//! A small reliable channel per Connection, beside the unreliable datagrams
//! (ADR 0002): its messages are acknowledged, resent until they are, and
//! handed over in the order they were sent.
//!
//! The channel sends nothing itself, and never makes a datagram wait. For
//! every datagram sent on the Connection, reliable or not, `outgoing` gives
//! the `Header` to write and the messages to add after it, if any; for every
//! datagram received, `incoming` takes them back. So:
//! - every datagram carries a sequence number, and acknowledges the latest
//!   sequence number received plus, one bit each, the 32 before it;
//! - a message goes into a datagram again when the datagram it last went into
//!   is still unacknowledged after the measured round trip plus 50 ms;
//! - `next` hands the messages received over in sending order: a later one
//!   waits for an earlier one, and a message received twice is handed once;
//! - at most `window` messages wait for an acknowledgement: `send` refuses
//!   one more, and the Connection then counts as timed out.
//!
//! What the messages mean, and how they are encoded, is the program's: a
//! message is any value of its `Message` type. `Header` and `Numbered` encode
//! with `bytes.ByteWriter`, when `Message` does. Nothing is allocated.

const std = @import("std");
const Io = std.Io;

/// Messages that may wait for an acknowledgement at once, per direction.
pub const window = 32;
/// Added to the measured round trip before a message is sent again.
pub const resend_margin: Io.Duration = .fromMilliseconds(50);
/// The round trip assumed until one is measured.
pub const initial_round_trip: Io.Duration = .fromMilliseconds(200);
/// Datagrams remembered for their acknowledgement: at 60 a second, about
/// 4 s, beyond which a late acknowledgement is ignored and the messages it
/// covered are simply sent again.
const datagram_history = 256;

/// What every datagram on a Connection starts with.
pub const Header = struct {
    /// This datagram's number, counted per direction from 1, wrapping.
    sequence: u16,
    /// The latest sequence number received; 0 until one arrives.
    ack: u16,
    /// Bit n set: sequence number `ack - 1 - n` was received too.
    ack_bits: u32,
};

/// A message, with its number on the channel, counted per direction from 0.
pub fn Numbered(comptime Message: type) type {
    return struct {
        id: u16,
        message: Message,
    };
}

pub fn Channel(comptime Message: type) type {
    return struct {
        const Self = @This();
        pub const Entry = Numbered(Message);

        pub const Outgoing = struct {
            header: Header,
            /// The messages to add after the header: a slice of `room`.
            messages: []const Entry,
        };

        // Sending. Sequence numbers start at 1, so that the 0 a peer
        // acknowledges before receiving anything matches no datagram sent.
        next_sequence: u16 = 1,
        /// The number the next message sent gets.
        next_id: u16 = 0,
        /// The oldest message not acknowledged yet.
        oldest_id: u16 = 0,
        /// Messages from `oldest_id` to `next_id`, at `id % window`.
        pending: [window]Pending = undefined,
        /// The datagrams sent, at `sequence % datagram_history`.
        sent: [datagram_history]Sent = @splat(.{}),
        /// Smoothed, as TCP does (RFC 6298): 7/8 of the old value, 1/8 of the
        /// new measurement.
        round_trip: Io.Duration = initial_round_trip,
        /// Messages put into a datagram again, since the channel was made.
        resent: u64 = 0,

        // Receiving.
        received: Received = .{},
        /// The number of the next message `next` hands over.
        next_expected: u16 = 0,
        /// Messages from `next_expected` on, at `id % window`.
        arrived: [window]?Entry = @splat(null),

        const Pending = struct {
            message: Message,
            acknowledged: bool,
            /// When the message last went into a datagram; null: not yet.
            last_sent: ?Io.Timestamp,
        };

        const Sent = struct {
            valid: bool = false,
            sequence: u16 = 0,
            at: Io.Timestamp = .zero,
            /// The messages this datagram carried: bit n is message
            /// `first_id + n`.
            first_id: u16 = 0,
            ids: u32 = 0,
        };

        /// Queues a message, which every later datagram may carry until it
        /// is acknowledged. Fails when `window` messages already wait: the
        /// peer has stopped acknowledging, so the Connection has timed out.
        pub fn send(c: *Self, message: Message) error{TimedOut}!void {
            if (c.waiting() == window) return error.TimedOut;
            c.pending[c.next_id % window] = .{ .message = message, .acknowledged = false, .last_sent = null };
            c.next_id +%= 1;
        }

        /// Messages sent and not acknowledged yet.
        pub fn waiting(c: *const Self) u16 {
            return c.next_id -% c.oldest_id;
        }

        /// Call for every datagram sent on the Connection: returns the header
        /// to write, and the messages to add after it, at most `room.len` of
        /// them, oldest first. Never waits for anything.
        pub fn outgoing(c: *Self, now: Io.Timestamp, room: []Entry) Outgoing {
            const sequence = c.next_sequence;
            c.next_sequence +%= 1;
            const resend_after = c.round_trip.nanoseconds + resend_margin.nanoseconds;
            var count: usize = 0;
            var ids: u32 = 0;
            var offset: u16 = 0;
            while (offset < c.waiting() and count < room.len) : (offset += 1) {
                const id = c.oldest_id +% offset;
                const pending = &c.pending[id % window];
                if (pending.acknowledged) continue;
                if (pending.last_sent) |last_sent| {
                    if (now.nanoseconds - last_sent.nanoseconds < resend_after) continue;
                    c.resent += 1;
                }
                pending.last_sent = now;
                room[count] = .{ .id = id, .message = pending.message };
                count += 1;
                ids |= @as(u32, 1) << @intCast(offset);
            }
            c.sent[sequence % datagram_history] = .{
                .valid = true,
                .sequence = sequence,
                .at = now,
                .first_id = c.oldest_id,
                .ids = ids,
            };
            return .{
                .header = .{ .sequence = sequence, .ack = c.received.latest, .ack_bits = c.received.bits },
                .messages = room[0..count],
            };
        }

        /// Call for every datagram received on the Connection, with its
        /// header and the messages after it. They come from the network, so
        /// any value is accepted, and only what is plausible is used.
        pub fn incoming(c: *Self, now: Io.Timestamp, header: Header, messages: []const Entry) void {
            c.received.note(header.sequence);

            c.acknowledge(now, header.ack);
            var bits = header.ack_bits;
            while (bits != 0) : (bits &= bits - 1) {
                c.acknowledge(now, header.ack -% (@ctz(bits) + 1));
            }
            while (c.waiting() > 0 and c.pending[c.oldest_id % window].acknowledged) c.oldest_id +%= 1;

            for (messages) |entry| {
                // Behind: handed over already. Too far ahead: the peer cannot
                // have sent it, since no more than `window` messages wait.
                if (entry.id -% c.next_expected >= window) continue;
                c.arrived[entry.id % window] = entry;
            }
        }

        /// The next message received, in sending order; null until it has
        /// arrived, even if later ones have.
        pub fn next(c: *Self) ?Message {
            const slot = &c.arrived[c.next_expected % window];
            const entry = slot.* orelse return null;
            // `incoming` keeps only the window's ids, each at its own slot.
            std.debug.assert(entry.id == c.next_expected);
            slot.* = null;
            c.next_expected +%= 1;
            return entry.message;
        }

        fn acknowledge(c: *Self, now: Io.Timestamp, sequence: u16) void {
            const sent = &c.sent[sequence % datagram_history];
            if (!sent.valid or sent.sequence != sequence) return; // never sent, already acknowledged, or forgotten
            sent.valid = false;
            const measured = @max(0, now.nanoseconds - sent.at.nanoseconds);
            c.round_trip.nanoseconds = @divTrunc(7 * c.round_trip.nanoseconds + measured, 8);
            var ids = sent.ids;
            while (ids != 0) : (ids &= ids - 1) {
                const id = sent.first_id +% @as(u16, @ctz(ids));
                // Behind `oldest_id`: acknowledged by an earlier datagram.
                if (id -% c.oldest_id < c.waiting()) c.pending[id % window].acknowledged = true;
            }
        }
    };
}

/// The sequence numbers received: the latest, and which of the 32 before it.
const Received = struct {
    latest: u16 = 0,
    bits: u32 = 0,

    fn note(r: *Received, sequence: u16) void {
        if (isNewer(sequence, r.latest)) {
            const ahead = sequence -% r.latest;
            // The old latest becomes bit `ahead - 1`, if it is still among the 32.
            r.bits = if (ahead > 32) 0 else @truncate((@as(u64, r.bits) << 1 | 1) << @intCast(ahead - 1));
            r.latest = sequence;
        } else {
            const behind = r.latest -% sequence;
            if (behind >= 1 and behind <= 32) r.bits |= @as(u32, 1) << @intCast(behind - 1);
        }
    }
};

/// Whether sequence number `a` comes after `b`, across wrapping: of the two
/// ways round, the shorter one counts.
pub fn isNewer(a: u16, b: u16) bool {
    return @as(i16, @bitCast(a -% b)) > 0;
}

const testing = std.testing;

fn at(milliseconds: i96) Io.Timestamp {
    return .{ .nanoseconds = milliseconds * std.time.ns_per_ms };
}

const TestChannel = Channel(u32);

/// Carries one datagram from `from` to `to`.
fn deliver(from: *TestChannel, to: *TestChannel, now: Io.Timestamp) void {
    var room: [4]TestChannel.Entry = undefined;
    const datagram = from.outgoing(now, &room);
    to.incoming(now, datagram.header, datagram.messages);
}

test "messages arrive in order, and are acknowledged" {
    var a: TestChannel = .{};
    var b: TestChannel = .{};
    for (0..3) |n| try a.send(@intCast(n));
    try testing.expectEqual(3, a.waiting());

    deliver(&a, &b, at(0));
    for (0..3) |n| try testing.expectEqual(n, b.next().?);
    try testing.expectEqual(null, b.next());

    deliver(&b, &a, at(30)); // b's next datagram acknowledges a's
    try testing.expectEqual(0, a.waiting());
    // The round trip moves an eighth of the way from 200 ms to the 30 ms measured.
    try testing.expectEqual(@divTrunc(7 * initial_round_trip.nanoseconds + 30 * std.time.ns_per_ms, 8), a.round_trip.nanoseconds);
}

test "a lost message is sent again after the round trip plus 50 ms, not before" {
    var a: TestChannel = .{};
    var b: TestChannel = .{};
    try a.send(7);
    var room: [4]TestChannel.Entry = undefined;
    try testing.expectEqual(1, a.outgoing(at(0), &room).messages.len); // lost

    try testing.expectEqual(0, a.outgoing(at(249), &room).messages.len);
    const again = a.outgoing(at(250), &room);
    try testing.expectEqual(1, again.messages.len);
    try testing.expectEqual(1, a.resent);
    b.incoming(at(250), again.header, again.messages);
    try testing.expectEqual(7, b.next().?);
}

test "a later message waits for an earlier one, and a duplicate is handed over once" {
    var b: TestChannel = .{};
    const header: Header = .{ .sequence = 1, .ack = 0, .ack_bits = 0 };
    b.incoming(at(0), header, &.{.{ .id = 1, .message = 11 }});
    try testing.expectEqual(null, b.next());
    b.incoming(at(0), header, &.{ .{ .id = 0, .message = 10 }, .{ .id = 1, .message = 11 } });
    try testing.expectEqual(10, b.next().?);
    try testing.expectEqual(11, b.next().?);
    b.incoming(at(0), header, &.{ .{ .id = 0, .message = 10 }, .{ .id = 1, .message = 11 } });
    try testing.expectEqual(null, b.next());
    // An id the peer cannot have sent yet is ignored.
    b.incoming(at(0), header, &.{.{ .id = 2 + window, .message = 99 }});
    try testing.expectEqual(null, b.next());
}

test "the window's worth of unacknowledged messages times the Connection out" {
    var a: TestChannel = .{};
    for (0..window) |n| try a.send(@intCast(n));
    try testing.expectError(error.TimedOut, a.send(window));
}

test "acknowledgements cover the latest datagram and the 32 before it, across wrapping" {
    var r: Received = .{};
    r.note(65535);
    r.note(1); // two ahead, across the wrap: 65535 becomes bit 1
    r.note(0); // late: bit 0
    try testing.expectEqual(1, r.latest);
    try testing.expectEqual(0b11, r.bits);
    r.note(34); // 33 ahead: 1 becomes bit 32, beyond the 32 kept
    try testing.expectEqual(0, r.bits);
    try testing.expect(isNewer(0, 65535) and !isNewer(65535, 0) and !isNewer(5, 5));
}

test "the header and numbered messages have a wire encoding" {
    const bytes = @import("bytes.zig");
    var buffer: [16]u8 = undefined;
    var out: bytes.ByteWriter = .init(&buffer);
    out.write(Header{ .sequence = 0x0102, .ack = 0x0304, .ack_bits = 0x08070605 });
    out.write(Numbered(u8){ .id = 0x0A09, .message = 0x0B });
    try testing.expect(out.ok);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3, 5, 6, 7, 8, 9, 10, 11 }, buffer[0..out.written]);
}

test "over a link that loses, delays and reorders, every message arrives once and in order" {
    // Both ends send a datagram every 16 ms, as at 60 Ticks a second. Each
    // datagram is lost one time in four, and the others take 40 to 120 ms,
    // which reorders them.
    const tick_ms = 16;
    const InFlight = struct { arrives_ms: i96, header: Header, messages: [4]TestChannel.Entry, count: usize };
    const Link = struct {
        queue: [64]?InFlight = @splat(null),

        fn put(link: *@This(), datagram: InFlight) void {
            for (&link.queue) |*slot| if (slot.* == null) {
                slot.* = datagram;
                return;
            };
            unreachable; // the test sizes the queue for its delays
        }

        fn arrive(link: *@This(), now_ms: i96, to: *TestChannel) void {
            for (&link.queue) |*slot| {
                const datagram = slot.* orelse continue;
                if (datagram.arrives_ms > now_ms) continue;
                to.incoming(at(now_ms), datagram.header, datagram.messages[0..datagram.count]);
                slot.* = null;
            }
        }
    };

    var prng: std.Random.DefaultPrng = .init(2026);
    const random = prng.random();
    var a: TestChannel = .{};
    var b: TestChannel = .{};
    var a_to_b: Link = .{};
    var b_to_a: Link = .{};
    var sent: u32 = 0;
    var handed_over: u32 = 0;

    var now_ms: i96 = 0;
    while (now_ms < 60_000) : (now_ms += tick_ms) {
        // A message about twice a second for the first 50 s, then silence,
        // so that everything left gets through.
        if (now_ms < 50_000 and random.uintLessThan(u32, 30) == 0) {
            try a.send(sent);
            sent += 1;
        }
        inline for (.{ .{ &a, &a_to_b }, .{ &b, &b_to_a } }) |end| {
            var room: [4]TestChannel.Entry = undefined;
            const out = end[0].outgoing(at(now_ms), &room);
            if (random.uintLessThan(u32, 4) != 0) {
                var datagram: InFlight = .{ .arrives_ms = now_ms + random.intRangeAtMost(i96, 40, 120), .header = out.header, .messages = undefined, .count = out.messages.len };
                @memcpy(datagram.messages[0..out.messages.len], out.messages);
                end[1].put(datagram);
            }
        }
        a_to_b.arrive(now_ms, &b);
        b_to_a.arrive(now_ms, &a);
        while (b.next()) |message| {
            try testing.expectEqual(handed_over, message);
            handed_over += 1;
        }
    }
    try testing.expect(sent > 50);
    try testing.expectEqual(sent, handed_over);
    try testing.expectEqual(0, a.waiting());
    try testing.expect(a.resent > 0);
}
