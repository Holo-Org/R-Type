//! Where the Match keeps its entities: one Engine table per kind of entity,
//! each as big as its kind's budget (ADR 0006).

const std = @import("std");
const ecs = @import("engine_headless").ecs;
const protocol = @import("protocol.zig");
const max_players = protocol.max_players;

/// An entity's top-left corner.
pub const Position = struct { x: f32, y: f32 };
/// Per Tick.
pub const Velocity = struct { x: f32, y: f32 };

/// Darts and Pods share it, so their tables hold this many rows each, and the
/// Wave spawner checks it before it spawns a Wave.
pub const enemy_budget = 32;

pub const World = struct {
    ships: ecs.Table(max_players, struct {
        player: u8,
        position: Position,
        hit_points: u8,
        /// Ticks of invulnerability left.
        invulnerable: u16,
        /// Ticks until the Ship may fire again.
        cooldown: u8,
    }),
    ship_projectiles: ecs.Table(32, struct {
        /// A Player index, not an entity: it outlives its Ship.
        owner: u8,
        position: Position,
        velocity: Velocity,
        /// Used up by a hit: removed with the off-screen ones.
        used: bool,
    }),
    darts: ecs.Table(enemy_budget, struct {
        position: Position,
        velocity: Velocity,
        /// The height its sine wave is centred on.
        wave_y: f32,
        /// Ticks since it spawned.
        age: u16,
        hit_points: u8,
    }),
    pods: ecs.Table(enemy_budget, struct {
        position: Position,
        velocity: Velocity,
        hit_points: u8,
        /// Ticks until its next shot, counted once fully on screen.
        cooldown: u16,
    }),
    enemy_projectiles: ecs.Table(64, struct {
        position: Position,
        velocity: Velocity,
        used: bool,
    }),

    pub const empty: World = .{
        .ships = .empty,
        .ship_projectiles = .empty,
        .darts = .empty,
        .pods = .empty,
        .enemy_projectiles = .empty,
    };

    pub fn enemyCount(w: *const World) usize {
        return w.darts.len + w.pods.len;
    }
};

// Even with every table full, a Snapshot fits in one datagram (ADR 0005):
// checked over the tables' capacities, not over runtime budgets. The sizes
// are the layout settled in #4; "Encode protocol v1's messages" (#26) owns it.
comptime {
    const header_bytes = 22; // packet header, Tick, phase, join-window Tick, one count per section
    const entry_bytes = .{ .ships = 7, .ship_projectiles = 5, .darts = 5, .pods = 5, .enemy_projectiles = 5 };
    var worst: usize = header_bytes;
    for (@typeInfo(World).@"struct".fields) |table| worst += table.type.capacity * @field(entry_bytes, table.name);
    if (worst > protocol.max_datagram_size) @compileError("a Snapshot of full tables would not fit in one datagram");
}

test "a world starts empty" {
    const w: World = .empty;
    try std.testing.expectEqual(0, w.enemyCount());
    try std.testing.expectEqual(0, w.ships.len);
}
