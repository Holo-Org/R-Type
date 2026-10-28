//! What the Client draws of the Match at one Server Tick: the Scene. Only
//! the conversions at the bottom know where it comes from, a Snapshot or,
//! with `--demo`, a Match run inside the Client; the drawing reads nothing else.

const std = @import("std");
const game = @import("game");
const protocol = game.protocol;
const rules = game.rules;
const World = game.world.World;
const tick_rate = rules.tick_rate;

pub const Phase = game.match.Phase;

/// An entity's top-left corner, as in the Match's World.
pub const Position = game.world.Position;

pub const Ship = struct {
    player: u8,
    position: Position,
    /// Null until Snapshots carry them (#26).
    hit_points: ?u8,
    invulnerable: bool,
};

/// A Dart, a Pod or a Projectile: told apart from the others of its kind by
/// its id, which Snapshots carry.
pub const Entity = struct {
    id: u8,
    position: Position,
};

/// At most `capacity` items, held inline.
pub fn List(comptime capacity_: usize, comptime T: type) type {
    return struct {
        const Self = @This();
        pub const capacity = capacity_;

        buffer: [capacity]T = undefined,
        len: usize = 0,

        /// Leaves out any item beyond `capacity`.
        pub fn append(list: *Self, item: T) void {
            if (list.len == capacity) return;
            list.buffer[list.len] = item;
            list.len += 1;
        }

        pub fn slice(list: *const Self) []const T {
            return list.buffer[0..list.len];
        }
    };
}

/// As many as the Match's table of that kind holds.
fn ListOf(comptime table: []const u8, comptime T: type) type {
    return List(@FieldType(World, table).capacity, T);
}

pub const Scene = struct {
    tick: u32 = 0,
    phase: Phase = .playing,
    /// The Tick at which the join window closes, or the game-over pause ends.
    phase_ends: u32 = 0,
    ships: ListOf("ships", Ship) = .{},
    darts: ListOf("darts", Entity) = .{},
    pods: ListOf("pods", Entity) = .{},
    /// Ships' Projectiles.
    bolts: ListOf("ship_projectiles", Entity) = .{},
    /// Enemies' Projectiles.
    orbs: ListOf("enemy_projectiles", Entity) = .{},

    /// Whole seconds left in the join window or the game-over pause, rounded
    /// up; null in the other phases.
    pub fn secondsLeft(scene: *const Scene) ?u32 {
        if (scene.phase != .join_window and scene.phase != .game_over) return null;
        const ticks = scene.phase_ends -% scene.tick;
        if (ticks >= 1 << 31) return 0; // already past, across the Tick counter wrapping
        return std.math.divCeil(u32, ticks, tick_rate) catch unreachable;
    }

    /// The Ships, as a Snapshot gives them today. Protocol v1 (#26) adds the
    /// phase, hit points and every other kind of entity.
    pub fn fromSnapshot(snapshot: *const protocol.Snapshot) Scene {
        var scene: Scene = .{ .tick = snapshot.tick };
        for (snapshot.shipSlice()) |ship| scene.ships.append(.{
            .player = ship.player,
            .position = .{ .x = @floatFromInt(ship.x), .y = @floatFromInt(ship.y) },
            .hit_points = null,
            .invulnerable = false,
        });
        return scene;
    }

    /// Everything a Snapshot of protocol v1 will hold, read straight from a
    /// Match's World, for `--demo`.
    pub fn fromMatch(match: *game.match.Match) Scene {
        var scene: Scene = .{ .tick = match.tick, .phase = match.phase };
        if (match.phase == .join_window or match.phase == .game_over) scene.phase_ends = match.phase_ends;
        const w = &match.world;
        for (w.ships.items(.player), w.ships.items(.position), w.ships.items(.hit_points), w.ships.items(.invulnerable)) |player, position, hit_points, invulnerable| {
            if (hit_points == 0) continue; // destroyed this Tick, as in a Snapshot
            scene.ships.append(.{ .player = player, .position = position, .hit_points = hit_points, .invulnerable = invulnerable > 0 });
        }
        inline for (.{ .{ "darts", "darts" }, .{ "pods", "pods" }, .{ "bolts", "ship_projectiles" }, .{ "orbs", "enemy_projectiles" } }) |pair| {
            const table = &@field(w, pair[1]);
            for (table.liveIds(), table.items(.position)) |id, position| {
                @field(scene, pair[0]).append(.{ .id = id, .position = position });
            }
        }
        return scene;
    }
};

/// Where Ships' Projectiles hit Enemies between two Scenes: each one that
/// vanished short of the right edge, at its front. Nothing hits when the world
/// empties at game over. Snapshots can be lost, so a Projectile that vanished
/// within a few Ticks of the edge is taken to have left the screen.
pub fn hits(previous: *const Scene, next: *const Scene, out: []Position) []Position {
    if (next.phase != .join_window and next.phase != .playing) return out[0..0];
    const box = rules.ship_fire.box;
    const margin = 4 * rules.ship_fire.speed;
    var count: usize = 0;
    for (previous.bolts.slice()) |bolt| {
        const still_there = for (next.bolts.slice()) |later| {
            if (later.id == bolt.id) break true;
        } else false;
        if (still_there or bolt.position.x + box.width + margin >= rules.screen_width) continue;
        if (count == out.len) break;
        out[count] = .{ .x = bolt.position.x + box.width, .y = bolt.position.y + box.height / 2 };
        count += 1;
    }
    return out[0..count];
}

const testing = std.testing;

test "the join window counts whole seconds down" {
    var scene: Scene = .{ .tick = 100, .phase = .join_window, .phase_ends = 100 + 5 * tick_rate };
    try testing.expectEqual(5, scene.secondsLeft());
    scene.tick += 1;
    try testing.expectEqual(5, scene.secondsLeft());
    scene.tick += 4 * tick_rate - 1;
    try testing.expectEqual(1, scene.secondsLeft());
    scene.tick += tick_rate;
    try testing.expectEqual(0, scene.secondsLeft());
    scene.tick += 10; // a Snapshot that left before the window closed, overtaken
    try testing.expectEqual(0, scene.secondsLeft());
    scene.phase = .playing;
    try testing.expectEqual(null, scene.secondsLeft());
}

test "game over counts down to the next join window" {
    const scene: Scene = .{ .tick = 100, .phase = .game_over, .phase_ends = 100 + 3 * tick_rate - 1 };
    try testing.expectEqual(3, scene.secondsLeft());
}

test "the countdown survives the Tick counter wrapping" {
    const scene: Scene = .{ .tick = std.math.maxInt(u32) - 10, .phase = .join_window, .phase_ends = 50 };
    try testing.expectEqual(2, scene.secondsLeft()); // 61 Ticks
}

test "a Projectile that vanishes short of the right edge has hit" {
    var before: Scene = .{};
    before.bolts.append(.{ .id = 1, .position = .{ .x = 400, .y = 100 } }); // hits
    before.bolts.append(.{ .id = 2, .position = .{ .x = 500, .y = 200 } }); // flies on
    before.bolts.append(.{ .id = 3, .position = .{ .x = rules.screen_width - 40, .y = 300 } }); // leaves the screen
    var after: Scene = .{};
    after.bolts.append(.{ .id = 2, .position = .{ .x = 516, .y = 200 } });
    var buffer: [8]Position = undefined;
    const found = hits(&before, &after, &buffer);
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(400 + rules.ship_fire.box.width, found[0].x);
    try testing.expectEqual(100 + rules.ship_fire.box.height / 2, found[0].y);

    const game_over: Scene = .{ .phase = .game_over }; // the world emptied
    try testing.expectEqual(0, hits(&before, &game_over, &buffer).len);
}

test "a Scene from a Match holds every kind, and leaves destroyed Ships out" {
    var match: game.match.Match = .init(.{ .seed = 3 });
    _ = try match.join(.loopback(1));
    _ = try match.join(.loopback(2));
    _ = match.world.darts.spawn(.{ .position = .{ .x = 10, .y = 20 }, .velocity = .{ .x = 0, .y = 0 }, .wave_y = 20, .age = 0, .hit_points = 1 }).?;
    _ = match.world.enemy_projectiles.spawn(.{ .position = .{ .x = 30, .y = 40 }, .velocity = .{ .x = 0, .y = 0 }, .used = false }).?;
    match.world.ships.items(.hit_points)[1] = 0;
    match.world.ships.items(.invulnerable)[0] = 5;

    const scene: Scene = .fromMatch(&match);
    try testing.expectEqual(.join_window, scene.phase);
    try testing.expectEqual(5, scene.secondsLeft());
    try testing.expectEqual(1, scene.ships.len);
    try testing.expect(scene.ships.slice()[0].invulnerable);
    try testing.expectEqual(3, scene.ships.slice()[0].hit_points);
    try testing.expectEqual(1, scene.darts.len);
    try testing.expectEqual(Position{ .x = 30, .y = 40 }, scene.orbs.slice()[0].position);
}

test "a Scene from today's Snapshot holds the Ships" {
    var snapshot: protocol.Snapshot = .{ .tick = 9 };
    snapshot.add(.{ .player = 2, .x = 64, .y = 90 });
    const scene: Scene = .fromSnapshot(&snapshot);
    try testing.expectEqual(1, scene.ships.len);
    try testing.expectEqual(Position{ .x = 64, .y = 90 }, scene.ships.slice()[0].position);
    try testing.expectEqual(null, scene.ships.slice()[0].hit_points);
}
