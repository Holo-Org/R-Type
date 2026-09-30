//! The rules of a Match: who plays, how Ships move, when a silent Player is dropped.

const std = @import("std");
const Endpoint = @import("engine_headless").net.Endpoint;
const protocol = @import("protocol.zig");
const max_players = protocol.max_players;

pub const world_width = 1280;
pub const world_height = 720;
/// A 33x17 sprite drawn at twice its size.
pub const ship_width = 66;
pub const ship_height = 34;
/// Pixels per Tick.
pub const ship_speed = 6;
/// Ticks per second.
pub const tick_rate = 60;
/// Ticks a Player may stay silent before being dropped.
pub const silence_limit: u32 = 3 * tick_rate;

/// A Player of the Match, as the Server knows it.
pub const Player = struct {
    peer: Endpoint,
    /// Server Tick of the Player's last packet.
    last_heard: u32,
    /// Client Tick of the newest input applied.
    last_input: u32 = 0,
    buttons: protocol.Buttons = .{},
    x: i32,
    y: i32,
};

/// Player indices, such as the ones a Tick dropped.
pub const PlayerSet = std.StaticBitSet(max_players);

pub const Match = struct {
    players: [max_players]?Player = @splat(null),
    tick: u32 = 0,

    /// The Player index of `peer`, joining it if it is new; null if the Match is full.
    pub fn join(m: *Match, peer: Endpoint) ?u8 {
        if (m.find(peer)) |existing| return existing; // a repeated connect, after a lost accept
        for (&m.players, 0..) |*slot, index| {
            if (slot.* != null) continue;
            const player: u8 = @intCast(index);
            slot.* = .{ .peer = peer, .last_heard = m.tick, .x = 64, .y = 90 + 160 * @as(i32, player) };
            return player;
        }
        return null;
    }

    pub fn find(m: *const Match, peer: Endpoint) ?u8 {
        for (m.players, 0..) |slot, index| {
            const player = slot orelse continue;
            if (player.peer.eql(peer)) return @intCast(index);
        }
        return null;
    }

    pub fn leave(m: *Match, player: u8) void {
        if (player < max_players) m.players[player] = null;
    }

    /// Records the newest buttons held by a Player; also proves it is alive.
    pub fn receive(m: *Match, player: u8, input: protocol.Input) void {
        if (player >= max_players) return;
        if (m.players[player]) |*state| {
            state.last_heard = m.tick;
            // Datagrams can arrive out of order: never go back to older buttons.
            const newest = input.recent[0];
            if (newest.tick > state.last_input) {
                state.last_input = newest.tick;
                state.buttons = newest.buttons;
            }
        }
    }

    /// Advances one Tick: moves every Ship, then drops and returns the
    /// Players who have been silent for longer than `silence_limit`.
    pub fn step(m: *Match) PlayerSet {
        m.tick +%= 1;
        var dropped: PlayerSet = .empty;
        for (&m.players, 0..) |*slot, index| {
            const player = if (slot.*) |*player| player else continue;
            if (m.tick -% player.last_heard > silence_limit) {
                slot.* = null;
                dropped.set(index);
                continue;
            }
            const held = player.buttons;
            const dx = @as(i32, @intFromBool(held.right)) - @intFromBool(held.left);
            const dy = @as(i32, @intFromBool(held.down)) - @intFromBool(held.up);
            player.x = std.math.clamp(player.x + dx * ship_speed, 0, world_width - ship_width);
            player.y = std.math.clamp(player.y + dy * ship_speed, 0, world_height - ship_height);
        }
        return dropped;
    }

    pub fn snapshot(m: *const Match) protocol.Snapshot {
        var s: protocol.Snapshot = .{ .tick = m.tick };
        for (m.players, 0..) |slot, index| {
            const player = slot orelse continue;
            s.add(.{
                .player = @intCast(index),
                // Clamped by step() to the world, which fits in a u16.
                .x = @intCast(player.x),
                .y = @intCast(player.y),
            });
        }
        return s;
    }

    pub fn playerCount(m: *const Match) usize {
        var count: usize = 0;
        for (m.players) |slot| count += @intFromBool(slot != null);
        return count;
    }
};

const testing = std.testing;

test "four Players join and a fifth is refused" {
    var m: Match = .{};
    for (0..4) |port| {
        const expected: ?u8 = @intCast(port);
        try testing.expectEqual(expected, m.join(.loopback(@intCast(port))));
    }
    try testing.expectEqual(2, m.join(.loopback(2))); // a repeated connect keeps its index
    try testing.expectEqual(null, m.join(.loopback(9)));
    m.leave(1);
    try testing.expectEqual(1, m.join(.loopback(9))); // a free slot is reused
}

test "Ships move with the newest input and stay in the world" {
    var m: Match = .{};
    const player = m.join(.loopback(1)).?;
    const input = struct {
        fn of(tick: u32, buttons: protocol.Buttons) protocol.Input {
            return .{ .recent = @splat(.{ .tick = tick, .buttons = buttons }) };
        }
    }.of;
    m.receive(player, input(2, .{ .left = true, .up = true }));
    m.receive(player, input(1, .{ .right = true })); // older: ignored
    for (0..100) |_| _ = m.step();
    const ship = m.snapshot().shipSlice()[0];
    try testing.expectEqual(0, ship.x);
    try testing.expectEqual(0, ship.y);
}

test "a silent Player is dropped after three seconds" {
    var m: Match = .{};
    _ = m.join(.loopback(1));
    for (0..silence_limit) |_| try testing.expectEqual(0, m.step().count());
    const dropped = m.step();
    try testing.expect(dropped.isSet(0) and dropped.count() == 1);
    try testing.expectEqual(0, m.playerCount());
}
