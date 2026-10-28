//! The rules of a Match: who plays, the join window, Ships and their fire,
//! Waves of Darts and Pods, hits, and game over. They are systems over the
//! Match's World, run in a fixed order once per Tick by `step`; the numbers
//! they play by are in rules.zig.
//!
//! A Match runs from its first Player joining to game over. It is endless and
//! co-operative: Waves keep coming until no Ship is left.

const std = @import("std");
const engine = @import("engine_headless");
const ecs = engine.ecs;
const Endpoint = engine.net.Endpoint;
const protocol = @import("protocol.zig");
const rules = @import("rules.zig");
const world = @import("world.zig");
const Box = rules.Box;
const Position = world.Position;
const Velocity = world.Velocity;
const World = world.World;
const max_players = protocol.max_players;

pub const tick_rate = rules.tick_rate;
pub const screen_width = rules.screen_width;
pub const screen_height = rules.screen_height;
/// Ticks a Player may stay silent before being dropped.
pub const silence_limit: u32 = 3 * tick_rate;

/// What the Server's command line can change, in Ticks where it is a duration.
pub const Settings = struct {
    join_window: u32 = 5 * tick_rate,
    hit_points: u8 = 3,
    invulnerability: u16 = 4 * tick_rate,
    game_over_pause: u32 = 5 * tick_rate,
    /// The first Match's seed. Each next Match draws its own from the one
    /// before, and reports it when it begins, so any Match can be replayed.
    seed: u64,
};

pub const Phase = enum {
    /// Nobody is connected: the next Player to connect begins a Match.
    waiting,
    /// Ships appear as their Players join, and can move and fire. No Waves.
    join_window,
    playing,
    /// No Ship is left; a new join window opens when the pause ends.
    game_over,
};

/// A Player of the Match, as the Server knows it: their Ship, if they still
/// have one, is in the World.
pub const Player = struct {
    peer: Endpoint,
    /// Server Tick of the Player's last packet.
    last_heard: u32,
    /// Client Tick of the newest input applied.
    last_input: u32 = 0,
    actions: protocol.Actions = .{},
};

/// Player indices, such as the ones a Tick dropped.
pub const PlayerSet = std.StaticBitSet(max_players);

pub const JoinError = error{
    /// Every slot is taken, or was left during this Match.
    MatchFull,
    /// The join window has closed.
    AlreadyStarted,
};

pub const ShipDestroyed = struct { player: u8, position: Position };

/// What happened since the last Tick, for the Server to announce.
pub const Events = struct {
    timed_out: PlayerSet = .empty,
    /// The seed of a Match that began, to print so that it can be replayed.
    match_started: ?u64 = null,
    game_over: bool = false,
    /// Where Enemies were destroyed.
    explosions: [world.enemy_budget]Position = undefined,
    explosion_count: usize = 0,
    ships_destroyed: [max_players]ShipDestroyed = undefined,
    ship_destroyed_count: usize = 0,

    pub fn explosionSlice(e: *const Events) []const Position {
        return e.explosions[0..e.explosion_count];
    }

    pub fn shipDestroyedSlice(e: *const Events) []const ShipDestroyed {
        return e.ships_destroyed[0..e.ship_destroyed_count];
    }
};

pub const Match = struct {
    settings: Settings,
    players: [max_players]?Player = @splat(null),
    /// Slots of Players who left this Match: not freed until it ends.
    retired: PlayerSet = .empty,
    world: World = .empty,
    tick: u32 = 0,
    phase: Phase = .waiting,
    /// The Tick at which the join window closes, or the game-over pause ends.
    phase_ends: u32 = 0,
    /// The Tick at which the join window closed, which the Waves' ramp counts from.
    playing_since: u32 = 0,
    next_wave: u32 = 0,
    next_seed: u64,
    prng: std.Random.DefaultPrng,
    /// Gathered by `join`, `leave` and `step`, handed out by `step`.
    events: Events = .{},

    pub fn init(settings: Settings) Match {
        return .{ .settings = settings, .next_seed = settings.seed, .prng = .init(settings.seed) };
    }

    /// The Player index of `peer`, joining it if it is new. Outside a
    /// Match's join window, a new Player joins the next Match.
    pub fn join(m: *Match, peer: Endpoint) JoinError!u8 {
        if (m.find(peer)) |existing| return existing; // a repeated connect, after a lost accept
        if (m.phase == .playing) return error.AlreadyStarted;
        const index = for (m.players, 0..) |slot, i| {
            if (slot == null and !m.retired.isSet(i)) break i;
        } else return error.MatchFull;
        const player: u8 = @intCast(index);
        m.players[index] = .{ .peer = peer, .last_heard = m.tick };
        switch (m.phase) {
            .waiting => m.begin(),
            .join_window => {
                m.spawnShip(player);
                m.phase_ends = m.tick +% m.settings.join_window;
            },
            .game_over => {},
            .playing => unreachable,
        }
        return player;
    }

    pub fn find(m: *const Match, peer: Endpoint) ?u8 {
        for (m.players, 0..) |slot, index| {
            const player = slot orelse continue;
            if (player.peer.eql(peer)) return @intCast(index);
        }
        return null;
    }

    /// The Player loses their Ship at once, and their slot stays taken until
    /// the Match ends.
    pub fn leave(m: *Match, player: u8) void {
        if (player >= max_players or m.players[player] == null) return;
        m.players[player] = null;
        for (m.world.ships.items(.player), m.world.ships.items(.hit_points)) |owner, *hit_points| {
            if (owner == player) hit_points.* = 0;
        }
        switch (m.phase) {
            .join_window => {
                m.retired.set(player);
                if (m.playerCount() == 0) m.drop() else m.phase_ends = m.tick +% m.settings.join_window;
            },
            .playing => m.retired.set(player),
            .waiting, .game_over => {},
        }
    }

    /// Records the newest Actions held by a Player; also proves it is alive.
    pub fn receive(m: *Match, player: u8, input: protocol.Input) void {
        if (player >= max_players) return;
        if (m.players[player]) |*state| {
            state.last_heard = m.tick;
            // Datagrams can arrive out of order: never go back to older Actions.
            const newest = input.recent[0];
            if (newest.tick > state.last_input) {
                state.last_input = newest.tick;
                state.actions = newest.actions;
            }
        }
    }

    /// Advances one Tick, and returns what happened since the last one.
    /// Systems only mark rows; the removal steps after them take rows out.
    pub fn step(m: *Match) Events {
        m.tick +%= 1;
        m.dropSilent();
        m.advancePhase();
        if (m.phase == .join_window or m.phase == .playing) {
            m.moveShips();
            m.shipsFire();
            if (m.phase == .playing) m.spawnWaves();
            m.move();
            m.flyDarts();
            m.podsFire();
            m.hitEnemies();
            m.hitShips();
            m.removeSpent();
            if (m.phase == .playing and m.world.ships.len == 0) m.gameOver();
        }
        const events = m.events;
        m.events = .{};
        return events;
    }

    /// Where the Ships are. Protocol v1 (#26) adds every other kind.
    pub fn snapshot(m: *Match) protocol.Snapshot {
        var s: protocol.Snapshot = .{ .tick = m.tick };
        const ships = &m.world.ships;
        for (ships.items(.player), ships.items(.position), ships.items(.hit_points)) |player, position, hit_points| {
            if (hit_points == 0) continue;
            s.add(.{
                .player = player,
                // Kept on screen by moveShips(), which fits in a u16.
                .x = @intFromFloat(@round(position.x)),
                .y = @intFromFloat(@round(position.y)),
            });
        }
        return s;
    }

    pub fn playerCount(m: *const Match) usize {
        var count: usize = 0;
        for (m.players) |slot| count += @intFromBool(slot != null);
        return count;
    }

    // ---- Phases ----------------------------------------------------------

    /// Opens a Match's join window, with a Ship for every connected Player.
    fn begin(m: *Match) void {
        const seed = m.next_seed;
        m.prng = .init(seed);
        m.next_seed = m.random().int(u64);
        m.world = .empty;
        m.retired = .empty;
        m.phase = .join_window;
        m.phase_ends = m.tick +% m.settings.join_window;
        for (m.players, 0..) |slot, index| {
            if (slot != null) m.spawnShip(@intCast(index));
        }
        m.events.match_started = seed;
    }

    /// Every Player left during the join window.
    fn drop(m: *Match) void {
        m.world = .empty;
        m.retired = .empty;
        m.phase = .waiting;
    }

    fn gameOver(m: *Match) void {
        m.world = .empty;
        m.retired = .empty;
        m.phase = .game_over;
        m.phase_ends = m.tick +% m.settings.game_over_pause;
        m.events.game_over = true;
    }

    fn advancePhase(m: *Match) void {
        switch (m.phase) {
            .join_window => if (m.reached(m.phase_ends)) {
                m.phase = .playing;
                m.playing_since = m.tick;
                m.next_wave = m.tick +% rules.waves.first_after;
            },
            .game_over => if (m.reached(m.phase_ends)) {
                if (m.playerCount() > 0) m.begin() else m.phase = .waiting;
            },
            .waiting, .playing => {},
        }
    }

    fn dropSilent(m: *Match) void {
        for (0..max_players) |index| {
            const player = m.players[index] orelse continue;
            if (m.tick -% player.last_heard > silence_limit) {
                m.leave(@intCast(index));
                m.events.timed_out.set(index);
            }
        }
    }

    /// Whether Tick `at` has come, even across the Tick counter wrapping.
    fn reached(m: *const Match, at: u32) bool {
        return m.tick -% at < 1 << 31;
    }

    fn random(m: *Match) std.Random {
        return m.prng.random();
    }

    // ---- Ships -----------------------------------------------------------

    fn spawnShip(m: *Match, player: u8) void {
        const ship = rules.ship;
        // One Ship per slot at most, so the table never refuses it.
        _ = m.world.ships.spawn(.{
            .player = player,
            .position = .{ .x = ship.spawn_x, .y = ship.spawn_y + ship.spawn_step * @as(f32, @floatFromInt(player)) },
            .hit_points = m.settings.hit_points,
            .invulnerable = 0,
            .cooldown = 0,
        }).?;
    }

    fn moveShips(m: *Match) void {
        const ships = &m.world.ships;
        const box = rules.ship.box;
        for (ships.items(.player), ships.items(.position), ships.items(.invulnerable), ships.items(.cooldown)) |player, *position, *invulnerable, *cooldown| {
            invulnerable.* -|= 1;
            cooldown.* -|= 1;
            const held = (m.players[player] orelse continue).actions;
            const dx: f32 = @floatFromInt(@as(i32, @intFromBool(held.right)) - @intFromBool(held.left));
            const dy: f32 = @floatFromInt(@as(i32, @intFromBool(held.down)) - @intFromBool(held.up));
            position.x = std.math.clamp(position.x + dx * rules.ship.speed, 0, screen_width - box.width);
            position.y = std.math.clamp(position.y + dy * rules.ship.speed, 0, screen_height - box.height);
        }
    }

    /// A shot beyond the budget, or by an invulnerable Ship, does not happen.
    fn shipsFire(m: *Match) void {
        const ships = &m.world.ships;
        const fire = rules.ship_fire;
        const box = rules.ship.box;
        for (ships.items(.player), ships.items(.position), ships.items(.hit_points), ships.items(.invulnerable), ships.items(.cooldown)) |player, position, hit_points, invulnerable, *cooldown| {
            const held = (m.players[player] orelse continue).actions;
            if (!held.fire or hit_points == 0 or invulnerable > 0 or cooldown.* > 0) continue;
            if (m.inFlight(player) >= fire.per_ship) continue;
            const bolt = m.world.ship_projectiles.spawn(.{
                .owner = player,
                .position = .{ .x = position.x + box.width, .y = position.y + (box.height - fire.box.height) / 2 },
                .velocity = .{ .x = fire.speed, .y = 0 },
                .used = false,
            });
            if (bolt != null) cooldown.* = fire.every;
        }
    }

    fn inFlight(m: *Match, player: u8) usize {
        var count: usize = 0;
        for (m.world.ship_projectiles.items(.owner)) |owner| count += @intFromBool(owner == player);
        return count;
    }

    // ---- Enemies ---------------------------------------------------------

    fn spawnWaves(m: *Match) void {
        if (!m.reached(m.next_wave)) return;
        if (m.random().uintLessThan(u8, 100) < rules.enemies.dart.share) m.spawnWave(.dart) else m.spawnWave(.pod);
        m.next_wave = m.tick +% m.drawGap();
    }

    /// The interval to the next Wave, from a range that shrinks over the
    /// first minutes of play, then holds.
    fn drawGap(m: *Match) u32 {
        const waves = rules.waves;
        const elapsed: f32 = @floatFromInt(@min(m.tick -% m.playing_since, waves.ramp));
        const progress = elapsed / waves.ramp;
        const low = std.math.lerp(@as(f32, waves.gap_start[0]), waves.gap_end[0], progress);
        const high = std.math.lerp(@as(f32, waves.gap_start[1]), waves.gap_end[1], progress);
        return m.random().intRangeAtMost(u32, @intFromFloat(@round(low)), @intFromFloat(@round(high)));
    }

    /// A line of Enemies just beyond the right edge, at a height where the
    /// whole path stays on screen; skipped if it does not fit whole.
    fn spawnWave(m: *Match, comptime kind: rules.EnemyKind) void {
        const enemy = rules.enemies.of(kind);
        const size = m.random().intRangeAtMost(u8, enemy.wave_min, enemy.wave_max);
        if (m.world.enemyCount() + size > world.enemy_budget) return;
        const y = enemy.amplitude + m.random().float(f32) * (screen_height - enemy.box.height - 2 * enemy.amplitude);
        for (0..size) |i| {
            const position: Position = .{ .x = screen_width + enemy.spacing * @as(f32, @floatFromInt(i)), .y = y };
            const velocity: Velocity = .{ .x = -enemy.speed, .y = 0 };
            // The budget check above keeps both tables from refusing.
            switch (kind) {
                .dart => _ = m.world.darts.spawn(.{ .position = position, .velocity = velocity, .wave_y = y, .age = 0, .hit_points = enemy.hit_points }).?,
                .pod => _ = m.world.pods.spawn(.{ .position = position, .velocity = velocity, .hit_points = enemy.hit_points, .cooldown = enemy.fire_every }).?,
            }
        }
    }

    /// Everything that flies straight: Projectiles, and Enemies' leftward drift.
    fn move(m: *Match) void {
        for (ecs.query(&m.world, .{ .position, .velocity })) |rows| {
            for (rows.position, rows.velocity) |*position, velocity| {
                position.x += velocity.x;
                position.y += velocity.y;
            }
        }
    }

    fn flyDarts(m: *Match) void {
        const dart = rules.enemies.dart;
        const darts = &m.world.darts;
        for (darts.items(.position), darts.items(.wave_y), darts.items(.age)) |*position, wave_y, *age| {
            age.* +%= 1;
            const turn = @as(f32, @floatFromInt(age.* % dart.period)) / @as(f32, @floatFromInt(dart.period));
            position.y = wave_y + dart.amplitude * @sin(2 * std.math.pi * turn);
        }
    }

    /// Once fully on screen, each Pod fires at the nearest Ship still in play,
    /// invulnerable or not.
    fn podsFire(m: *Match) void {
        const pod = rules.enemies.pod;
        const orb = rules.enemy_projectile.box;
        const pods = &m.world.pods;
        for (pods.items(.position), pods.items(.cooldown)) |position, *cooldown| {
            if (position.x + pod.box.width > screen_width) continue;
            cooldown.* -|= 1;
            if (cooldown.* > 0) continue;
            cooldown.* = pod.fire_every;
            const from = centre(position, pod.box);
            const to = m.nearestShip(from) orelse continue;
            const dx = to.x - from.x;
            const dy = to.y - from.y;
            const length = @sqrt(dx * dx + dy * dy);
            const velocity: Velocity = if (length == 0)
                .{ .x = -pod.projectile_speed, .y = 0 }
            else
                .{ .x = dx / length * pod.projectile_speed, .y = dy / length * pod.projectile_speed };
            // A shot beyond the budget does not happen.
            _ = m.world.enemy_projectiles.spawn(.{
                .position = .{ .x = from.x - orb.width / 2, .y = from.y - orb.height / 2 },
                .velocity = velocity,
                .used = false,
            });
        }
    }

    /// The centre of the nearest Ship still in play.
    fn nearestShip(m: *Match, from: Position) ?Position {
        var nearest: ?Position = null;
        var best = std.math.inf(f32);
        for (m.world.ships.items(.position), m.world.ships.items(.hit_points)) |position, hit_points| {
            if (hit_points == 0) continue;
            const at = centre(position, rules.ship.box);
            const distance = (at.x - from.x) * (at.x - from.x) + (at.y - from.y) * (at.y - from.y);
            if (distance < best) {
                best = distance;
                nearest = at;
            }
        }
        return nearest;
    }

    // ---- Hits ------------------------------------------------------------

    /// A Ship's Projectile hits only Enemies, and the hit uses it up.
    fn hitEnemies(m: *Match) void {
        const bolt_box = rules.ship_fire.box;
        const bolts = &m.world.ship_projectiles;
        for (bolts.items(.position), bolts.items(.used)) |bolt, *used| {
            if (used.*) continue;
            used.* = hitFirst(&m.world.darts, rules.enemies.dart.box, bolt, bolt_box) or
                hitFirst(&m.world.pods, rules.enemies.pod.box, bolt, bolt_box);
        }
    }

    /// Enemy Projectiles, and touching an Enemy, cost a Ship one hit point.
    /// Nothing harms an invulnerable Ship: Enemy Projectiles pass through it
    /// without being used up, and the Enemy it touches loses nothing.
    fn hitShips(m: *Match) void {
        const box = rules.ship.box;
        const orbs = &m.world.enemy_projectiles;
        const ships = &m.world.ships;
        for (ships.items(.position), ships.items(.hit_points), ships.items(.invulnerable)) |position, *hit_points, *invulnerable| {
            for (orbs.items(.position), orbs.items(.used)) |orb, *used| {
                if (hit_points.* == 0 or invulnerable.* > 0) break;
                if (used.* or !overlaps(position, box, orb, rules.enemy_projectile.box)) continue;
                used.* = true;
                m.hit(hit_points, invulnerable);
            }
            if (hit_points.* == 0 or invulnerable.* > 0) continue;
            if (touchesAny(&m.world.darts, rules.enemies.dart.box, position, box) or
                touchesAny(&m.world.pods, rules.enemies.pod.box, position, box))
            {
                m.hit(hit_points, invulnerable);
            }
        }
    }

    fn hit(m: *const Match, hit_points: *u8, invulnerable: *u16) void {
        hit_points.* -= 1;
        if (hit_points.* > 0) invulnerable.* = m.settings.invulnerability;
    }

    /// The removal steps: used and off-screen Projectiles, Enemies destroyed
    /// or past the left edge, and Ships at zero hit points.
    fn removeSpent(m: *Match) void {
        m.world.ship_projectiles.removeIf(rules.ship_fire.box, spentProjectile);
        m.world.enemy_projectiles.removeIf(rules.enemy_projectile.box, spentProjectile);
        m.removeEnemies(.dart);
        m.removeEnemies(.pod);
        m.world.ships.removeIf(m, destroyedShip);
    }

    fn removeEnemies(m: *Match, comptime kind: rules.EnemyKind) void {
        const gone = struct {
            fn gone(match: *Match, _: ecs.Id, row: anytype) bool {
                if (row.hit_points == 0) {
                    match.events.explosions[match.events.explosion_count] = row.position;
                    match.events.explosion_count += 1;
                    return true;
                }
                // Off the left edge, silently.
                return row.position.x + rules.enemies.of(kind).box.width < 0;
            }
        }.gone;
        @field(m.world, @tagName(kind) ++ "s").removeIf(m, gone);
    }
};

fn spentProjectile(box: Box, _: ecs.Id, row: anytype) bool {
    const p = row.position;
    return row.used or p.x + box.width < 0 or p.x > screen_width or p.y + box.height < 0 or p.y > screen_height;
}

fn destroyedShip(m: *Match, _: ecs.Id, row: anytype) bool {
    if (row.hit_points > 0) return false;
    m.events.ships_destroyed[m.events.ship_destroyed_count] = .{ .player = row.player, .position = row.position };
    m.events.ship_destroyed_count += 1;
    return true;
}

/// Takes one hit point from the first Enemy of `table` still in play that
/// overlaps the box at `at`.
fn hitFirst(table: anytype, box: Box, at: Position, at_box: Box) bool {
    for (table.items(.position), table.items(.hit_points)) |position, *hit_points| {
        if (hit_points.* == 0 or !overlaps(position, box, at, at_box)) continue;
        hit_points.* -= 1;
        return true;
    }
    return false;
}

fn touchesAny(table: anytype, box: Box, at: Position, at_box: Box) bool {
    for (table.items(.position), table.items(.hit_points)) |position, hit_points| {
        if (hit_points > 0 and overlaps(position, box, at, at_box)) return true;
    }
    return false;
}

fn overlaps(a: Position, a_box: Box, b: Position, b_box: Box) bool {
    return a.x < b.x + b_box.width and b.x < a.x + a_box.width and
        a.y < b.y + b_box.height and b.y < a.y + a_box.height;
}

fn centre(position: Position, box: Box) Position {
    return .{ .x = position.x + box.width / 2, .y = position.y + box.height / 2 };
}

const testing = std.testing;

fn inputOf(tick: u32, actions: protocol.Actions) protocol.Input {
    return .{ .recent = @splat(.{ .tick = tick, .actions = actions }) };
}

/// Steps `ticks` times while every Player keeps talking, and returns the
/// last Tick's events.
fn run(m: *Match, ticks: usize) Events {
    var events: Events = .{};
    for (0..ticks) |_| {
        for (&m.players) |*slot| {
            if (slot.*) |*player| player.last_heard = m.tick;
        }
        events = m.step();
    }
    return events;
}

/// A Match of `players` Players, `ticks` Ticks after the first joined.
fn started(players: u8, ticks: usize) Match {
    var m: Match = .init(.{ .seed = 42 });
    for (0..players) |port| _ = m.join(.loopback(@intCast(port))) catch unreachable;
    _ = run(&m, ticks);
    return m;
}

fn shipRow(m: *Match, player: u8) ?usize {
    return std.mem.findScalar(u8, m.world.ships.items(.player), player);
}

test "four Players join and a fifth is refused" {
    var m: Match = .init(.{ .seed = 1 });
    for (0..4) |port| try testing.expectEqual(@as(u8, @intCast(port)), try m.join(.loopback(@intCast(port))));
    try testing.expectEqual(2, try m.join(.loopback(2))); // a repeated connect keeps its index
    try testing.expectError(error.MatchFull, m.join(.loopback(9)));
    try testing.expectEqual(4, m.world.ships.len);
}

test "a Player who leaves keeps their slot until the Match ends" {
    var m = started(2, 1);
    m.leave(1);
    try testing.expectEqual(2, try m.join(.loopback(2)));
    try testing.expectEqual(3, try m.join(.loopback(3)));
    try testing.expectError(error.MatchFull, m.join(.loopback(4))); // slot 1 stays taken
    const events = run(&m, 1);
    try testing.expectEqual(1, events.ship_destroyed_count);
    try testing.expectEqual(1, events.shipDestroyedSlice()[0].player);
}

test "Ships move with the newest input and stay on screen" {
    var m = started(1, 0);
    m.receive(0, inputOf(2, .{ .left = true, .up = true }));
    m.receive(0, inputOf(1, .{ .right = true })); // older: ignored
    _ = run(&m, 100);
    const ship = m.snapshot().shipSlice()[0];
    try testing.expectEqual(0, ship.x);
    try testing.expectEqual(0, ship.y);
}

test "a silent Player is dropped after three seconds" {
    var m: Match = .init(.{ .seed = 1 });
    _ = try m.join(.loopback(1));
    for (0..silence_limit) |_| try testing.expectEqual(0, m.step().timed_out.count());
    const dropped = m.step().timed_out;
    try testing.expect(dropped.isSet(0) and dropped.count() == 1);
    try testing.expectEqual(0, m.playerCount());
    // The only Player left during the join window: the Match is dropped.
    try testing.expectEqual(.waiting, m.phase);
}

test "the join window closes five seconds after the last join or leave" {
    var m = started(1, 200);
    _ = try m.join(.loopback(1)); // restarts the window
    _ = run(&m, 299);
    try testing.expectEqual(.join_window, m.phase);
    try testing.expectEqual(0, m.world.enemyCount());
    _ = run(&m, 1);
    try testing.expectEqual(.playing, m.phase);
    try testing.expectError(error.AlreadyStarted, m.join(.loopback(9)));
    try testing.expectEqual(0, try m.join(.loopback(0))); // a known Player is still welcome
}

test "a Match begins with a seed it reports" {
    var m: Match = .init(.{ .seed = 7 });
    _ = try m.join(.loopback(1));
    try testing.expectEqual(7, m.step().match_started);
    try testing.expectEqual(null, m.step().match_started);
}

test "a Ship fires every 12 Ticks while Fire is held, and not while invulnerable" {
    var m = started(1, 0);
    m.receive(0, inputOf(1, .{ .fire = true }));
    _ = run(&m, 1);
    try testing.expectEqual(1, m.world.ship_projectiles.len);
    _ = run(&m, 11);
    try testing.expectEqual(1, m.world.ship_projectiles.len);
    _ = run(&m, 1);
    try testing.expectEqual(2, m.world.ship_projectiles.len);

    m.world.ships.items(.invulnerable)[0] = 100;
    const before = m.world.ship_projectiles.len;
    _ = run(&m, 24);
    try testing.expect(m.world.ship_projectiles.len <= before);
}

test "a Ship's shots beyond its budget do not happen" {
    var m = started(1, 0);
    for (0..rules.ship_fire.per_ship) |_| {
        _ = m.world.ship_projectiles.spawn(.{ .owner = 0, .position = .{ .x = 600, .y = 600 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    }
    m.receive(0, inputOf(1, .{ .fire = true }));
    _ = run(&m, 1);
    try testing.expectEqual(rules.ship_fire.per_ship, m.world.ship_projectiles.len);
}

test "the first Wave comes two seconds after the join window" {
    var m = started(1, 300 + 119);
    try testing.expectEqual(.playing, m.phase);
    try testing.expectEqual(0, m.world.enemyCount());
    _ = run(&m, 1);
    try testing.expect(m.world.enemyCount() > 0);
}

test "a Wave that does not fit whole is skipped" {
    var m = started(1, 0);
    for (0..world.enemy_budget - 3) |_| {
        _ = m.world.pods.spawn(.{ .position = .{ .x = 900, .y = 600 }, .velocity = .{ .x = 0, .y = 0 }, .hit_points = 3, .cooldown = 100 }).?;
    }
    m.spawnWave(.dart); // at least 4
    try testing.expectEqual(0, m.world.darts.len);
    m.spawnWave(.pod); // at most 3
    try testing.expect(m.world.pods.len > world.enemy_budget - 3);
}

test "the interval between Waves shrinks over three minutes, then holds" {
    var m = started(1, 300);
    for (0..100) |_| {
        const gap = m.drawGap();
        try testing.expect(gap >= 2 * tick_rate and gap <= 4 * tick_rate);
    }
    m.tick +%= rules.waves.ramp * 2;
    for (0..100) |_| {
        const gap = m.drawGap();
        try testing.expect(gap >= 1 * tick_rate and gap <= 2 * tick_rate);
    }
}

test "the same seed plays the same Match" {
    var a = started(2, 0);
    var b = started(2, 0);
    for ([_]*Match{ &a, &b }) |m| m.receive(0, inputOf(1, .{ .fire = true, .down = true }));
    _ = run(&a, 3000);
    _ = run(&b, 3000);
    inline for (.{ "ships", "ship_projectiles", "darts", "pods", "enemy_projectiles" }) |name| {
        const ta = &@field(a.world, name);
        const tb = &@field(b.world, name);
        try testing.expectEqualSlices(ecs.Id, ta.liveIds(), tb.liveIds());
        try testing.expectEqualSlices(Position, ta.items(.position), tb.items(.position));
    }
    try testing.expectEqual(a.phase, b.phase);
}

test "Darts keep their whole path on screen" {
    var m = started(1, 300);
    for (0..50) |_| m.spawnWave(.dart);
    for (0..400) |_| {
        _ = run(&m, 1);
        for (m.world.darts.items(.position)) |p| {
            try testing.expect(p.y >= 0 and p.y + rules.enemies.dart.box.height <= screen_height);
        }
    }
}

test "a Pod fully on screen fires at the nearest Ship" {
    var m = started(2, 0); // Ships at y = 90 and y = 250
    _ = m.world.pods.spawn(.{ .position = .{ .x = 600, .y = 400 }, .velocity = .{ .x = 0, .y = 0 }, .hit_points = 3, .cooldown = 1 }).?;
    _ = m.world.pods.spawn(.{ .position = .{ .x = screen_width - 10, .y = 400 }, .velocity = .{ .x = 0, .y = 0 }, .hit_points = 3, .cooldown = 1 }).?;
    _ = run(&m, 1);
    try testing.expectEqual(1, m.world.enemy_projectiles.len); // the second Pod is not fully on screen
    const v = m.world.enemy_projectiles.items(.velocity)[0];
    try testing.expectApproxEqAbs(rules.enemies.pod.projectile_speed, @sqrt(v.x * v.x + v.y * v.y), 0.001);
    try testing.expect(v.x < 0 and v.y < 0); // up and left, towards the Ship at y = 250
    try testing.expectEqual(rules.enemies.pod.fire_every, m.world.pods.items(.cooldown)[0]);
}

test "a Ship's Projectile hits only Enemies, and is used up" {
    var m = started(2, 0);
    _ = m.world.darts.spawn(.{ .position = .{ .x = 600, .y = 400 }, .velocity = .{ .x = 0, .y = 0 }, .wave_y = 400, .age = 0, .hit_points = 1 }).?;
    const ship = m.world.ships.items(.position)[1];
    _ = m.world.ship_projectiles.spawn(.{ .owner = 0, .position = .{ .x = 610, .y = 420 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    _ = m.world.ship_projectiles.spawn(.{ .owner = 0, .position = .{ .x = ship.x + 10, .y = ship.y + 10 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    const events = run(&m, 1);
    try testing.expectEqual(0, m.world.darts.len);
    try testing.expectEqual(1, events.explosion_count);
    try testing.expectEqual(1, m.world.ship_projectiles.len); // the one over a Ship: no friendly fire
    try testing.expectEqual(3, m.world.ships.items(.hit_points)[1]);
}

test "a Pod takes three hits" {
    var m = started(1, 0);
    _ = m.world.pods.spawn(.{ .position = .{ .x = 600, .y = 400 }, .velocity = .{ .x = 0, .y = 0 }, .hit_points = 3, .cooldown = 1000 }).?;
    for (0..3) |shot| {
        try testing.expectEqual(1, m.world.pods.len);
        _ = m.world.ship_projectiles.spawn(.{ .owner = 0, .position = .{ .x = 605, .y = 405 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
        const events = run(&m, 1);
        try testing.expectEqual(@intFromBool(shot == 2), events.explosion_count);
    }
    try testing.expectEqual(0, m.world.pods.len);
}

test "an Enemy Projectile costs a hit point, then passes through while invulnerable" {
    var m = started(1, 0);
    const ship = m.world.ships.items(.position)[0];
    const orb: Position = .{ .x = ship.x + 10, .y = ship.y + 10 };
    _ = m.world.enemy_projectiles.spawn(.{ .position = orb, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    _ = run(&m, 1);
    try testing.expectEqual(2, m.world.ships.items(.hit_points)[0]);
    try testing.expectEqual(0, m.world.enemy_projectiles.len);

    _ = m.world.enemy_projectiles.spawn(.{ .position = orb, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    _ = run(&m, 1);
    try testing.expectEqual(2, m.world.ships.items(.hit_points)[0]);
    try testing.expectEqual(1, m.world.enemy_projectiles.len);

    _ = run(&m, m.settings.invulnerability);
    try testing.expectEqual(1, m.world.ships.items(.hit_points)[0]);
}

test "touching an Enemy costs the Ship a hit point, and the Enemy nothing" {
    var m = started(1, 0);
    const ship = m.world.ships.items(.position)[0];
    _ = m.world.pods.spawn(.{ .position = ship, .velocity = .{ .x = 0, .y = 0 }, .hit_points = 3, .cooldown = 1000 }).?;
    _ = run(&m, 1);
    try testing.expectEqual(2, m.world.ships.items(.hit_points)[0]);
    try testing.expectEqual(3, m.world.pods.items(.hit_points)[0]);
    try testing.expectEqual(m.settings.invulnerability, m.world.ships.items(.invulnerable)[0]);
}

test "a Projectile keeps flying after its Ship is destroyed" {
    var m = started(2, 0);
    _ = m.world.ship_projectiles.spawn(.{ .owner = 0, .position = .{ .x = 400, .y = 600 }, .velocity = .{ .x = 16, .y = 0 }, .used = false }).?;
    m.leave(0);
    const events = run(&m, 1);
    try testing.expectEqual(1, events.ship_destroyed_count);
    try testing.expectEqual(1, m.world.ship_projectiles.len);
}

test "the last Ship destroyed ends the Match, and a new one begins after the pause" {
    var m = started(1, 300);
    try testing.expectEqual(.playing, m.phase);
    m.world.ships.items(.hit_points)[0] = 1;
    const ship = m.world.ships.items(.position)[0];
    _ = m.world.enemy_projectiles.spawn(.{ .position = .{ .x = ship.x + 10, .y = ship.y + 10 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    const events = run(&m, 1);
    try testing.expectEqual(1, events.ship_destroyed_count);
    try testing.expect(events.game_over);
    try testing.expectEqual(.game_over, m.phase);
    try testing.expectEqual(0, m.world.enemyCount() + m.world.enemy_projectiles.len + m.world.ship_projectiles.len);

    _ = try m.join(.loopback(5)); // joins the next Match
    _ = run(&m, m.settings.game_over_pause - 1);
    try testing.expectEqual(.game_over, m.phase);
    const next = run(&m, 1);
    try testing.expectEqual(.join_window, m.phase);
    try testing.expect(next.match_started != null);
    try testing.expectEqual(2, m.world.ships.len);
    try testing.expect(shipRow(&m, 0) != null);
}

test "a Match with nobody left after game over waits for the next Player" {
    var m = started(1, 300);
    m.leave(0);
    try testing.expect(run(&m, 1).game_over);
    _ = run(&m, m.settings.game_over_pause);
    try testing.expectEqual(.waiting, m.phase);
    try testing.expectEqual(0, try m.join(.loopback(1)));
    try testing.expectEqual(.join_window, m.phase);
}
