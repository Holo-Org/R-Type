//! The Client's own World: what only the Client draws, such as explosions and
//! impacts (ADR 0006). Each effect plays its animation once, from where it
//! was spawned, and is removed when the animation ends.

const std = @import("std");
const ecs = @import("engine_headless").ecs;
const game = @import("game");
const sprites = @import("sprites.zig");
const Position = game.world.Position;

pub const Kind = enum {
    /// An Enemy destroyed.
    explosion,
    /// A Ship destroyed.
    ship_explosion,
    /// A Ship's Projectile hitting an Enemy.
    impact,

    pub fn animation(kind: Kind) sprites.Animation {
        return switch (kind) {
            .explosion => sprites.explosion,
            .ship_explosion => sprites.ship_explosion,
            .impact => sprites.impact,
        };
    }
};

const Effect = struct {
    centre: Position,
    /// Seconds since it was spawned.
    age: f32,
};

/// One table per Kind, named after it, each as big as what can cause that
/// effect at once: every Enemy, every Ship, every Ship's Projectile.
pub const Effects = struct {
    explosion: ecs.Table(game.world.enemy_budget, Effect),
    ship_explosion: ecs.Table(game.protocol.max_players, Effect),
    impact: ecs.Table(@FieldType(game.world.World, "ship_projectiles").capacity, Effect),

    pub const empty: Effects = .{ .explosion = .empty, .ship_explosion = .empty, .impact = .empty };

    /// Starts an effect centred on `centre`. It is left out when its table
    /// is full: it is only a picture.
    pub fn spawn(effects: *Effects, kind: Kind, centre: Position) void {
        switch (kind) {
            inline else => |k| _ = @field(effects, @tagName(k)).spawn(.{ .centre = centre, .age = 0 }),
        }
    }

    /// Ages every effect, and removes the ones whose animation has ended.
    pub fn advance(effects: *Effects, seconds: f32) void {
        for (ecs.query(effects, .{.age})) |rows| {
            for (rows.age) |*age| age.* += seconds;
        }
        inline for (comptime std.enums.values(Kind)) |kind| {
            @field(effects, @tagName(kind)).removeIf(kind.animation().duration(), ended);
        }
    }

    pub fn count(effects: *const Effects) usize {
        var total: usize = 0;
        inline for (comptime std.enums.values(Kind)) |kind| total += @field(effects, @tagName(kind)).len;
        return total;
    }
};

fn ended(duration: f32, _: ecs.Id, effect: Effect) bool {
    return effect.age >= duration;
}

const testing = std.testing;

test "an effect lasts as long as its animation" {
    var effects: Effects = .empty;
    effects.spawn(.explosion, .{ .x = 10, .y = 20 });
    effects.spawn(.impact, .{ .x = 30, .y = 40 });
    try testing.expectEqual(2, effects.count());

    effects.advance(Kind.impact.animation().duration() + 0.01);
    try testing.expectEqual(1, effects.count()); // the impact is shorter
    try testing.expectEqual(1, effects.explosion.len);

    effects.advance(Kind.explosion.animation().duration());
    try testing.expectEqual(0, effects.count());
}

test "effects beyond a table's capacity are left out" {
    var effects: Effects = .empty;
    for (0..game.protocol.max_players + 2) |_| effects.spawn(.ship_explosion, .{ .x = 0, .y = 0 });
    try testing.expectEqual(game.protocol.max_players, effects.ship_explosion.len);
}
