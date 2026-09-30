//! Little-endian encoding, so the wire format never depends on the host's byte
//! order or on how Zig lays out a struct in memory.
//!
//! `ByteWriter.write` and `ByteReader.read` derive the encoding of plain data
//! types from their declarations, at compile time:
//! - integers, little-endian, in a whole number of bytes;
//! - enums, as their integer tag;
//! - packed structs, as their backing integer;
//! - arrays, element by element;
//! - other structs, field by field in declaration order.
//!
//! A type can take part in three ways:
//! - `pub fn validate(value: T) error{BadValue}!void` rejects values that
//!   decode but are out of range;
//! - `pub fn writeTo(value: T, w: *ByteWriter) void` and
//!   `pub fn readFrom(r: *ByteReader) ReadError!T` replace the derived
//!   encoding, for a type whose length varies.
//!
//! Every read is checked by this code, not by the language's safety checks, so
//! the checks hold in every build mode, ReleaseFast included.

const std = @import("std");

pub const ReadError = error{
    /// A read went past the end of the bytes.
    Truncated,
    /// The bytes are there, but do not hold a valid value of the type.
    BadValue,
};

/// Writes into a caller-provided buffer. A write that does not fit is dropped
/// and marks the writer as failed; check `ok` once, after the last write.
pub const ByteWriter = struct {
    buffer: []u8,
    /// Bytes written so far.
    written: usize = 0,
    /// False once a write did not fit.
    ok: bool = true,

    pub fn init(buffer: []u8) ByteWriter {
        return .{ .buffer = buffer };
    }

    /// Writes an integer, little-endian.
    pub fn int(w: *ByteWriter, comptime T: type, value: T) void {
        const size = comptime byteSize(T);
        if (!w.ok or w.buffer.len - w.written < size) {
            w.ok = false;
            return;
        }
        std.mem.writeInt(T, w.buffer[w.written..][0..size], value, .little);
        w.written += size;
    }

    /// Writes `value` with the encoding derived from its type (see the top of
    /// this file).
    pub fn write(w: *ByteWriter, value: anytype) void {
        const T = @TypeOf(value);
        if (comptime hasDecl(T, "writeTo")) return value.writeTo(w);
        switch (@typeInfo(T)) {
            .void => {},
            .int => w.int(T, value),
            .@"enum" => |info| w.int(info.tag_type, @intFromEnum(value)),
            .array => for (value) |element| w.write(element),
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => w.int(info.backing_integer.?, @bitCast(value)),
                .auto, .@"extern" => inline for (info.fields) |field| w.write(@field(value, field.name)),
            },
            else => @compileError("no wire encoding for " ++ @typeName(T)),
        }
    }
};

/// Reads from untrusted bytes. A read past the end fails with
/// `error.Truncated` and consumes nothing.
pub const ByteReader = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) ByteReader {
        return .{ .bytes = bytes };
    }

    /// Bytes not read yet.
    pub fn remaining(r: ByteReader) usize {
        return r.bytes.len;
    }

    /// Reads an integer, little-endian.
    pub fn int(r: *ByteReader, comptime T: type) error{Truncated}!T {
        const size = comptime byteSize(T);
        if (r.bytes.len < size) return error.Truncated;
        return std.mem.readInt(T, r.take(size), .little);
    }

    /// Reads a value written by `ByteWriter.write`. A type of fixed size is
    /// only decoded once all of its bytes are known to be there: a short read
    /// is `Truncated` even when the bytes present already hold a bad value.
    pub fn read(r: *ByteReader, comptime T: type) ReadError!T {
        if (comptime hasDecl(T, "readFrom")) return T.readFrom(r);
        if (r.bytes.len < comptime wireSize(T)) return error.Truncated;
        return r.readPresent(T);
    }

    /// Reads a fixed-size value whose bytes `read` found to be there.
    fn readPresent(r: *ByteReader, comptime T: type) error{BadValue}!T {
        const value: T = switch (@typeInfo(T)) {
            .void => {},
            .int => std.mem.readInt(T, r.take(comptime byteSize(T)), .little),
            .@"enum" => |info| decoded: {
                const tag = try r.readPresent(info.tag_type);
                break :decoded std.enums.fromInt(T, tag) orelse return error.BadValue;
            },
            .array => |info| decoded: {
                var array: T = undefined;
                for (&array) |*element| element.* = try r.readPresent(info.child);
                break :decoded array;
            },
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => decoded: {
                    const decoded: T = @bitCast(try r.readPresent(info.backing_integer.?));
                    // Padding bits (a field named "_") must be zero: they name
                    // nothing, so a set one means the sender meant something
                    // this version does not know.
                    if (comptime @hasField(T, "_")) {
                        if (decoded._ != 0) return error.BadValue;
                    }
                    break :decoded decoded;
                },
                .auto, .@"extern" => decoded: {
                    var decoded: T = undefined;
                    inline for (info.fields) |field| {
                        @field(decoded, field.name) = try r.readPresent(field.type);
                    }
                    break :decoded decoded;
                },
            },
            else => @compileError("no wire encoding for " ++ @typeName(T)),
        };
        if (comptime hasDecl(T, "validate")) try value.validate();
        return value;
    }

    fn take(r: *ByteReader, comptime size: usize) *const [size]u8 {
        defer r.bytes = r.bytes[size..];
        return r.bytes[0..size];
    }
};

/// The number of bytes `ByteWriter.write` produces for any value of `T`.
pub fn wireSize(comptime T: type) comptime_int {
    if (hasDecl(T, "readFrom")) @compileError(@typeName(T) ++ " has no fixed wire size");
    return switch (@typeInfo(T)) {
        .void => 0,
        .int => byteSize(T),
        .@"enum" => |info| byteSize(info.tag_type),
        .array => |info| info.len * wireSize(info.child),
        .@"struct" => |info| switch (info.layout) {
            .@"packed" => byteSize(info.backing_integer.?),
            .auto, .@"extern" => size: {
                var size: comptime_int = 0;
                for (info.fields) |field| size += wireSize(field.type);
                break :size size;
            },
        },
        else => @compileError("no wire encoding for " ++ @typeName(T)),
    };
}

fn byteSize(comptime T: type) comptime_int {
    const bits = @typeInfo(T).int.bits;
    if (bits % 8 != 0) @compileError(@typeName(T) ++ " is not a whole number of bytes");
    return bits / 8;
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

test "integers are little-endian" {
    var buffer: [7]u8 = undefined;
    var out: ByteWriter = .init(&buffer);
    out.int(u8, 0x01);
    out.int(u16, 0x0302);
    out.int(u32, 0x07060504);
    try std.testing.expect(out.ok);
    try std.testing.expectEqual(7, out.written);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7 }, &buffer);

    var in: ByteReader = .init(&buffer);
    try std.testing.expectEqual(0x01, try in.int(u8));
    try std.testing.expectEqual(0x0302, try in.int(u16));
    try std.testing.expectEqual(0x07060504, try in.int(u32));
    try std.testing.expectEqual(0, in.remaining());
}

test "overflowing writes and reads fail without panicking" {
    var buffer: [3]u8 = undefined;
    var out: ByteWriter = .init(&buffer);
    out.int(u16, 0xFFFF);
    out.int(u16, 0xFFFF);
    try std.testing.expect(!out.ok);
    try std.testing.expectEqual(2, out.written);

    var in: ByteReader = .init(&.{ 1, 2, 3 });
    try std.testing.expectError(error.Truncated, in.int(u32));
    try std.testing.expectEqual(3, in.remaining()); // a failed read consumes nothing
    try std.testing.expectEqual(0x0201, try in.int(u16));
}

test "derived encoding: fields in order, packed structs, enums, and truncation first" {
    const Flags = packed struct(u8) { a: bool, b: bool, _: u6 = 0 };
    const Kind = enum(u8) { one = 1, two = 2 };
    const Record = struct { kind: Kind, flags: Flags, pair: [2]u16 };
    try std.testing.expectEqual(6, wireSize(Record));

    var buffer: [6]u8 = undefined;
    var out: ByteWriter = .init(&buffer);
    out.write(Record{ .kind = .two, .flags = .{ .a = false, .b = true }, .pair = .{ 0x0102, 3 } });
    try std.testing.expectEqualSlices(u8, &.{ 2, 0b10, 0x02, 0x01, 3, 0 }, &buffer);

    var in: ByteReader = .init(&buffer);
    const record = try in.read(Record);
    try std.testing.expectEqual(Kind.two, record.kind);
    try std.testing.expect(record.flags.b and !record.flags.a);
    try std.testing.expectEqual(0x0102, record.pair[0]);

    // An unknown enum tag or a padding bit is a bad value, unless bytes are
    // missing: then the read is truncated, whatever the bytes present hold.
    var bad_kind: ByteReader = .init(&.{ 9, 0, 0, 0, 0, 0 });
    try std.testing.expectError(error.BadValue, bad_kind.read(Record));
    var bad_flags: ByteReader = .init(&.{ 1, 0b100, 0, 0, 0, 0 });
    try std.testing.expectError(error.BadValue, bad_flags.read(Record));
    var short: ByteReader = .init(&.{ 9, 0b100, 0, 0, 0 });
    try std.testing.expectError(error.Truncated, short.read(Record));
}
