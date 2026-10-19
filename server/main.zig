//! r-type_server: runs one Match for up to four Players.
//! Players are numbered from 1 in logs; the protocol counts from 0.
//!
//! Two threads: the Engine's network thread receives datagrams into the
//! transport's inbox, and the main thread runs the 60 Hz Tick loop, which
//! drains the inbox, advances the Match and sends every Player a snapshot.
//! Logs go to stderr, unbuffered, so they show up at once even when redirected.

const std = @import("std");
const Io = std.Io;
const engine = @import("engine_headless");
const game = @import("game");
const net = engine.net;
const FixedStep = engine.time.FixedStep;
const protocol = game.protocol;
const Match = game.match.Match;
const tick_rate = game.match.tick_rate;

const usage =
    \\usage: r-type_server [--port <port>] [--seed <seed>] [--join-window <seconds>]
    \\                     [--hit-points <n>] [--invulnerability <seconds>] [--game-over-pause <seconds>]
;

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

const Options = struct {
    port: u16 = 4242,
    /// Random from the OS when not given.
    seed: ?u64 = null,
    /// Every field but the seed, which `main` fills in.
    settings: game.match.Settings = .{ .seed = 0 },
};

fn parseOptions(args: []const [:0]const u8) ?Options {
    if (args.len % 2 != 0) return null; // an option without its value
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = args[i];
        const value = args[i + 1];
        const settings = &options.settings;
        if (std.mem.eql(u8, name, "--port")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch return null;
        } else if (std.mem.eql(u8, name, "--seed")) {
            options.seed = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, name, "--join-window")) {
            settings.join_window = secondsToTicks(u32, value) orelse return null;
        } else if (std.mem.eql(u8, name, "--hit-points")) {
            settings.hit_points = std.fmt.parseInt(u8, value, 10) catch return null;
            if (settings.hit_points == 0) return null;
        } else if (std.mem.eql(u8, name, "--invulnerability")) {
            settings.invulnerability = secondsToTicks(u16, value) orelse return null;
        } else if (std.mem.eql(u8, name, "--game-over-pause")) {
            settings.game_over_pause = secondsToTicks(u32, value) orelse return null;
        } else return null;
    }
    return options;
}

/// A duration given in seconds, such as "4" or "2.5", as a whole number of
/// Ticks; null if it is negative or too long for `T`.
fn secondsToTicks(comptime T: type, seconds: []const u8) ?T {
    const value = std.fmt.parseFloat(f64, seconds) catch return null;
    const count = @round(value * tick_rate);
    if (!(count >= 0 and count <= std.math.maxInt(T))) return null; // also rejects NaN
    return @intFromFloat(count);
}

const Server = struct {
    io: Io,
    transport: *net.UdpTransport,
    match: Match,
    /// Sequence number of the last datagram sent.
    sequence: u32 = 0,
    received: usize = 0,
    malformed: usize = 0,
    ignored: usize = 0,

    fn tick(s: *Server) void {
        // At most one inbox's worth per Tick, so a flood cannot stall the loop.
        for (0..net.inbox_capacity) |_| {
            const datagram = s.transport.receive() orelse break;
            s.handle(&datagram);
        }
        const events = s.match.step();
        if (events.match_started) |seed| log(s.io, "Tick {d}: a Match begins, seed {d}", .{ s.match.tick, seed });
        var dropped = events.timed_out.iterator(.{});
        while (dropped.next()) |player| {
            log(s.io, "Tick {d}: Player {d} timed out", .{ s.match.tick, player + 1 });
            s.tellEveryone(.{ .player_left = .{ .player = @intCast(player) } });
        }
        // Protocol v1 (#26) announces these, and explosions, to the Clients.
        for (events.shipDestroyedSlice()) |ship| log(s.io, "Tick {d}: Player {d}'s Ship destroyed", .{ s.match.tick, ship.player + 1 });
        if (events.game_over) log(s.io, "Tick {d}: game over", .{s.match.tick});
        s.tellEveryone(.{ .snapshot = s.match.snapshot() });
        if (s.match.tick % (5 * tick_rate) == 0) s.report();
    }

    fn handle(s: *Server, datagram: *const net.Datagram) void {
        s.received += 1;
        const packet = protocol.decode(datagram.bytes()) catch {
            s.malformed += 1;
            return;
        };
        const player = s.match.find(datagram.from);
        switch (packet.message) {
            .connect => s.connect(datagram.from),
            .input => |input| {
                if (player) |p| s.match.receive(p, input) else s.ignored += 1;
            },
            .disconnect => {
                if (player) |p| s.leave(p) else s.ignored += 1;
            },
            // Messages only the Server sends.
            .accept, .reject, .snapshot, .player_left => s.ignored += 1,
        }
    }

    fn connect(s: *Server, peer: net.Endpoint) void {
        const known = s.match.find(peer) != null;
        const player = s.match.join(peer) catch |err| {
            // Protocol v1 (#26) adds a reason for a Match that already started.
            s.send(peer, .{ .reject = .{ .reason = .match_full } });
            if (!known) log(s.io, "Tick {d}: refused {f}: {t}", .{ s.match.tick, peer, err });
            return;
        };
        if (!known) log(s.io, "Tick {d}: Player {d} joined from {f}", .{ s.match.tick, player + 1, peer });
        s.send(peer, .{ .accept = .{ .player = player } });
    }

    fn leave(s: *Server, player: u8) void {
        s.match.leave(player);
        log(s.io, "Tick {d}: Player {d} left", .{ s.match.tick, player + 1 });
        s.tellEveryone(.{ .player_left = .{ .player = player } });
    }

    fn send(s: *Server, to: net.Endpoint, message: protocol.Message) void {
        s.sequence +%= 1;
        const encoded = protocol.encode(.{ .sequence = s.sequence, .message = message });
        s.transport.send(to, encoded.bytes());
    }

    fn tellEveryone(s: *Server, message: protocol.Message) void {
        for (s.match.players) |slot| {
            const player = slot orelse continue;
            s.send(player.peer, message);
        }
    }

    fn report(s: *const Server) void {
        log(s.io, "Tick {d}: {d} Players, {d} datagrams received, {d} malformed, {d} ignored, {d} dropped by the transport", .{
            s.match.tick,
            s.match.playerCount(),
            s.received,
            s.malformed,
            s.ignored,
            s.transport.droppedCount(),
        });
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) orelse {
        log(io, usage, .{});
        return 2;
    };
    const port = options.port;
    const transport = net.UdpTransport.open(init.gpa, io, port) catch |err| {
        log(io, "r-type_server: cannot listen on UDP port {d}: {t}", .{ port, err });
        return 1;
    };
    defer transport.close();
    var settings = options.settings;
    settings.seed = options.seed orelse seed: {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        break :seed seed;
    };
    var server: Server = .{ .io = io, .transport = transport, .match = .init(settings) };
    log(io, "r-type_server: listening on UDP port {d}, {d} Ticks per second", .{ transport.localPort(), tick_rate });

    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    while (true) {
        for (0..try ticks.wait()) |_| server.tick();
    }
}

const testing = std.testing;

test "options default to #2's settings" {
    const options = parseOptions(&.{}).?;
    try testing.expectEqual(4242, options.port);
    try testing.expectEqual(null, options.seed);
    try testing.expectEqual(5 * tick_rate, options.settings.join_window);
    try testing.expectEqual(3, options.settings.hit_points);
    try testing.expectEqual(4 * tick_rate, options.settings.invulnerability);
    try testing.expectEqual(5 * tick_rate, options.settings.game_over_pause);
}

test "durations are read in seconds" {
    const options = parseOptions(&.{ "--join-window", "2.5", "--invulnerability", "0", "--seed", "42", "--hit-points", "5" }).?;
    try testing.expectEqual(150, options.settings.join_window);
    try testing.expectEqual(0, options.settings.invulnerability);
    try testing.expectEqual(42, options.seed);
    try testing.expectEqual(5, options.settings.hit_points);
}

test "bad options are refused" {
    try testing.expectEqual(null, parseOptions(&.{"--port"}));
    try testing.expectEqual(null, parseOptions(&.{ "--hit-points", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--join-window", "-1" }));
    try testing.expectEqual(null, parseOptions(&.{ "--invulnerability", "2000" })); // beyond a u16 of Ticks
    try testing.expectEqual(null, parseOptions(&.{ "--game-over-pause", "nan" }));
    try testing.expectEqual(null, parseOptions(&.{ "--speed", "2" }));
}
