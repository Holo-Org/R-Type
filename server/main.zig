//! r-type_server: runs one Match for up to four Players.
//! Players are numbered from 1 in logs; the protocol counts from 0.
//!
//! Two threads: the Engine's network thread receives datagrams into the
//! transport's inbox, and the main thread runs the 60 Hz Tick loop, which
//! drains the inbox, advances the Match, queues what the Tick announced on
//! each Player's reliable channel, and every K Ticks sends every Player a
//! snapshot, which carries the Announcements not acknowledged yet.
//! Logs go to stderr, unbuffered, so they show up at once even when redirected.

const std = @import("std");
const Io = std.Io;
const engine = @import("engine_headless");
const game = @import("game");
const net = engine.net;
const FixedStep = engine.time.FixedStep;
const Channel = engine.reliable.Channel(protocol.Announcement);
const protocol = game.protocol;
const Match = game.match.Match;
const tick_rate = game.match.tick_rate;

const usage =
    \\usage: r-type_server [--port <port>] [--seed <seed>] [--snapshot-every <ticks>] [--join-window <seconds>]
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
    /// K: a snapshot every K Ticks (ADR 0002). A larger K saves bandwidth,
    /// and shows as jerkier movement.
    snapshot_every: u8 = 1,
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
        } else if (std.mem.eql(u8, name, "--snapshot-every")) {
            options.snapshot_every = std.fmt.parseInt(u8, value, 10) catch return null;
            if (options.snapshot_every == 0) return null;
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
    snapshot_every: u8,
    /// Each Player's reliable channel, by Player index; null outside a Connection.
    channels: [protocol.max_players]?Channel = @splat(null),
    received: usize = 0,
    malformed: usize = 0,
    ignored: usize = 0,
    bytes_sent: u64 = 0,
    /// Announcements resent on channels since closed; open ones count their own.
    resent: u64 = 0,

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
            s.close(@intCast(player));
            s.announce(.{ .player_timed_out = .{ .player = @intCast(player) } });
        }
        for (events.explosionSlice()) |at| {
            s.announce(.{ .explosion = .{ .x = protocol.coordinate(at.x), .y = protocol.coordinate(at.y) } });
        }
        for (events.shipDestroyedSlice()) |ship| {
            log(s.io, "Tick {d}: Player {d}'s Ship destroyed", .{ s.match.tick, ship.player + 1 });
            s.announce(.{ .ship_destroyed = .{ .player = ship.player, .x = protocol.coordinate(ship.position.x), .y = protocol.coordinate(ship.position.y) } });
        }
        if (events.game_over) {
            log(s.io, "Tick {d}: game over", .{s.match.tick});
            s.announce(.game_over);
        }
        if (s.match.tick % s.snapshot_every == 0) {
            const snapshot = s.match.snapshot();
            for (0..protocol.max_players) |player| {
                if (s.channels[player] != null) s.send(@intCast(player), .{ .snapshot = snapshot });
            }
        }
        if (s.match.tick % (5 * tick_rate) == 0) s.report();
    }

    fn handle(s: *Server, datagram: *const net.Datagram) void {
        s.received += 1;
        const packet = protocol.decode(datagram.bytes()) catch {
            s.malformed += 1;
            return;
        };
        const player = s.match.find(datagram.from);
        // Only acknowledgements: a Client sends no Announcements.
        if (player) |p| {
            if (s.channels[p]) |*channel| channel.incoming(engine.time.timestamp(s.io), packet.link, &.{});
        }
        switch (packet.message) {
            .connect => s.connect(datagram.from, packet.link),
            .input => |input| {
                if (player) |p| s.match.receive(p, input) else s.ignored += 1;
            },
            .disconnect => {
                if (player) |p| s.leave(p) else s.ignored += 1;
            },
            // Messages only the Server sends.
            .accept, .refusal, .snapshot => s.ignored += 1,
        }
    }

    fn connect(s: *Server, peer: net.Endpoint, link: engine.reliable.Header) void {
        const known = s.match.find(peer) != null;
        const player = s.match.join(peer) catch |err| {
            s.sendOutside(peer, .{ .refusal = .{ .reason = switch (err) {
                error.MatchFull => .match_full,
                error.AlreadyStarted => .already_started,
            } } });
            if (!known) log(s.io, "Tick {d}: refused {f}: {t}", .{ s.match.tick, peer, err });
            return;
        };
        if (!known) {
            s.channels[player] = .{};
            s.channels[player].?.incoming(engine.time.timestamp(s.io), link, &.{});
            log(s.io, "Tick {d}: Player {d} joined from {f}", .{ s.match.tick, player + 1, peer });
            s.announce(.{ .player_joined = .{ .player = player } });
        }
        s.send(player, .{ .accept = .{ .player = player } });
    }

    fn leave(s: *Server, player: u8) void {
        s.match.leave(player);
        s.close(player);
        log(s.io, "Tick {d}: Player {d} left", .{ s.match.tick, player + 1 });
        s.announce(.{ .player_left = .{ .player = player } });
    }

    fn close(s: *Server, player: u8) void {
        const channel = &(s.channels[player] orelse return);
        s.resent += channel.resent;
        s.channels[player] = null;
    }

    /// Sends a Player `message`, with the Announcements their channel has
    /// to send again or for the first time.
    fn send(s: *Server, player: u8, message: protocol.Message) void {
        const channel = &(s.channels[player] orelse return);
        const peer = (s.match.players[player] orelse return).peer;
        var room: [protocol.max_announcements]protocol.Numbered = undefined;
        const out = channel.outgoing(engine.time.timestamp(s.io), &room);
        var packet: protocol.Packet = .{ .link = out.header, .message = message };
        for (out.messages) |entry| packet.announcements.add(entry);
        s.transmit(peer, &packet);
    }

    /// Answers a peer that has no Connection.
    fn sendOutside(s: *Server, peer: net.Endpoint, message: protocol.Message) void {
        s.transmit(peer, &.{ .message = message });
    }

    fn transmit(s: *Server, peer: net.Endpoint, packet: *const protocol.Packet) void {
        const encoded = protocol.encode(packet.*);
        s.bytes_sent += encoded.len;
        s.transport.send(peer, encoded.bytes());
    }

    /// Tells every Player of something that happened this Tick: it goes out
    /// with their next datagrams until they acknowledge it. A Player whose
    /// channel is full has stopped acknowledging, and times out.
    fn announce(s: *Server, event: protocol.Announcement.Event) void {
        const announcement: protocol.Announcement = .{ .tick = s.match.tick, .event = event };
        for (0..protocol.max_players) |index| {
            const player: u8 = @intCast(index);
            const channel = &(s.channels[player] orelse continue);
            channel.send(announcement) catch {
                log(s.io, "Tick {d}: Player {d} timed out: {d} Announcements unacknowledged", .{ s.match.tick, player + 1, engine.reliable.window });
                s.match.leave(player);
                s.close(player);
                // Told to the Players left; at most once per Player, so this ends.
                s.announce(.{ .player_timed_out = .{ .player = player } });
            };
        }
    }

    fn report(s: *const Server) void {
        var resent = s.resent;
        for (s.channels) |slot| resent += if (slot) |channel| channel.resent else 0;
        log(s.io, "Tick {d}: {d} Players, {d} datagrams received, {d} malformed, {d} ignored, {d} dropped by the transport, {d} bytes sent, {d} Announcements resent", .{
            s.match.tick,
            s.match.playerCount(),
            s.received,
            s.malformed,
            s.ignored,
            s.transport.droppedCount(),
            s.bytes_sent,
            resent,
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
    var server: Server = .{ .io = io, .transport = transport, .match = .init(settings), .snapshot_every = options.snapshot_every };
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
    try testing.expectEqual(1, options.snapshot_every);
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
    try testing.expectEqual(4, parseOptions(&.{ "--snapshot-every", "4" }).?.snapshot_every);
}

test "bad options are refused" {
    try testing.expectEqual(null, parseOptions(&.{"--port"}));
    try testing.expectEqual(null, parseOptions(&.{ "--hit-points", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--snapshot-every", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--join-window", "-1" }));
    try testing.expectEqual(null, parseOptions(&.{ "--invulnerability", "2000" })); // beyond a u16 of Ticks
    try testing.expectEqual(null, parseOptions(&.{ "--game-over-pause", "nan" }));
    try testing.expectEqual(null, parseOptions(&.{ "--speed", "2" }));
}
