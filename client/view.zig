//! The Match as the Player sees it: the newest Scene, drawn as it is over the
//! Star-field, with the Client's own effects and the HUD on top. Frames
//! follow the Client's clock, not the Server's Ticks.

const std = @import("std");
const engine = @import("engine_client");
const game = @import("game");
const rules = game.rules;
const scene_ = @import("scene.zig");
const Scene = scene_.Scene;
const Position = scene_.Position;
const Effects = @import("effects.zig").Effects;
const PlayerSet = game.match.PlayerSet;
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");
const Sprites = sprites.Sprites;
const centreOf = sprites.centreOf;
const Starfield = @import("starfield.zig").Starfield;

/// An invulnerable Ship is drawn see-through, steadily: it never blinks.
const invulnerable_tint: engine.Color = .{ .r = 255, .g = 255, .b = 255, .a = 110 };

pub const View = struct {
    sprites: Sprites,
    starfield: Starfield,
    effects: Effects = .empty,
    scene: Scene = .{},
    /// Who plays the Match: every Ship of the join window, and any seen
    /// since, destroyed or not, so that the heart bar lists every Player.
    players: PlayerSet = .empty,
    /// Seconds since the View opened: every animation follows it.
    clock: f32 = 0,

    pub fn init(window: *engine.Window) engine.Error!View {
        return .{
            .sprites = try .load(window),
            .starfield = .init(rules.screen_width, rules.screen_height, 2026),
        };
    }

    pub fn deinit(view: *const View) void {
        view.sprites.unload();
    }

    /// Shows the newest Scene, with an impact wherever a Ship's Projectile
    /// hit an Enemy since the one before.
    pub fn show(view: *View, next: Scene) void {
        var buffer: [@TypeOf(next.bolts).capacity]Position = undefined;
        for (scene_.hits(&view.scene, &next, &buffer)) |at| view.effects.spawn(.impact, at);
        // In the join window, Players can still leave, and a new Match starts
        // afresh: only the Ships there count.
        if (next.phase == .join_window) view.players = .empty;
        if (next.phase == .join_window or next.phase == .playing) {
            for (next.ships.slice()) |ship| view.players.set(ship.player);
        }
        view.scene = next;
    }

    /// Whether `player` lost their Ship in the Match being played.
    pub fn isDestroyed(view: *const View, player: u8) bool {
        if (view.scene.phase != .playing or !view.players.isSet(player)) return false;
        for (view.scene.ships.slice()) |ship| {
            if (ship.player == player) return false;
        }
        return true;
    }

    /// An Enemy destroyed at `position`, its top-left corner: the explosion
    /// Announcement. Call it before showing the Scene it vanished from, so
    /// that it is still there to tell its size.
    pub fn enemyDestroyed(view: *View, position: Position) void {
        var centre = centreOf(position, rules.enemies.dart.box);
        var nearest = std.math.inf(f32);
        inline for (.{ .{ "darts", rules.enemies.dart.box }, .{ "pods", rules.enemies.pod.box } }) |kind| {
            for (@field(view.scene, kind[0]).slice()) |enemy| {
                const distance = @abs(enemy.position.x - position.x) + @abs(enemy.position.y - position.y);
                if (distance < nearest) {
                    nearest = distance;
                    centre = centreOf(position, kind[1]);
                }
            }
        }
        view.effects.spawn(.explosion, centre);
    }

    /// A Ship destroyed at `position`, its top-left corner: the "Ship
    /// destroyed" Announcement.
    pub fn shipDestroyed(view: *View, position: Position) void {
        view.effects.spawn(.ship_explosion, centreOf(position, rules.ship.box));
    }

    pub fn advance(view: *View, seconds: f32) void {
        view.clock += seconds;
        view.starfield.scroll(seconds);
        view.effects.advance(seconds);
    }

    /// Back to front: the Star-field, Enemies, Projectiles, Ships, effects,
    /// then the HUD, with who `me` plays as once the Server has said.
    pub fn draw(view: *const View, frame: *engine.Frame, me: ?u8) void {
        const scene = &view.scene;
        view.starfield.draw(frame);
        view.drawAll(frame, scene.darts.slice(), sprites.dart, rules.enemies.dart.box);
        view.drawAll(frame, scene.pods.slice(), sprites.pod, rules.enemies.pod.box);
        view.drawAll(frame, scene.bolts.slice(), sprites.bolt, rules.ship_fire.box);
        view.drawAll(frame, scene.orbs.slice(), sprites.orb, rules.enemy_projectile.box);
        for (scene.ships.slice()) |ship| view.drawShip(frame, ship);
        inline for (comptime std.enums.values(@import("effects.zig").Kind)) |kind| {
            const table = &@field(view.effects, @tagName(kind));
            for (table.columns.centre[0..table.len], table.columns.age[0..table.len]) |centre, age| {
                view.sprites.draw(frame, kind.animation(), age, centre, .white);
            }
        }
        if (me) |player| hud.drawPlayer(frame, player, view.isDestroyed(player));
        hud.drawHeartBar(frame, view.players, scene);
        hud.drawCountdown(frame, scene);
        hud.drawGameOver(frame, scene);
    }

    /// Each entity's animation starts at a moment of its own, from its id,
    /// so that a Wave does not move in lockstep.
    fn drawAll(view: *const View, frame: *engine.Frame, entities: []const scene_.Entity, animation: sprites.Animation, box: rules.Box) void {
        for (entities) |entity| {
            const offset = @as(f32, @floatFromInt(entity.id)) * 0.37;
            view.sprites.draw(frame, animation, view.clock + offset, centreOf(entity.position, box), .white);
        }
    }

    /// The Ship, and its Player's number in their colour beside it.
    fn drawShip(view: *const View, frame: *engine.Frame, ship: scene_.Ship) void {
        const box = rules.ship.box;
        const tint: engine.Color = if (ship.invulnerable) invulnerable_tint else .white;
        view.sprites.drawShip(frame, ship.player, centreOf(ship.position, box), tint);
        var buffer: [4]u8 = undefined;
        const number = std.fmt.bufPrint(&buffer, "{d}", .{ship.player + 1}) catch unreachable;
        // Behind the Ship, or in front of it when the Ship is at the left edge.
        const size = 20;
        const left: i32 = @intFromFloat(ship.position.x);
        const x = if (left >= 16) left - 14 else left + @as(i32, @intFromFloat(box.width)) + 4;
        const y: i32 = @intFromFloat(ship.position.y + box.height / 2 - size / 2);
        frame.drawText(number, x, y, size, sprites.player_colors[ship.player % sprites.player_colors.len]);
    }
};

const testing = std.testing;

fn shipOf(player: u8) scene_.Ship {
    return .{ .player = player, .position = .{ .x = 0, .y = 0 }, .hit_points = 3, .invulnerable = false };
}

test "a destroyed Player stays listed until the next join window" {
    var view: View = .{ .sprites = undefined, .starfield = undefined };
    var joining: Scene = .{ .phase = .join_window };
    joining.ships.append(shipOf(0));
    joining.ships.append(shipOf(2));
    view.show(joining);
    var playing: Scene = .{ .phase = .playing };
    playing.ships.append(shipOf(0));
    view.show(playing);
    try testing.expect(view.isDestroyed(2));
    try testing.expect(!view.isDestroyed(0));
    try testing.expect(!view.isDestroyed(1)); // never in the Match
    try testing.expectEqual(2, view.players.count());

    view.show(.{ .phase = .game_over });
    try testing.expect(!view.isDestroyed(2)); // game over has its own screen
    try testing.expectEqual(2, view.players.count());
    view.show(.{ .phase = .join_window });
    try testing.expectEqual(0, view.players.count());
}

test "hits and Announcements start the Client's own effects" {
    var view: View = .{ .sprites = undefined, .starfield = undefined };
    var before: Scene = .{};
    before.bolts.append(.{ .id = 1, .position = .{ .x = 300, .y = 100 } });
    before.pods.append(.{ .id = 4, .position = .{ .x = 340, .y = 90 } });
    view.show(before);
    view.enemyDestroyed(.{ .x = 340, .y = 90 });
    view.show(.{});
    try testing.expectEqual(1, view.effects.impact.len);
    try testing.expectEqual(1, view.effects.explosion.len);
    // Centred on the Pod, whose box it takes from the Scene before.
    const pod = rules.enemies.pod.box;
    try testing.expectEqual(Position{ .x = 340 + pod.width / 2, .y = 90 + pod.height / 2 }, view.effects.explosion.columns.centre[0]);

    view.shipDestroyed(.{ .x = 10, .y = 20 });
    try testing.expectEqual(1, view.effects.ship_explosion.len);
}
