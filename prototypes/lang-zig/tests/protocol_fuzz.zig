//! protocol_fuzz: throws random and mutated datagrams at the protocol decoder,
//! which must never crash, never allocate, and reject anything but well-formed
//! packets.
//!
//! usage: protocol_fuzz [datagrams [seed]]
//!   zig build fuzz -- 100000 42
//!
//! The datagrams are the Rust POC's, draw for draw: the same generator
//! (SplitMix64, taking the high 32 bits, bounded by remainder) and the same
//! order of draws, so for the same seed the three tallies can be compared
//! directly.
//!
//! Panics: in Debug and ReleaseSafe builds, a failed bounds or overflow check
//! panics, and a Zig panic cannot be caught. The panic handler below prints
//! the datagram being decoded, then ends the run as usual; a completed run
//! therefore means no panic.
//!
//! Allocations: Zig has no global allocator to hook. Every allocator the
//! standard library offers gets its memory from the C library on macOS and
//! Linux, though: `malloc` and its variants (`c_allocator`), or `mmap`
//! (`page_allocator`, `smp_allocator`, `DebugAllocator`). This program defines
//! those functions itself, counts every call made from its own code, and
//! forwards each to the C library. A self-check proves the counter sees
//! allocations before the fuzzing starts.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("game").protocol;

// ---- Allocation counting --------------------------------------------------

/// Calls to the C library's allocation functions made by this thread.
threadlocal var allocations: usize = 0;

const counting = builtin.link_libc and (builtin.os.tag.isDarwin() or builtin.os.tag == .linux);

/// The C library's own definition of `name`, found past this program's.
fn next(comptime name: [:0]const u8, comptime Fn: type) *const Fn {
    const Cache = struct {
        var function: ?*const Fn = null;
    };
    if (Cache.function) |function| return function;
    const rtld_next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize)); // (void *)-1
    const symbol = std.c.dlsym(rtld_next, name) orelse @panic("dlsym cannot find " ++ name);
    Cache.function = @ptrCast(@alignCast(symbol));
    return Cache.function.?;
}

const interposed = struct {
    fn malloc(size: usize) callconv(.c) ?*anyopaque {
        allocations += 1;
        return next("malloc", @TypeOf(malloc))(size);
    }
    fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
        allocations += 1;
        return next("calloc", @TypeOf(calloc))(count, size);
    }
    fn realloc(block: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        allocations += 1;
        return next("realloc", @TypeOf(realloc))(block, size);
    }
    fn posix_memalign(block: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
        allocations += 1;
        return next("posix_memalign", @TypeOf(posix_memalign))(block, alignment, size);
    }
    fn aligned_alloc(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
        allocations += 1;
        return next("aligned_alloc", @TypeOf(aligned_alloc))(alignment, size);
    }
    fn mmap(address: ?*anyopaque, len: usize, protection: c_int, flags: c_int, fd: c_int, offset: i64) callconv(.c) ?*anyopaque {
        allocations += 1;
        return next("mmap", @TypeOf(mmap))(address, len, protection, flags, fd, offset);
    }
};

comptime {
    if (counting) {
        for (.{ "malloc", "calloc", "realloc", "posix_memalign", "aligned_alloc", "mmap" }) |name| {
            @export(&@field(interposed, name), .{ .name = name });
        }
    }
}

/// Fails unless the counter sees an allocation from the page allocator and
/// from the C allocator: a counter that sees nothing would always read 0.
fn checkTheCounter() !void {
    const before = allocations;
    const page = try std.heap.page_allocator.alloc(u8, 64);
    defer std.heap.page_allocator.free(page);
    const from_c = try std.heap.c_allocator.alloc(u8, 64);
    defer std.heap.c_allocator.free(from_c);
    if (allocations - before < 2) return error.AllocationCounterBlind;
}

// ---- Panics ----------------------------------------------------------------

/// The datagram being decoded, for the panic handler.
var decoding: ?[]const u8 = null;

pub const panic = std.debug.FullPanic(struct {
    fn reportDatagram(message: []const u8, first_trace_address: ?usize) noreturn {
        if (decoding) |datagram| {
            std.debug.print("protocol_fuzz: decode() panicked on this {d}-byte datagram:\n", .{datagram.len});
            std.debug.dumpHex(datagram);
        }
        std.debug.defaultPanic(message, first_trace_address);
    }
}.reportDatagram);

// ---- The Rust POC's generator ------------------------------------------------

const Random = struct {
    state: std.Random.SplitMix64,

    fn init(seed: u64) Random {
        return .{ .state = .init(seed) };
    }

    fn next32(r: *Random) u32 {
        return @intCast(r.state.next() >> 32); // the high half: the better-mixed bits
    }

    /// A number in 0..bound, or 0 when bound is 0.
    fn below(r: *Random, bound: u32) u32 {
        const n = r.next32();
        return if (bound == 0) 0 else n % bound;
    }
};

fn randomPlayer(r: *Random) u8 {
    return @intCast(r.below(protocol.max_players));
}

fn shuffle(items: []u8, r: *Random) void {
    var i = items.len - 1;
    while (i > 0) : (i -= 1) std.mem.swap(u8, &items[i], &items[r.below(@intCast(i + 1))]);
}

fn randomMessage(r: *Random) protocol.Message {
    return switch (r.below(7)) {
        0 => .connect,
        1 => .{ .accept = .{ .player = randomPlayer(r) } },
        2 => .{ .reject = .{ .reason = .match_full } },
        3 => input: {
            var input: protocol.Input = .{};
            var tick = r.next32();
            for (&input.recent) |*state| {
                const bits: u8 = @truncate(r.next32());
                state.* = .{ .tick = tick, .buttons = @bitCast(bits & 0b1_1111) };
                tick -= @min(tick, r.below(3));
            }
            break :input .{ .input = input };
        },
        4 => snapshot: {
            var snapshot: protocol.Snapshot = .{ .tick = r.next32() };
            const count = r.below(protocol.max_players + 1);
            var players = [_]u8{ 0, 1, 2, 3 };
            shuffle(&players, r);
            for (players[0..count]) |player| {
                const x: u16 = @truncate(r.next32());
                const y: u16 = @truncate(r.next32());
                snapshot.add(.{ .player = player, .x = x, .y = y });
            }
            break :snapshot .{ .snapshot = snapshot };
        },
        5 => .disconnect,
        else => .{ .player_left = .{ .player = randomPlayer(r) } },
    };
}

fn randomPacket(r: *Random) protocol.Packet {
    const sequence = r.next32();
    return .{ .sequence = sequence, .message = randomMessage(r) };
}

/// A datagram under construction: at most 1500 bytes of noise, or a small
/// packet plus a few appended bytes.
const Datagram = struct {
    buffer: [1600]u8 = undefined,
    len: usize = 0,

    fn bytes(d: *const Datagram) []const u8 {
        return d.buffer[0..d.len];
    }

    fn push(d: *Datagram, byte: u8) void {
        d.buffer[d.len] = byte;
        d.len += 1;
    }
};

/// One to three mutations: flip a bit, overwrite a byte, truncate, or append.
/// Where the Rust test indexes a byte and draws the new value in one
/// assignment, Rust draws the value first; so does this code.
fn mutate(d: *Datagram, r: *Random) void {
    for (0..1 + r.below(3)) |_| {
        const len: u32 = @intCast(d.len);
        switch (r.below(4)) {
            0 => if (len > 0) {
                const bit: u3 = @intCast(r.below(8));
                d.buffer[r.below(len)] ^= @as(u8, 1) << bit;
            },
            1 => if (len > 0) {
                const value: u8 = @truncate(r.next32());
                d.buffer[r.below(len)] = value;
            },
            2 => d.len = r.below(len + 1),
            else => for (0..1 + r.below(8)) |_| d.push(@truncate(r.next32())),
        }
    }
}

// ---- The test ----------------------------------------------------------------

/// The number of datagrams, and the seed if one is given.
fn parseArgs(args: []const [:0]const u8) ?struct { count: u64, seed: ?u64 } {
    if (args.len > 2) return null;
    const count = if (args.len > 0) std.fmt.parseInt(u64, args[0], 10) catch return null else 100_000;
    const seed = if (args.len > 1) std.fmt.parseInt(u64, args[1], 10) catch return null else null;
    return .{ .count = count, .seed = seed };
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseArgs(args[1..]) orelse {
        std.debug.print("usage: protocol_fuzz [datagrams [seed]]\n", .{});
        return 2;
    };
    const seed = options.seed orelse seed: {
        var fresh: u64 = undefined;
        init.io.random(std.mem.asBytes(&fresh));
        break :seed fresh;
    };
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    if (counting) try checkTheCounter();

    var random: Random = .init(seed);
    try out.print("protocol_fuzz: seed {d}\n", .{seed});

    // Whatever encode() writes, decode() must read back unchanged.
    const round_trips = 10_000;
    var mismatches: usize = 0;
    for (0..round_trips) |_| {
        const packet = randomPacket(&random);
        const decoded = protocol.decode(protocol.encode(packet).bytes()) catch {
            mismatches += 1;
            continue;
        };
        if (!std.meta.eql(decoded, packet)) mismatches += 1;
    }
    try out.print("round trip: {d} packets, {d} mismatches\n", .{ round_trips, mismatches });

    // Half pure noise of any length up to 1500 bytes, half mutated valid packets.
    var rejected: [protocol.decode_errors.len]usize = @splat(0);
    var accepted: usize = 0;
    var decoder_allocations: usize = 0;
    var datagram: Datagram = .{};
    for (0..options.count) |i| {
        datagram.len = 0;
        if (i % 2 == 0) {
            for (0..random.below(1501)) |_| datagram.push(@truncate(random.next32()));
        } else {
            const encoded = protocol.encode(randomPacket(&random));
            @memcpy(datagram.buffer[0..encoded.len], encoded.bytes());
            datagram.len = encoded.len;
            mutate(&datagram, &random);
        }
        const before = allocations;
        decoding = datagram.bytes();
        const result = protocol.decode(datagram.bytes());
        decoding = null;
        decoder_allocations += allocations - before;
        if (result) |_| {
            accepted += 1;
        } else |err| for (protocol.decode_errors, &rejected) |known, *times| {
            if (err == known) times.* += 1;
        }
    }

    var total_rejected: usize = 0;
    for (rejected) |times| total_rejected += times;
    try out.print("fuzz: {d} datagrams, {d} rejected, {d} accepted, 0 panics, ", .{ options.count, total_rejected, accepted });
    if (counting) {
        try out.print("{d} allocations in decode()\n", .{decoder_allocations});
    } else {
        try out.print("allocations in decode() not counted on this system\n", .{});
    }
    for (protocol.decode_errors, rejected) |err, times| {
        try out.print("  {d:>7} {s}\n", .{ times, protocol.describe(err) });
    }
    try out.flush();
    return if (mismatches == 0 and decoder_allocations == 0) 0 else 1;
}
