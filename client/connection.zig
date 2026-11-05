//! How the Client reaches a Match: when to send a connect, why it is still
//! waiting, and when the Server counts as lost. It counts in Client Ticks and
//! sends nothing itself; `run` asks it.
//!
//! A connect goes out 1 s after the wait begins, then after twice as long
//! each time nobody answers, up to 10 s. Any answer from the Server, a
//! Refusal included, brings the wait back to 1 s, and so does losing it.

const std = @import("std");
const game = @import("game");
const RefusalReason = game.protocol.RefusalReason;
const tick_rate = game.rules.tick_rate;

const first_wait: u32 = 1 * tick_rate;
const longest_wait: u32 = 10 * tick_rate;
/// Ticks without a datagram from the Server after which it counts as lost.
pub const silence_limit: u32 = 3 * tick_rate;

/// Why the Client is not in a Match.
pub const Waiting = enum {
    /// No answer from the Server yet.
    connecting,
    match_full,
    already_started,
    /// The Server went silent: the Client rejoins as a new Player.
    lost,
};

pub const Connection = struct {
    /// Null once the Server took the Client.
    waiting: ?Waiting = .connecting,
    /// When the Client began waiting, to show the seconds spent.
    since: u32,
    next_connect: u32,
    /// Before the connect after the next.
    wait: u32,
    /// When the last datagram from the Server came.
    last_heard: u32,

    pub fn init(now: u32) Connection {
        return .{ .since = now, .next_connect = now +% first_wait, .wait = 2 * first_wait, .last_heard = now };
    }

    /// Whether to send a connect at Tick `now`.
    pub fn connectDue(c: *Connection, now: u32) bool {
        if (c.waiting == null or !reached(now, c.next_connect)) return false;
        c.next_connect = now +% c.wait;
        c.wait = @min(2 * c.wait, longest_wait);
        return true;
    }

    /// Any datagram from the Server.
    pub fn heard(c: *Connection, now: u32) void {
        c.last_heard = now;
    }

    pub fn accepted(c: *Connection) void {
        c.waiting = null;
    }

    pub fn refused(c: *Connection, now: u32, reason: RefusalReason) void {
        c.waitAgain(now, switch (reason) {
            .match_full => .match_full,
            .already_started => .already_started,
        });
    }

    /// The Server dropped the Client, as it announced: try again at once.
    pub fn dropped(c: *Connection, now: u32) void {
        c.waitAgain(now, .connecting);
    }

    /// Whether the Server, once it took the Client, just went silent for too
    /// long; the Client then waits again, as `lost`.
    pub fn checkLost(c: *Connection, now: u32) bool {
        if (c.waiting != null or now -% c.last_heard <= silence_limit) return false;
        c.waitAgain(now, .lost);
        return true;
    }

    /// Whole seconds spent waiting.
    pub fn secondsWaiting(c: *const Connection, now: u32) u32 {
        return (now -% c.since) / tick_rate;
    }

    fn waitAgain(c: *Connection, now: u32, why: Waiting) void {
        if (c.waiting == null) c.since = now;
        c.waiting = why;
        c.next_connect = now +% first_wait;
        c.wait = 2 * first_wait;
        c.last_heard = now;
    }
};

/// Whether Tick `at` has come, even across the Tick counter wrapping.
fn reached(now: u32, at: u32) bool {
    return now -% at < 1 << 31;
}

const testing = std.testing;

/// The Ticks, from `from` on and before `until`, at which connects go out.
fn connectTicks(c: *Connection, from: u32, until: u32, out: []u32) []u32 {
    var count: usize = 0;
    var now = from;
    while (now != until) : (now +%= 1) {
        if (c.connectDue(now)) {
            out[count] = now - from;
            count += 1;
        }
    }
    return out[0..count];
}

test "connects after 1 s, then waits twice as long each time, up to 10 s" {
    var c: Connection = .init(0);
    var buffer: [16]u32 = undefined;
    const s = tick_rate;
    try testing.expectEqualSlices(u32, &.{ 1 * s, 3 * s, 7 * s, 15 * s, 25 * s, 35 * s }, connectTicks(&c, 0, 40 * s, &buffer));
}

test "any answer brings the wait back to 1 s" {
    var c: Connection = .init(0);
    var buffer: [16]u32 = undefined;
    _ = connectTicks(&c, 0, 20 * tick_rate, &buffer);
    c.refused(20 * tick_rate, .already_started);
    try testing.expectEqual(.already_started, c.waiting);
    const ticks = connectTicks(&c, 20 * tick_rate, 24 * tick_rate, &buffer);
    try testing.expectEqual(tick_rate, ticks[0]);
    // The seconds keep counting from when the Client began waiting.
    try testing.expectEqual(24, c.secondsWaiting(24 * tick_rate));
}

test "once taken, the Client sends no connect, and loses a Server silent for 3 s" {
    var c: Connection = .init(0);
    c.accepted();
    try testing.expect(!c.connectDue(5 * tick_rate));
    c.heard(100);
    try testing.expect(!c.checkLost(100 + silence_limit));
    try testing.expect(c.checkLost(101 + silence_limit));
    try testing.expectEqual(.lost, c.waiting);
    try testing.expectEqual(0, c.secondsWaiting(101 + silence_limit));
    try testing.expect(!c.checkLost(1000)); // waiting already
    try testing.expect(c.connectDue(101 + silence_limit + tick_rate));
}

test "the Tick counter wrapping changes nothing" {
    const start: u32 = std.math.maxInt(u32) - 30;
    var c: Connection = .init(start);
    try testing.expect(!c.connectDue(start +% tick_rate -% 1));
    try testing.expect(c.connectDue(start +% tick_rate));
    c.accepted();
    c.heard(start +% tick_rate);
    try testing.expect(!c.checkLost(start +% tick_rate +% silence_limit));
}
