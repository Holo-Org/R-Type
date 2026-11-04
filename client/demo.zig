//! `--demo <seed>`: a Match run inside the Client, with no Server, to see
//! everything the Client draws before Snapshots carry it (#26). Player 1
//! plays from the keyboard, or `--script`; Players 2 to 4 fly scripted
//! patterns and fire in bursts, so that Enemies get through now and then and
//! the Match reaches game over. The same seed plays the same Waves.

const std = @import("std");
const game = @import("game");
const protocol = game.protocol;
const Actions = protocol.Actions;
const Match = game.match.Match;

/// Unattended play: every pattern flies a square, starting on a different
/// side, and fires every two seconds.
pub fn scriptedActions(pattern: u32, tick: u32) Actions {
    const legs = [_]Actions{ .{ .right = true }, .{ .down = true }, .{ .left = true }, .{ .up = true } };
    const leg_ticks = 45;
    var actions = legs[((tick / leg_ticks) +% pattern) % legs.len];
    actions.fire = tick % (2 * game.rules.tick_rate) == 0;
    return actions;
}

/// Players 2 to 4 fire for this many Ticks out of three times as many.
const burst_ticks = 2 * game.rules.tick_rate;

pub const Demo = struct {
    match: Match,
    tick: u32 = 0,

    /// Four Players join a new Match at once.
    pub fn init(seed: u64) Demo {
        var demo: Demo = .{ .match = .init(.{ .seed = seed }) };
        for (0..protocol.max_players) |player| {
            _ = demo.match.join(.loopback(@intCast(player + 1))) catch unreachable;
        }
        return demo;
    }

    /// One Tick, with Player 1 holding `actions`.
    pub fn step(demo: *Demo, actions: Actions) game.match.Events {
        demo.tick +%= 1;
        for (0..protocol.max_players) |player| {
            var held = actions;
            if (player > 0) {
                held = scriptedActions(@intCast(player), demo.tick);
                held.fire = (demo.tick / burst_ticks + player) % 3 == 0;
            }
            demo.match.receive(@intCast(player), .{ .recent = @splat(.{ .tick = demo.tick, .actions = held }) });
        }
        return demo.match.step();
    }
};

test "a demo plays through game over into a new Match" {
    var demo: Demo = .init(1);
    var game_over = false;
    var explosions: usize = 0;
    for (0..5 * 60 * game.rules.tick_rate) |_| {
        const events = demo.step(.{});
        explosions += events.explosion_count;
        if (events.game_over) game_over = true;
        if (game_over and demo.match.phase == .join_window) break;
    }
    try std.testing.expect(explosions > 0);
    try std.testing.expect(game_over);
    try std.testing.expectEqual(.join_window, demo.match.phase);
}
