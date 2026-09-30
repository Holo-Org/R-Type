//! The messages exchanged by the Server and the Clients, and their wire format.
//!
//! Every datagram is one packet: an 8-byte header, then the message body.
//! All integers are little-endian.
//!
//!     header       u16 protocol id ("RT"), u8 version, u8 message type, u32 sequence
//!     connect      (empty)                                          Client -> Server
//!     accept       u8 Player index                                  Server -> Client
//!     reject       u8 reason                                        Server -> Client
//!     input        3 x (u32 Client Tick, u8 buttons), newest first  Client -> Server
//!     snapshot     u32 Server Tick, u8 Ship count (0-4),
//!                  count x (u8 Player index, u16 x, u16 y)          Server -> Client
//!     disconnect   (empty)                                          Client -> Server
//!     player_left  u8 Player index                                  Server -> Client
//!
//! The sequence counts the datagrams sent by each peer; receivers use it to
//! ignore datagrams that arrive out of order.
//!
//! No message has a hand-written encoder or decoder: the Engine's
//! `ByteWriter.write` and `ByteReader.read` derive them from the types below
//! at compile time, so the order of a struct's fields is its wire layout. The
//! types only add their value checks (`validate`), and the snapshot, whose
//! length varies, spells out its own encoding.

const std = @import("std");
const bytes = @import("engine_headless").bytes;
const net = @import("engine_headless").net;
const ByteReader = bytes.ByteReader;
const ByteWriter = bytes.ByteWriter;

pub const protocol_id: u16 = std.mem.readInt(u16, "RT", .little);
pub const protocol_version: u8 = 1;
pub const max_datagram_size = net.max_datagram_size;
pub const max_players = 4;
pub const input_history = 3;

/// The message type byte of each message.
pub const MessageType = enum(u8) {
    connect = 1,
    accept,
    reject,
    input,
    snapshot,
    disconnect,
    player_left,
};

/// The buttons a Player holds, one bit each, `up` in the lowest bit.
pub const Buttons = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    fire: bool = false,
    /// Bits that name no button: the decoder rejects a datagram that sets one.
    _: u3 = 0,
};

/// The buttons a Player held during one Client Tick.
pub const InputState = struct {
    tick: u32 = 0,
    buttons: Buttons = .{},
};

/// The last `input_history` input states, newest first, so that one lost
/// datagram loses no input.
pub const Input = struct {
    recent: [input_history]InputState = @splat(.{}),

    pub fn validate(input: Input) error{BadValue}!void {
        for (input.recent[0 .. input_history - 1], input.recent[1..]) |newer, older| {
            if (newer.tick < older.tick) return error.BadValue;
        }
    }
};

/// A Player's index in the Match, from 0: the body of accept and player_left.
pub const PlayerId = struct {
    player: u8,

    pub fn validate(id: PlayerId) error{BadValue}!void {
        if (id.player >= max_players) return error.BadValue;
    }
};

pub const RejectReason = enum(u8) { match_full = 1 };

pub const Reject = struct {
    reason: RejectReason,
};

pub const ShipState = struct {
    player: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,
};

/// Where the Ships are at one Server Tick: up to `max_players` of them.
pub const Snapshot = struct {
    tick: u32 = 0,
    /// Zig has no private fields: only `add` keeps this at most `max_players`.
    ship_count: u8 = 0,
    ships: [max_players]ShipState = @splat(.{}),

    /// Adds a Ship; any beyond `max_players` are left out.
    pub fn add(snapshot: *Snapshot, ship: ShipState) void {
        if (snapshot.ship_count >= max_players) return;
        snapshot.ships[snapshot.ship_count] = ship;
        snapshot.ship_count += 1;
    }

    pub fn shipSlice(snapshot: *const Snapshot) []const ShipState {
        return snapshot.ships[0..@min(snapshot.ship_count, max_players)];
    }

    /// On the wire, only the Ships present follow their count.
    pub fn writeTo(snapshot: Snapshot, out: *ByteWriter) void {
        const ships = snapshot.shipSlice();
        out.int(u32, snapshot.tick);
        out.int(u8, @intCast(ships.len));
        for (ships) |ship| out.write(ship);
    }

    /// Reads the Ships one at a time: like the C++ and Rust decoders, a bad
    /// Ship is rejected before the next one is read.
    pub fn readFrom(in: *ByteReader) bytes.ReadError!Snapshot {
        var snapshot: Snapshot = .{ .tick = try in.int(u32) };
        const count = try in.int(u8);
        // Checked before use: an attacker-chosen count never sizes or indexes anything.
        if (count > max_players) return error.BadValue;
        var seen: std.StaticBitSet(max_players) = .empty;
        for (0..count) |_| {
            const ship = try in.read(ShipState);
            // No such Player, or one twice.
            if (ship.player >= max_players or seen.isSet(ship.player)) return error.BadValue;
            seen.set(ship.player);
            snapshot.add(ship);
        }
        return snapshot;
    }
};

pub const Message = union(MessageType) {
    connect,
    accept: PlayerId,
    reject: Reject,
    input: Input,
    snapshot: Snapshot,
    disconnect,
    player_left: PlayerId,
};

pub const Packet = struct {
    sequence: u32,
    message: Message,
};

/// Why a datagram is not a packet.
pub const DecodeError = error{
    TooLong,
    Truncated,
    BadProtocol,
    BadVersion,
    UnknownType,
    BadValue,
    TrailingBytes,
};

/// Every decode error, in the order the fuzz test tallies them.
pub const decode_errors = [_]DecodeError{
    error.TooLong,
    error.Truncated,
    error.BadProtocol,
    error.BadVersion,
    error.UnknownType,
    error.BadValue,
    error.TrailingBytes,
};

pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.TooLong => "too long",
        error.Truncated => "truncated",
        error.BadProtocol => "bad protocol id",
        error.BadVersion => "bad version",
        error.UnknownType => "unknown message type",
        error.BadValue => "value out of range",
        error.TrailingBytes => "trailing bytes",
    };
}

const Header = struct {
    protocol_id: u16,
    version: u8,
    kind: u8,
    sequence: u32,
};

/// An encoded packet, held in place: encoding never allocates.
pub const Encoded = struct {
    buffer: [max_datagram_size]u8 = undefined,
    len: usize = 0,

    pub fn bytes(encoded: *const Encoded) []const u8 {
        return encoded.buffer[0..encoded.len];
    }
};

pub fn encode(packet: Packet) Encoded {
    var encoded: Encoded = .{};
    var out: ByteWriter = .init(&encoded.buffer);
    out.write(Header{
        .protocol_id = protocol_id,
        .version = protocol_version,
        .kind = @intFromEnum(packet.message),
        .sequence = packet.sequence,
    });
    switch (packet.message) {
        inline else => |body| out.write(body),
    }
    // The largest message is a few dozen bytes, so this is a programming error.
    if (!out.ok) @panic("packet does not fit in a datagram");
    encoded.len = out.written;
    return encoded;
}

/// Decodes one datagram. Takes no allocator, and rejects anything but exactly
/// one well-formed packet. The checks run in the same order as in the C++ and
/// Rust decoders, so that all three tally rejected datagrams alike.
pub fn decode(datagram: []const u8) DecodeError!Packet {
    if (datagram.len > max_datagram_size) return error.TooLong;
    var in: ByteReader = .init(datagram);
    const header = try in.read(Header);
    if (header.protocol_id != protocol_id) return error.BadProtocol;
    if (header.version != protocol_version) return error.BadVersion;
    const kind = std.enums.fromInt(MessageType, header.kind) orelse return error.UnknownType;
    const message: Message = switch (kind) {
        // One branch per message type, generated at compile time.
        inline else => |tag| @unionInit(
            Message,
            @tagName(tag),
            try in.read(@FieldType(Message, @tagName(tag))),
        ),
    };
    if (in.remaining() != 0) return error.TrailingBytes;
    return .{ .sequence = header.sequence, .message = message };
}

const testing = std.testing;

fn withHeader(comptime kind: u8, comptime body: []const u8) []const u8 {
    return .{ 'R', 'T', 1, kind, 0x04, 0x03, 0x02, 0x01 } ++ body;
}

fn expectBytes(expected: []const u8, message: Message) !void {
    const encoded = encode(.{ .sequence = 0x01020304, .message = message });
    try testing.expectEqualSlices(u8, expected, encoded.bytes());
}

test "the layout matches the wire format" {
    // The example in the POC's report: an accept for Player 2, sequence 0x01020304.
    try expectBytes(&.{ 0x52, 0x54, 0x01, 0x02, 0x04, 0x03, 0x02, 0x01, 0x02 }, .{ .accept = .{ .player = 2 } });
    try expectBytes(withHeader(1, &.{}), .connect);
    try expectBytes(withHeader(3, &.{1}), .{ .reject = .{ .reason = .match_full } });
    try expectBytes(withHeader(4, &.{ 0x0D, 0x0C, 0x0B, 0x0A, 0x11, 7, 0, 0, 0, 0, 6, 0, 0, 0, 8 }), .{ .input = .{ .recent = .{
        .{ .tick = 0x0A0B0C0D, .buttons = .{ .up = true, .fire = true } },
        .{ .tick = 7, .buttons = .{} },
        .{ .tick = 6, .buttons = .{ .right = true } },
    } } });
    var snapshot: Snapshot = .{ .tick = 9 };
    snapshot.add(.{ .player = 1, .x = 0x0102, .y = 0x0304 });
    snapshot.add(.{ .player = 3, .x = 5, .y = 6 });
    try expectBytes(withHeader(5, &.{ 9, 0, 0, 0, 2, 1, 0x02, 0x01, 0x04, 0x03, 3, 5, 0, 6, 0 }), .{ .snapshot = snapshot });
    try expectBytes(withHeader(6, &.{}), .disconnect);
    try expectBytes(withHeader(7, &.{3}), .{ .player_left = .{ .player = 3 } });
}

test "decodes what it encodes" {
    var snapshot: Snapshot = .{ .tick = std.math.maxInt(u32) };
    snapshot.add(.{});
    const messages = [_]Message{
        .connect,
        .{ .accept = .{ .player = 3 } },
        .{ .reject = .{ .reason = .match_full } },
        .{ .input = .{} },
        .{ .snapshot = snapshot },
        .disconnect,
        .{ .player_left = .{ .player = 0 } },
    };
    for (messages) |message| {
        const packet: Packet = .{ .sequence = 42, .message = message };
        try testing.expectEqualDeep(packet, try decode(encode(packet).bytes()));
    }
}

test "rejects malformed datagrams" {
    const too_long: [max_datagram_size + 1]u8 = @splat(0);
    try testing.expectError(error.TooLong, decode(&too_long));
    try testing.expectError(error.Truncated, decode(&.{}));
    try testing.expectError(error.Truncated, decode(withHeader(1, &.{})[0..7]));
    try testing.expectError(error.BadProtocol, decode(&.{ 'R', 'X', 1, 1, 0, 0, 0, 0 }));
    try testing.expectError(error.BadVersion, decode(&.{ 'R', 'T', 2, 1, 0, 0, 0, 0 }));
    try testing.expectError(error.UnknownType, decode(withHeader(0, &.{})));
    try testing.expectError(error.UnknownType, decode(withHeader(8, &.{})));
    try testing.expectError(error.Truncated, decode(withHeader(2, &.{})));
    try testing.expectError(error.BadValue, decode(withHeader(2, &.{4})));
    try testing.expectError(error.BadValue, decode(withHeader(3, &.{2})));
    try testing.expectError(error.TrailingBytes, decode(withHeader(1, &.{0})));
    // Input: unknown button bits, ticks out of order, and truncation first.
    const unknown_button = [_]u8{ 0, 0, 0, 0, 0x20 } ++ [_]u8{0} ** 10;
    try testing.expectError(error.BadValue, decode(withHeader(4, &unknown_button)));
    try testing.expectError(error.Truncated, decode(withHeader(4, unknown_button[0..14])));
    const out_of_order = [_]u8{ 0, 0, 0, 0, 0, 1 } ++ [_]u8{0} ** 9;
    try testing.expectError(error.BadValue, decode(withHeader(4, &out_of_order)));
    // Snapshot: too many Ships, a Player out of range, a Player twice.
    try testing.expectError(error.BadValue, decode(withHeader(5, &.{ 0, 0, 0, 0, 5 })));
    try testing.expectError(error.BadValue, decode(withHeader(5, &.{ 0, 0, 0, 0, 1, 4, 0, 0, 0, 0 })));
    const twice = [_]u8{ 0, 0, 0, 0, 2, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    try testing.expectError(error.BadValue, decode(withHeader(5, &twice)));
    try testing.expectError(error.Truncated, decode(withHeader(5, twice[0..12])));
}
