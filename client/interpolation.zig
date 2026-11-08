//! Drawing the Match between Snapshots. The Client keeps the last Scenes it
//! received, and draws a render Tick about two Snapshot intervals behind the
//! newest, so that the next Scene is usually there already: each entity then
//! slides from where it was in the Scene before the render Tick to where it
//! is in the one after. With one Snapshot per Tick, that is 2 Ticks (33 ms)
//! behind; with one every 4, 8 Ticks (133 ms), but as smooth.
//!
//! - The interval is the Tick gap between the last two Scenes received, so
//!   the Client needs no setting to follow the Server's `--snapshot-every`.
//! - The render Tick runs at 60 a second and never passes the newest Scene.
//!   More than an interval ahead of its target, it runs a tenth slower; more
//!   than an interval behind, as when Snapshots come again after a stall, it
//!   jumps to it.
//! - An entity is the same in two Scenes when its kind and id match, or its
//!   Player for a Ship. One found only in the earlier Scene stays where it
//!   was until the later one's Tick; one found only in the later appears at
//!   that Tick. One that moved more than `max_slide` does not slide: its id
//!   may have gone to another entity.
//! - When Snapshots stop, the render Tick stops at the newest Scene, which
//!   stays on screen without guessing ahead.

const std = @import("std");
const game = @import("game");
const scene_ = @import("scene.zig");
const Scene = scene_.Scene;
const Position = scene_.Position;
const tick_rate = game.rules.tick_rate;

/// Scenes kept: enough for two intervals at one Snapshot every 4 Ticks,
/// and a lost one.
const kept = 8;

/// Farther than this between two Scenes, in pixels, an entity jumps.
pub const max_slide = 64;

pub const Interpolation = struct {
    /// The Scenes received, oldest first.
    scenes: [kept]Scene = undefined,
    len: usize = 0,
    /// The Tick drawn, with its fraction; null until a Scene arrives.
    render: ?f64 = null,

    /// A new Scene, newer than every one kept: the Client drops the others.
    pub fn push(in: *Interpolation, scene: Scene) void {
        if (in.len > 0 and scene.tick -% in.newest().tick -% 1 >= 1 << 31) return; // not newer
        if (in.len == kept) {
            std.mem.copyForwards(Scene, in.scenes[0 .. kept - 1], in.scenes[1..kept]);
            in.len -= 1;
        }
        in.scenes[in.len] = scene;
        in.len += 1;
    }

    /// Forgets every Scene: the Connection is gone.
    pub fn reset(in: *Interpolation) void {
        in.* = .{};
    }

    fn newest(in: *const Interpolation) *const Scene {
        return &in.scenes[in.len - 1];
    }

    /// The Ticks between the last two Scenes; 1 with fewer.
    pub fn interval(in: *const Interpolation) f64 {
        if (in.len < 2) return 1;
        const gap = in.newest().tick -% in.scenes[in.len - 2].tick;
        return @floatFromInt(@max(1, gap));
    }

    /// How far behind the newest Scene the render Tick aims to be.
    pub fn delay(in: *const Interpolation) f64 {
        return 2 * in.interval();
    }

    /// Moves the render Tick on by `seconds` of the Client's clock.
    pub fn advance(in: *Interpolation, seconds: f32) void {
        // Until two Scenes give the interval, `current` shows the newest.
        if (in.len < 2) return;
        const newest_tick: f64 = @floatFromInt(in.newest().tick);
        const target = newest_tick - in.delay();
        var render = in.render orelse {
            in.render = target;
            return;
        };
        // More than an interval ahead, as Snapshots that stopped leave it,
        // or with a clock a little fast: a tenth slower, until the target
        // catches up. It never passes the newest Scene.
        const ticks: f64 = seconds * tick_rate;
        render += if (render > target + in.interval()) 0.9 * ticks else ticks;
        // Fell behind, when Snapshots come again after a stall: jump.
        if (render < target - in.interval()) render = target;
        in.render = @min(render, newest_tick);
    }

    /// The Scene to draw at the render Tick; null before the first.
    pub fn current(in: *const Interpolation) ?Scene {
        if (in.len == 0) return null;
        const render = in.render orelse return in.newest().*;
        // The last Scene at or before the render Tick, and the one after.
        var before: usize = 0;
        for (in.scenes[0..in.len], 0..) |*scene, index| {
            if (@as(f64, @floatFromInt(scene.tick)) <= render) before = index;
        }
        const from = &in.scenes[before];
        if (before + 1 == in.len) return from.*;
        const to = &in.scenes[before + 1];
        const span: f64 = @floatFromInt(to.tick -% from.tick);
        const t: f32 = @floatCast(std.math.clamp((render - @as(f64, @floatFromInt(from.tick))) / span, 0, 1));
        return between(from, to, t);
    }
};

/// `from`, with each entity moved `t` of the way to where it is in `to`.
pub fn between(from: *const Scene, to: *const Scene, t: f32) Scene {
    var scene = from.*;
    for (scene.ships.buffer[0..scene.ships.len]) |*ship| {
        for (to.ships.slice()) |later| {
            if (later.player == ship.player) ship.position = slide(ship.position, later.position, t);
        }
    }
    inline for (.{ "darts", "pods", "bolts", "orbs" }) |kind| {
        const list = &@field(scene, kind);
        for (list.buffer[0..list.len]) |*entity| {
            for (@field(to, kind).slice()) |later| {
                if (later.id == entity.id) entity.position = slide(entity.position, later.position, t);
            }
        }
    }
    return scene;
}

fn slide(a: Position, b: Position, t: f32) Position {
    if (@abs(b.x - a.x) > max_slide or @abs(b.y - a.y) > max_slide) return a;
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

const testing = std.testing;

/// One Tick of the Client's clock.
const tick_seconds: f32 = 1.0 / @as(f32, tick_rate);

fn sceneAt(tick: u32, dart_x: f32) Scene {
    var scene: Scene = .{ .tick = tick };
    scene.darts.append(.{ .id = 1, .position = .{ .x = dart_x, .y = 100 } });
    return scene;
}

test "an entity slides between two Scenes" {
    var from = sceneAt(10, 0);
    from.ships.append(.{ .player = 2, .position = .{ .x = 0, .y = 0 }, .hit_points = 3, .invulnerable = false });
    var to = sceneAt(14, 40);
    to.ships.append(.{ .player = 2, .position = .{ .x = 8, .y = 4 }, .hit_points = 3, .invulnerable = false });
    const halfway = between(&from, &to, 0.5);
    try testing.expectEqual(20, halfway.darts.slice()[0].position.x);
    try testing.expectEqual(Position{ .x = 4, .y = 2 }, halfway.ships.slice()[0].position);
}

test "an entity in one Scene only does not slide, and one too far jumps" {
    var from = sceneAt(10, 0);
    from.bolts.append(.{ .id = 7, .position = .{ .x = 300, .y = 50 } }); // gone in `to`
    var to = sceneAt(14, 0);
    to.darts.buffer[0].position.x = max_slide + 1; // the id went to another Dart
    to.orbs.append(.{ .id = 3, .position = .{ .x = 10, .y = 10 } }); // new in `to`
    const scene = between(&from, &to, 0.5);
    try testing.expectEqual(Position{ .x = 300, .y = 50 }, scene.bolts.slice()[0].position);
    try testing.expectEqual(0, scene.darts.slice()[0].position.x);
    try testing.expectEqual(0, scene.orbs.len);
}

test "the render Tick stays two intervals behind, and draws between Scenes" {
    var in: Interpolation = .{};
    try testing.expectEqual(null, in.current());
    var tick: u32 = 100;
    while (tick <= 140) : (tick += 4) { // one Snapshot every 4 Ticks
        in.push(sceneAt(tick, @floatFromInt(tick)));
        in.advance(4 * tick_seconds);
    }
    try testing.expectEqual(4, in.interval());
    try testing.expectApproxEqAbs(140 - 8, in.render.?, 0.001);
    try testing.expectApproxEqAbs(132, in.current().?.darts.slice()[0].position.x, 0.001);
    in.advance(2 * tick_seconds);
    try testing.expectApproxEqAbs(134, in.current().?.darts.slice()[0].position.x, 0.001);
}

test "when Snapshots stop, the newest Scene stays" {
    var in: Interpolation = .{};
    in.push(sceneAt(10, 10));
    in.push(sceneAt(11, 11));
    for (0..5) |_| in.advance(tick_seconds);
    try testing.expectEqual(11, in.render.?);
    try testing.expectEqual(11, in.current().?.darts.slice()[0].position.x);
    // They come again, far ahead: the render Tick jumps to two intervals behind.
    in.push(sceneAt(30, 30));
    in.push(sceneAt(31, 31));
    in.advance(tick_seconds);
    try testing.expectEqual(29, in.render.?);
}

test "a Scene older than the newest is dropped, and the oldest go first" {
    var in: Interpolation = .{};
    in.push(sceneAt(10, 0));
    in.push(sceneAt(9, 0));
    try testing.expectEqual(1, in.len);
    for (11..11 + kept) |tick| in.push(sceneAt(@intCast(tick), 0));
    try testing.expectEqual(kept, in.len);
    try testing.expectEqual(11, in.scenes[0].tick);
}
