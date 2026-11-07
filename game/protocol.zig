//! The messages exchanged by the Server and the Clients, and their wire format.
//!
//! Every datagram is one packet: a 12-byte header, the message body, then the
//! Announcements it carries on the reliable channel. All integers are
//! little-endian; coordinates are an entity's top-left corner, in pixels, as i16.
//!
//!     header        u16 protocol id ("RT"), u8 version, u8 message type,
//!                   u16 sequence, u16 ack, u32 ack bits (the Engine's reliable.Header)
//!     connect       u8 padding (0)                                   Client -> Server
//!     accept        u8 Player index                                  Server -> Client
//!     refusal       u8 reason                                        Server -> Client
//!     input         3 x (u32 Client Tick, u8 Actions), newest first  Client -> Server
//!     snapshot      u32 Server Tick, u8 phase, u32 Tick the phase ends,
//!                   then five sections, each a u8 count and its entries:
//!                   Ships             (u8 Player index, i16 x, i16 y, u8 hit points, u8 flags)
//!                   Ship Projectiles  (u8 id, i16 x, i16 y)
//!                   Darts             (u8 id, i16 x, i16 y)
//!                   Pods              (u8 id, i16 x, i16 y)
//!                   Enemy Projectiles (u8 id, i16 x, i16 y)          Server -> Client
//!     disconnect    (empty)                                          Client -> Server
//!     reliable      u8 count, then count x (u16 id, Announcement)    after every body
//!     Announcement  u32 Server Tick, u8 kind, then the kind's body
//!
//! The header's sequence counts the datagrams each end of a Connection sends,
//! and acknowledges the latest one received and the 32 before it. The
//! Server's Announcements ride on its datagrams until acknowledged, numbered
//! so that each is handed over once, in order (ADR 0002). A Client's
//! datagrams carry none; it only acknowledges. Before a Connection exists
//! (connect, refusal), the header's last three fields are 0.
//!
//! No message has a hand-written encoder or decoder: the Engine's
//! `ByteWriter.write` and `ByteReader.read` derive them from the types below
//! at compile time, so the order of a struct's fields is its wire layout. The
//! types only add their value checks (`validate`), and the snapshot and the
//! announcement, whose length varies, spell out their own encoding.

const std = @import("std");
const bytes = @import("engine_headless").bytes;
const net = @import("engine_headless").net;
const reliable = @import("engine_headless").reliable;
const World = @import("world.zig").World;
const ByteReader = bytes.ByteReader;
const ByteWriter = bytes.ByteWriter;

pub const protocol_id: u16 = std.mem.readInt(u16, "RT", .little);
/// 2 since Part 2's header: Part 1's prototype sent version 1 with an 8-byte
/// header, which this one must not be taken for.
pub const protocol_version: u8 = 2;
pub const max_datagram_size = net.max_datagram_size;
pub const max_players = 4;
pub const input_history = 3;

/// The message type byte of each message.
pub const MessageType = enum(u8) {
    connect = 1,
    accept,
    refusal,
    input,
    snapshot,
    disconnect,
};

/// Something a Player can ask their Ship to do.
pub const Action = enum { up, down, left, right, fire };

/// The Actions a Player holds, one bit each, `up` in the lowest bit.
pub const Actions = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    fire: bool = false,
    /// Bits that name no Action: the decoder rejects a datagram that sets one.
    _: u3 = 0,

    /// One bit for each Action in `held`.
    pub fn of(held: std.EnumSet(Action)) Actions {
        var actions: Actions = .{};
        // Every Action has its bit: a missing one fails to compile here.
        inline for (comptime std.enums.values(Action)) |action| {
            @field(actions, @tagName(action)) = held.contains(action);
        }
        return actions;
    }
};

/// A connect is padded to the size of the largest answer a Server sends
/// before it accepts: answering it never sends more bytes than it received.
pub const Connect = struct {
    padding: u8 = 0,

    pub fn validate(connect: Connect) error{BadValue}!void {
        if (connect.padding != 0) return error.BadValue;
    }
};

/// The Actions a Player held during one Client Tick.
pub const InputState = struct {
    tick: u32 = 0,
    actions: Actions = .{},
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

/// A Player's index in the Match, from 0: the body of accept, and of the
/// Announcements about one Player.
pub const PlayerId = struct {
    player: u8,

    pub fn validate(id: PlayerId) error{BadValue}!void {
        if (id.player >= max_players) return error.BadValue;
    }
};

pub const RefusalReason = enum(u8) {
    match_full = 1,
    /// The join window has closed: the Client may try again until the next one.
    already_started = 2,
};

/// The answer to a connect the Match cannot take.
pub const Refusal = struct {
    reason: RefusalReason,
};

comptime {
    if (bytes.wireSize(Connect) < bytes.wireSize(Refusal)) @compileError("a Refusal must be no larger than the connect it answers");
}

/// Where a Match stands, as Snapshots carry it. A Server only sends
/// Snapshots to connected Players, so `waiting` is never on the wire.
pub const Phase = enum(u8) {
    /// Nobody is connected: the next Player to connect begins a Match.
    waiting = 0,
    /// Ships appear as their Players join, and can move and fire. No Waves.
    join_window = 1,
    playing = 2,
    /// No Ship is left; a new join window opens when the pause ends.
    game_over = 3,
};

/// A coordinate on the wire, rounded and kept within an i16: entities can
/// stand partly off screen, on any side.
pub fn coordinate(value: f32) i16 {
    const limit: f32 = std.math.maxInt(i16);
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, -limit, limit)));
}

pub const ShipFlags = packed struct(u8) {
    invulnerable: bool = false,
    /// Bits that name nothing: the decoder rejects a datagram that sets one.
    _: u7 = 0,
};

pub const ShipState = struct {
    player: u8 = 0,
    x: i16 = 0,
    y: i16 = 0,
    /// At least 1: a destroyed Ship is left out of the Snapshot.
    hit_points: u8 = 1,
    flags: ShipFlags = .{},

    pub fn validate(ship: ShipState) error{BadValue}!void {
        if (ship.player >= max_players or ship.hit_points == 0) return error.BadValue;
    }
};

/// A Dart, a Pod or a Projectile, told apart from the others of its kind by
/// the id its table gave it.
pub const EntityState = struct {
    id: u8 = 0,
    x: i16 = 0,
    y: i16 = 0,
};

/// The entries of one kind in a Snapshot: at most as many as the Match's
/// table of that kind holds, each with a different `key`.
pub fn Section(comptime table: []const u8, comptime Entry: type, comptime key: []const u8) type {
    return struct {
        const Self = @This();
        pub const capacity = @FieldType(World, table).capacity;
        pub const max_wire_size = 1 + capacity * bytes.wireSize(Entry);

        /// Zig has no private fields: only `add` keeps this at most `capacity`.
        len: u8 = 0,
        entries: [capacity]Entry = undefined,

        /// Adds an entry; any beyond `capacity` are left out.
        pub fn add(section: *Self, entry: Entry) void {
            if (section.len >= capacity) return;
            section.entries[section.len] = entry;
            section.len += 1;
        }

        pub fn slice(section: *const Self) []const Entry {
            return section.entries[0..@min(section.len, capacity)];
        }

        /// On the wire, only the entries present follow their count.
        pub fn writeTo(section: Self, out: *ByteWriter) void {
            const entries = section.slice();
            out.int(u8, @intCast(entries.len));
            for (entries) |entry| out.write(entry);
        }

        /// Reads the entries one at a time: a bad one is rejected before the
        /// next one is read.
        pub fn readFrom(in: *ByteReader) bytes.ReadError!Self {
            var section: Self = .{};
            const count = try in.int(u8);
            // Checked before use: an attacker-chosen count never sizes or indexes anything.
            if (count > capacity) return error.BadValue;
            var seen: std.StaticBitSet(256) = .empty;
            for (0..count) |_| {
                const entry = try in.read(Entry);
                const k = @field(entry, key);
                if (seen.isSet(k)) return error.BadValue; // the same entity twice
                seen.set(k);
                section.add(entry);
            }
            return section;
        }

        /// Equal when the entries present are, whatever the unused slots hold.
        pub fn eql(a: *const Self, b: *const Self) bool {
            if (a.len != b.len) return false;
            for (a.slice(), b.slice()) |x, y| {
                if (!std.meta.eql(x, y)) return false;
            }
            return true;
        }
    };
}

/// Where every entity of a Match stands at one Server Tick. Each Snapshot
/// replaces the one before: none is ever resent.
pub const Snapshot = struct {
    tick: u32 = 0,
    phase: Phase = .join_window,
    /// The Tick at which the join window closes, or the game-over pause
    /// ends; 0 in the other phases.
    phase_ends: u32 = 0,
    ships: Section("ships", ShipState, "player") = .{},
    ship_projectiles: Section("ship_projectiles", EntityState, "id") = .{},
    darts: Section("darts", EntityState, "id") = .{},
    pods: Section("pods", EntityState, "id") = .{},
    enemy_projectiles: Section("enemy_projectiles", EntityState, "id") = .{},

    /// The sections, in their order on the wire.
    pub const sections = .{ "ships", "ship_projectiles", "darts", "pods", "enemy_projectiles" };

    /// The bytes of a Snapshot of full tables, header included.
    pub const max_wire_size = size: {
        var size = bytes.wireSize(Header) + bytes.wireSize(u32) + bytes.wireSize(Phase) + bytes.wireSize(u32);
        for (sections) |name| size += @FieldType(Snapshot, name).max_wire_size;
        break :size size;
    };

    pub fn writeTo(snapshot: Snapshot, out: *ByteWriter) void {
        out.int(u32, snapshot.tick);
        out.write(snapshot.phase);
        out.int(u32, snapshot.phase_ends);
        inline for (sections) |name| out.write(@field(snapshot, name));
    }

    pub fn readFrom(in: *ByteReader) bytes.ReadError!Snapshot {
        var snapshot: Snapshot = .{
            .tick = try in.int(u32),
            .phase = try in.read(Phase),
            .phase_ends = try in.int(u32),
        };
        inline for (sections) |name| @field(snapshot, name) = try in.read(@FieldType(Snapshot, name));
        return snapshot;
    }

    pub fn eql(a: *const Snapshot, b: *const Snapshot) bool {
        if (a.tick != b.tick or a.phase != b.phase or a.phase_ends != b.phase_ends) return false;
        inline for (sections) |name| {
            if (!@field(a, name).eql(&@field(b, name))) return false;
        }
        return true;
    }
};

// Even with every table full, a Snapshot fits in one datagram (ADR 0005):
// checked over the tables' capacities, not over runtime budgets.
comptime {
    if (Snapshot.max_wire_size > max_datagram_size) @compileError("a Snapshot of full tables would not fit in one datagram");
}

pub const Point = struct {
    x: i16 = 0,
    y: i16 = 0,
};

pub const ShipDestroyed = struct {
    player: u8,
    /// Where the Ship was, for the Client to draw its explosion.
    x: i16,
    y: i16,

    pub fn validate(ship: ShipDestroyed) error{BadValue}!void {
        if (ship.player >= max_players) return error.BadValue;
    }
};

/// Something that happened in a Match that every Player must learn of.
/// Unlike a Snapshot, it is delivered for certain, on the reliable channel.
pub const Announcement = struct {
    /// The Server Tick it happened at: a Client drops the visual ones that
    /// arrive too late to show.
    tick: u32 = 0,
    event: Event,

    /// The kind byte, then the kind's body.
    pub const Event = union(enum(u8)) {
        player_joined: PlayerId = 1,
        player_left: PlayerId = 2,
        player_timed_out: PlayerId = 3,
        /// An Enemy destroyed, where it stood.
        explosion: Point = 4,
        ship_destroyed: ShipDestroyed = 5,
        game_over = 6,
    };

    pub fn writeTo(announcement: Announcement, out: *ByteWriter) void {
        out.int(u32, announcement.tick);
        out.int(u8, @intFromEnum(announcement.event));
        switch (announcement.event) {
            inline else => |body| out.write(body),
        }
    }

    pub fn readFrom(in: *ByteReader) bytes.ReadError!Announcement {
        const tick = try in.int(u32);
        const Kind = @typeInfo(Event).@"union".tag_type.?;
        const kind = std.enums.fromInt(Kind, try in.int(u8)) orelse return error.BadValue;
        return .{ .tick = tick, .event = switch (kind) {
            inline else => |tag| @unionInit(Event, @tagName(tag), try in.read(@FieldType(Event, @tagName(tag)))),
        } };
    }
};

/// An Announcement with its number on the reliable channel.
pub const Numbered = reliable.Numbered(Announcement);

/// The bytes of the largest Announcement, with its number.
const max_numbered_size = size: {
    var largest = 0;
    for (@typeInfo(Announcement.Event).@"union".fields) |field| largest = @max(largest, bytes.wireSize(field.type));
    break :size bytes.wireSize(u16) + bytes.wireSize(u32) + bytes.wireSize(u8) + largest;
};

/// Announcements one datagram can carry, beside the largest Snapshot.
pub const max_announcements = (max_datagram_size - Snapshot.max_wire_size - 1) / max_numbered_size;

comptime {
    if (max_announcements < 8) @compileError("too little room for Announcements beside a full Snapshot");
}

/// The Announcements a packet carries, oldest first.
pub const Announcements = struct {
    /// Zig has no private fields: only `add` keeps this at most `max_announcements`.
    len: u8 = 0,
    entries: [max_announcements]Numbered = undefined,

    /// Adds an Announcement; any beyond `max_announcements` are left out.
    pub fn add(list: *Announcements, entry: Numbered) void {
        if (list.len >= max_announcements) return;
        list.entries[list.len] = entry;
        list.len += 1;
    }

    pub fn slice(list: *const Announcements) []const Numbered {
        return list.entries[0..@min(list.len, max_announcements)];
    }

    pub fn writeTo(list: Announcements, out: *ByteWriter) void {
        const entries = list.slice();
        out.int(u8, @intCast(entries.len));
        for (entries) |entry| {
            out.int(u16, entry.id);
            out.write(entry.message);
        }
    }

    pub fn readFrom(in: *ByteReader) bytes.ReadError!Announcements {
        var list: Announcements = .{};
        const count = try in.int(u8);
        if (count > max_announcements) return error.BadValue;
        for (0..count) |_| {
            const id = try in.int(u16);
            list.add(.{ .id = id, .message = try in.read(Announcement) });
        }
        return list;
    }
};

pub const Message = union(MessageType) {
    connect: Connect,
    accept: PlayerId,
    refusal: Refusal,
    input: Input,
    snapshot: Snapshot,
    disconnect,
};

pub const Packet = struct {
    /// The reliable channel's header; all 0 outside a Connection.
    link: reliable.Header = .{ .sequence = 0, .ack = 0, .ack_bits = 0 },
    message: Message,
    announcements: Announcements = .{},
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

/// Every decode error, in the order `decode` checks for them.
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
    link: reliable.Header,
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
        .link = packet.link,
    });
    switch (packet.message) {
        inline else => |body| out.write(body),
    }
    out.write(packet.announcements);
    // A full Snapshot and `max_announcements` always fit: a programming error.
    if (!out.ok) @panic("packet does not fit in a datagram");
    encoded.len = out.written;
    return encoded;
}

/// Decodes one datagram. Takes no allocator, and rejects anything but exactly
/// one well-formed packet.
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
    const announcements = try in.read(Announcements);
    if (in.remaining() != 0) return error.TrailingBytes;
    return .{ .link = header.link, .message = message, .announcements = announcements };
}

const testing = std.testing;

/// The header of a packet of type `kind`: sequence 0x0102, ack 0x0304, ack
/// bits 0x08070605.
fn headerOf(comptime kind: u8) [12]u8 {
    return .{ 'R', 'T', 2, kind, 0x02, 0x01, 0x04, 0x03, 0x05, 0x06, 0x07, 0x08 };
}

/// A packet of type `kind` carrying no Announcement.
fn withHeader(comptime kind: u8, comptime body: []const u8) []const u8 {
    const packet = comptime headerOf(kind) ++ body[0..body.len].* ++ [_]u8{0};
    return &packet;
}

const test_link: reliable.Header = .{ .sequence = 0x0102, .ack = 0x0304, .ack_bits = 0x08070605 };

fn expectBytes(expected: []const u8, message: Message) !void {
    const encoded = encode(.{ .link = test_link, .message = message });
    try testing.expectEqualSlices(u8, expected, encoded.bytes());
}

fn expectAnnouncement(comptime body: []const u8, event: Announcement.Event) !void {
    var packet: Packet = .{ .link = test_link, .message = .disconnect };
    packet.announcements.add(.{ .id = 0x0A09, .message = .{ .tick = 42, .event = event } });
    const expected = headerOf(6) ++ [_]u8{ 1, 0x09, 0x0A, 0x2A, 0, 0, 0 } ++ body;
    try testing.expectEqualSlices(u8, expected, encode(packet).bytes());
}

test "the layout matches the wire format" {
    // An accept for Player 2: the header, the body, and no Announcement.
    try expectBytes(&.{ 0x52, 0x54, 0x02, 0x02, 0x02, 0x01, 0x04, 0x03, 0x05, 0x06, 0x07, 0x08, 0x02, 0x00 }, .{ .accept = .{ .player = 2 } });
    try expectBytes(withHeader(1, &.{0}), .{ .connect = .{} });
    try expectBytes(withHeader(3, &.{1}), .{ .refusal = .{ .reason = .match_full } });
    try expectBytes(withHeader(3, &.{2}), .{ .refusal = .{ .reason = .already_started } });
    try expectBytes(withHeader(4, &.{ 0x0D, 0x0C, 0x0B, 0x0A, 0x11, 7, 0, 0, 0, 0, 6, 0, 0, 0, 8 }), .{ .input = .{ .recent = .{
        .{ .tick = 0x0A0B0C0D, .actions = .{ .up = true, .fire = true } },
        .{ .tick = 7, .actions = .{} },
        .{ .tick = 6, .actions = .{ .right = true } },
    } } });
    try expectBytes(withHeader(6, &.{}), .disconnect);
}

test "a Snapshot's layout: header, then one section per kind, in order" {
    var snapshot: Snapshot = .{ .tick = 9, .phase = .join_window, .phase_ends = 0x0102 };
    snapshot.ships.add(.{ .player = 1, .x = 0x0102, .y = 0x0304, .hit_points = 3, .flags = .{ .invulnerable = true } });
    snapshot.ships.add(.{ .player = 3, .x = 5, .y = 6, .hit_points = 1 });
    snapshot.darts.add(.{ .id = 7, .x = -2, .y = 100 });
    snapshot.enemy_projectiles.add(.{ .id = 0, .x = 1300, .y = -16 });
    try expectBytes(withHeader(5, &.{
        9, 0, 0, 0, // Tick
        1, // phase: join window
        0x02, 0x01, 0, 0, // the Tick it ends
        2, // Ships
        1,
        0x02,
        0x01,
        0x04,
        0x03,
        3,
        0b1,
        3,
        5,
        0,
        6,
        0,
        1,
        0,
        0, // Ship Projectiles
        1, // Darts
        7,
        0xFE,
        0xFF,
        100,
        0,
        0, // Pods
        1, // Enemy Projectiles
        0,
        0x14,
        0x05,
        0xF0,
        0xFF,
    }), .{ .snapshot = snapshot });
    // An empty one: the header and five zero counts.
    try expectBytes(withHeader(5, &.{ 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 }), .{ .snapshot = .{ .phase = .playing } });
}

test "an Announcement's layout: id, Tick, kind, then the kind's body" {
    try expectAnnouncement(&.{ 1, 2 }, .{ .player_joined = .{ .player = 2 } });
    try expectAnnouncement(&.{ 2, 0 }, .{ .player_left = .{ .player = 0 } });
    try expectAnnouncement(&.{ 3, 3 }, .{ .player_timed_out = .{ .player = 3 } });
    try expectAnnouncement(&.{ 4, 0x10, 0x02, 0xFB, 0xFF }, .{ .explosion = .{ .x = 0x0210, .y = -5 } });
    try expectAnnouncement(&.{ 5, 1, 64, 0, 90, 0 }, .{ .ship_destroyed = .{ .player = 1, .x = 64, .y = 90 } });
    try expectAnnouncement(&.{6}, .game_over);
}

test "a full Snapshot and the most Announcements fit in one datagram" {
    // 26 bytes of headers and counts, 4 Ships of 7 bytes, and 160 other
    // entities of 5 bytes.
    try testing.expectEqual(26 + 4 * 7 + (32 + 32 + 32 + 64) * 5, Snapshot.max_wire_size);
    var packet: Packet = .{ .message = .{ .snapshot = .{} } };
    inline for (Snapshot.sections) |name| {
        const section = &@field(packet.message.snapshot, name);
        for (0..@TypeOf(section.*).capacity) |i| {
            if (comptime std.mem.eql(u8, name, "ships")) section.add(.{ .player = @intCast(i) }) else section.add(.{ .id = @intCast(i) });
        }
    }
    for (0..max_announcements) |i| packet.announcements.add(.{ .id = @intCast(i), .message = .{ .event = .{ .ship_destroyed = .{ .player = 0, .x = 0, .y = 0 } } } });
    const encoded = encode(packet);
    try testing.expectEqual(Snapshot.max_wire_size + 1 + max_announcements * 12, encoded.len);
    try testing.expect(encoded.len <= max_datagram_size);
    try testing.expectEqual(28, max_announcements);
}

test "coordinates round, and stay within an i16" {
    try testing.expectEqual(-3, coordinate(-2.6));
    try testing.expectEqual(1280, coordinate(1279.5));
    try testing.expectEqual(std.math.maxInt(i16), coordinate(1e9));
    try testing.expectEqual(-std.math.maxInt(i16), coordinate(-std.math.inf(f32)));
    try testing.expectEqual(0, coordinate(std.math.nan(f32)));
}

test "Actions hold one bit per Action held" {
    var held: std.EnumSet(Action) = .empty;
    try testing.expectEqual(Actions{}, Actions.of(held));
    held.insert(.up);
    held.insert(.fire);
    try testing.expectEqual(Actions{ .up = true, .fire = true }, Actions.of(held));
}

test "decodes what it encodes" {
    const messages = [_]Message{
        .{ .connect = .{} },
        .{ .accept = .{ .player = 3 } },
        .{ .refusal = .{ .reason = .already_started } },
        .{ .input = .{} },
        .disconnect,
    };
    for (messages) |message| {
        const packet: Packet = .{ .link = test_link, .message = message };
        const decoded = try decode(encode(packet).bytes());
        try testing.expectEqualDeep(packet.link, decoded.link);
        try testing.expectEqualDeep(packet.message, decoded.message);
        try testing.expectEqual(0, decoded.announcements.len);
    }
    // A Snapshot's and a list's unused slots are undefined: compare what is present.
    var snapshot: Snapshot = .{ .tick = std.math.maxInt(u32), .phase = .game_over, .phase_ends = 7 };
    snapshot.ships.add(.{});
    snapshot.pods.add(.{ .id = 255, .x = std.math.minInt(i16), .y = std.math.maxInt(i16) });
    var packet: Packet = .{ .link = test_link, .message = .{ .snapshot = snapshot } };
    packet.announcements.add(.{ .id = 65535, .message = .{ .tick = 1, .event = .{ .ship_destroyed = .{ .player = 3, .x = -1, .y = 2 } } } });
    packet.announcements.add(.{ .id = 0, .message = .{ .tick = 2, .event = .game_over } });
    const decoded = try decode(encode(packet).bytes());
    try testing.expect(snapshot.eql(&decoded.message.snapshot));
    try testing.expectEqualDeep(packet.announcements.slice(), decoded.announcements.slice());
}

test "rejects malformed datagrams" {
    const too_long: [max_datagram_size + 1]u8 = @splat(0);
    try testing.expectError(error.TooLong, decode(&too_long));
    try testing.expectError(error.Truncated, decode(&.{}));
    try testing.expectError(error.Truncated, decode(headerOf(6)[0..11]));
    try testing.expectError(error.BadProtocol, decode(&[_]u8{ 'R', 'X', 1, 6 } ++ [_]u8{0} ** 9));
    // Part 1's version, and one from the future.
    try testing.expectError(error.BadVersion, decode(&[_]u8{ 'R', 'T', 1, 6 } ++ [_]u8{0} ** 9));
    try testing.expectError(error.BadVersion, decode(&[_]u8{ 'R', 'T', 3, 6 } ++ [_]u8{0} ** 9));
    try testing.expectError(error.UnknownType, decode(withHeader(0, &.{})));
    try testing.expectError(error.UnknownType, decode(withHeader(7, &.{})));
    try testing.expectError(error.Truncated, decode(&headerOf(2)));
    try testing.expectError(error.BadValue, decode(withHeader(2, &.{4})));
    try testing.expectError(error.BadValue, decode(withHeader(3, &.{3})));
    // The reliable section: missing, or followed by more bytes.
    try testing.expectError(error.Truncated, decode(&headerOf(6)));
    try testing.expectError(error.TrailingBytes, decode(&headerOf(6) ++ .{ 0, 0 }));
    // Connect: unpadded, or padded with anything but zero.
    try testing.expectError(error.Truncated, decode(&headerOf(1)));
    try testing.expectError(error.BadValue, decode(withHeader(1, &.{1})));
    // Input: unknown Action bits, ticks out of order, and truncation first.
    const unknown_action = [_]u8{ 0, 0, 0, 0, 0x20 } ++ [_]u8{0} ** 10;
    try testing.expectError(error.BadValue, decode(withHeader(4, &unknown_action)));
    try testing.expectError(error.Truncated, decode(&headerOf(4) ++ unknown_action[0..14]));
    const out_of_order = [_]u8{ 0, 0, 0, 0, 0, 1 } ++ [_]u8{0} ** 9;
    try testing.expectError(error.BadValue, decode(withHeader(4, &out_of_order)));
}

/// A Snapshot packet: Tick 0, playing, ending at 0, then `sections`, then no
/// Announcement.
fn snapshotWith(comptime sections: []const u8) []const u8 {
    return withHeader(5, &[_]u8{ 0, 0, 0, 0, 2, 0, 0, 0, 0 } ++ sections);
}

/// A Snapshot packet cut short inside `sections`.
fn snapshotCut(comptime sections: []const u8) []const u8 {
    const packet = comptime headerOf(5) ++ [_]u8{ 0, 0, 0, 0, 2, 0, 0, 0, 0 } ++ sections[0..sections.len].*;
    return &packet;
}

test "rejects malformed Snapshots" {
    const no_entities = [_]u8{ 0, 0, 0, 0, 0 };
    try testing.expect((try decode(snapshotWith(&no_entities))).message == .snapshot);
    // An unknown phase.
    try testing.expectError(error.BadValue, decode(withHeader(5, &[_]u8{ 0, 0, 0, 0, 4, 0, 0, 0, 0 } ++ no_entities)));
    // Too many Ships, a Player out of range, a Player twice, a Ship with no
    // hit points, an unknown flag.
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{5})));
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{ 1, 4, 0, 0, 0, 0, 1, 0 })));
    const twice = [_]u8{ 2, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0 };
    try testing.expectError(error.BadValue, decode(snapshotWith(&twice)));
    try testing.expectError(error.Truncated, decode(snapshotCut(twice[0..12])));
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{ 1, 0, 0, 0, 0, 0, 0, 0 })));
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{ 1, 0, 0, 0, 0, 0, 1, 2 })));
    // More Darts than their table holds, and the same Dart twice.
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{ 0, 0, 33 })));
    try testing.expectError(error.BadValue, decode(snapshotWith(&.{ 0, 0, 2, 7, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0 })));
    // A section missing.
    try testing.expectError(error.Truncated, decode(snapshotCut(no_entities[0..4])));
}

/// A disconnect carrying `reliable`, the reliable section.
fn carrying(comptime section: []const u8) []const u8 {
    const packet = comptime headerOf(6) ++ section[0..section.len].*;
    return &packet;
}

test "rejects malformed Announcements" {
    // More than a datagram carries.
    try testing.expectError(error.BadValue, decode(carrying(&.{max_announcements + 1})));
    // Unknown kinds, a Player out of range, and truncation.
    try testing.expectError(error.BadValue, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 0 })));
    try testing.expectError(error.BadValue, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 7 })));
    try testing.expectError(error.BadValue, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 2, 4 })));
    try testing.expectError(error.BadValue, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0 })));
    try testing.expectError(error.Truncated, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0 })));
    try testing.expectError(error.Truncated, decode(carrying(&.{ 2, 0, 0, 0, 0, 0, 0, 6 })));
    try testing.expectError(error.TrailingBytes, decode(carrying(&.{ 1, 0, 0, 0, 0, 0, 0, 6, 0 })));
}
