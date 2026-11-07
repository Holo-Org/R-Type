//! r-type_server: runs several Matches at once, five by default, each for up
//! to four Players, and places each new Player in the first Match that takes
//! them (matches.zig). Matches and Players are numbered from 1 in logs; the
//! protocol counts Players from 0.
//!
//! Two threads: the Engine's network thread receives datagrams into the
//! transport's inbox, and the main thread runs the 60 Hz Tick loop, which
//! drains the inbox, advances every Match, queues what the Tick announced on
//! each Player's reliable channel, and every K Ticks sends every Player a
//! snapshot of their Match, which carries the Announcements not acknowledged
//! yet. Logs go to stderr, unbuffered, so they show up at once even when
//! redirected.

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
const matches_ = @import("matches.zig");
const Place = matches_.Place;

const usage =
    \\usage: r-type_server [--port <port>] [--matches <n>] [--seed <seed>] [--snapshot-every <ticks>]
    \\                     [--join-window <seconds>] [--hit-points <n>] [--invulnerability <seconds>]
    \\                     [--game-over-pause <seconds>]
;

/// Each Player's reliable channel in a Match, by Player index; null outside
/// a Connection.
const Channels = [protocol.max_players]?Channel;

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

const Options = struct {
    port: u16 = 4242,
    /// Matches run at once: five take the 20 Players of a full session.
    matches: u8 = 5,
    /// The first Match's; random from the OS when not given.
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
        } else if (std.mem.eql(u8, name, "--matches")) {
            options.matches = std.fmt.parseInt(u8, value, 10) catch return null;
            if (options.matches == 0) return null;
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
    /// Every Match steps in lockstep, so all count the same Ticks.
    matches: []Match,
    /// Each Match's channels, by the Match's index.
    channels: []Channels,
    snapshot_every: u8,
    received: usize = 0,
    malformed: usize = 0,
    ignored: usize = 0,
    bytes_sent: u64 = 0,
    /// Announcements resent on channels since closed; open ones count their own.
    resent: u64 = 0,

    /// The Tick every Match is at.
    fn now(s: *const Server) u32 {
        return s.matches[0].tick;
    }

    fn tick(s: *Server) void {
        // At most one inbox's worth per Tick, so a flood cannot stall the loop.
        for (0..net.inbox_capacity) |_| {
            const datagram = s.transport.receive() orelse break;
            s.handle(&datagram);
        }
        for (0..s.matches.len) |index| s.step(@intCast(index));
        if (s.now() % (5 * tick_rate) == 0) s.report();
    }

    /// Advances one Match, announces what happened in it, and sends its
    /// Players their snapshot when one is due.
    fn step(s: *Server, m: u8) void {
        const match = &s.matches[m];
        const events = match.step();
        if (events.match_started) |seed| log(s.io, "Tick {d}: Match {d} begins, seed {d}", .{ match.tick, m + 1, seed });
        var dropped = events.timed_out.iterator(.{});
        while (dropped.next()) |player| {
            const place: Place = .{ .match = m, .player = @intCast(player) };
            log(s.io, "Tick {d}: Match {d}, Player {d} timed out", .{ match.tick, m + 1, player + 1 });
            s.close(place);
            s.announce(m, .{ .player_timed_out = .{ .player = place.player } });
        }
        for (events.explosionSlice()) |at| {
            s.announce(m, .{ .explosion = .{ .x = protocol.coordinate(at.x), .y = protocol.coordinate(at.y) } });
        }
        for (events.shipDestroyedSlice()) |ship| {
            log(s.io, "Tick {d}: Match {d}, Player {d}'s Ship destroyed", .{ match.tick, m + 1, ship.player + 1 });
            s.announce(m, .{ .ship_destroyed = .{ .player = ship.player, .x = protocol.coordinate(ship.position.x), .y = protocol.coordinate(ship.position.y) } });
        }
        if (events.game_over) {
            log(s.io, "Tick {d}: Match {d}: game over", .{ match.tick, m + 1 });
            s.announce(m, .game_over);
        }
        if (match.tick % s.snapshot_every == 0) {
            const snapshot = match.snapshot();
            for (0..protocol.max_players) |player| {
                if (s.channels[m][player] != null) s.send(.{ .match = m, .player = @intCast(player) }, .{ .snapshot = snapshot });
            }
        }
    }

    fn handle(s: *Server, datagram: *const net.Datagram) void {
        s.received += 1;
        const packet = protocol.decode(datagram.bytes()) catch {
            s.malformed += 1;
            return;
        };
        const place = matches_.find(s.matches, datagram.from);
        // Only acknowledgements: a Client sends no Announcements.
        if (place) |p| {
            if (s.channels[p.match][p.player]) |*channel| channel.incoming(engine.time.timestamp(s.io), packet.link, &.{});
        }
        switch (packet.message) {
            .connect => s.connect(datagram.from, packet.link),
            .input => |input| {
                if (place) |p| s.matches[p.match].receive(p.player, input) else s.ignored += 1;
            },
            .disconnect => {
                if (place) |p| s.leave(p) else s.ignored += 1;
            },
            // Messages only the Server sends.
            .accept, .refusal, .snapshot => s.ignored += 1,
        }
    }

    fn connect(s: *Server, peer: net.Endpoint, link: engine.reliable.Header) void {
        const known = matches_.find(s.matches, peer) != null;
        const place = matches_.place(s.matches, peer) catch |err| {
            s.sendOutside(peer, .{ .refusal = .{ .reason = switch (err) {
                error.MatchFull => .match_full,
                error.AlreadyStarted => .already_started,
            } } });
            if (!known) log(s.io, "Tick {d}: refused {f}: {t}", .{ s.now(), peer, err });
            return;
        };
        if (!known) {
            const channel = &s.channels[place.match][place.player];
            channel.* = .{};
            channel.*.?.incoming(engine.time.timestamp(s.io), link, &.{});
            log(s.io, "Tick {d}: Match {d}, Player {d} joined from {f}", .{ s.now(), place.match + 1, place.player + 1, peer });
            s.announce(place.match, .{ .player_joined = .{ .player = place.player } });
        }
        s.send(place, .{ .accept = .{ .player = place.player } });
    }

    fn leave(s: *Server, place: Place) void {
        s.matches[place.match].leave(place.player);
        s.close(place);
        log(s.io, "Tick {d}: Match {d}, Player {d} left", .{ s.now(), place.match + 1, place.player + 1 });
        s.announce(place.match, .{ .player_left = .{ .player = place.player } });
    }

    fn close(s: *Server, place: Place) void {
        const slot = &s.channels[place.match][place.player];
        const channel = &(slot.* orelse return);
        s.resent += channel.resent;
        slot.* = null;
    }

    /// Sends a Player `message`, with the Announcements their channel has
    /// to send again or for the first time.
    fn send(s: *Server, place: Place, message: protocol.Message) void {
        const channel = &(s.channels[place.match][place.player] orelse return);
        const peer = (s.matches[place.match].players[place.player] orelse return).peer;
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

    /// Tells every Player of Match `m` of something that happened in it this
    /// Tick: it goes out with their next datagrams until they acknowledge
    /// it. A Player whose channel is full has stopped acknowledging, and
    /// times out.
    fn announce(s: *Server, m: u8, event: protocol.Announcement.Event) void {
        const match = &s.matches[m];
        const announcement: protocol.Announcement = .{ .tick = match.tick, .event = event };
        for (0..protocol.max_players) |index| {
            const place: Place = .{ .match = m, .player = @intCast(index) };
            const channel = &(s.channels[m][index] orelse continue);
            channel.send(announcement) catch {
                log(s.io, "Tick {d}: Match {d}, Player {d} timed out: {d} Announcements unacknowledged", .{ match.tick, m + 1, place.player + 1, engine.reliable.window });
                match.leave(place.player);
                s.close(place);
                // Told to the Players left; at most once per Player, so this ends.
                s.announce(m, .{ .player_timed_out = .{ .player = place.player } });
            };
        }
    }

    fn report(s: *const Server) void {
        var resent = s.resent;
        for (s.channels) |*channels| {
            for (channels) |slot| resent += if (slot) |channel| channel.resent else 0;
        }
        var players: usize = 0;
        var busy: usize = 0;
        for (s.matches) |*match| {
            players += match.playerCount();
            busy += @intFromBool(match.playerCount() > 0);
        }
        log(s.io, "Tick {d}: {d} Players in {d} of {d} Matches, {d} datagrams received, {d} malformed, {d} ignored, {d} dropped by the transport, {d} bytes sent, {d} Announcements resent", .{
            s.now(),
            players,
            busy,
            s.matches.len,
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
    const arena = init.arena.allocator();
    const matches = try arena.alloc(Match, options.matches);
    matches_.init(matches, settings);
    const channels = try arena.alloc(Channels, options.matches);
    @memset(channels, @splat(null));
    var server: Server = .{ .io = io, .transport = transport, .matches = matches, .channels = channels, .snapshot_every = options.snapshot_every };
    log(io, "r-type_server: listening on UDP port {d}, {d} Matches of up to {d} Players, {d} Ticks per second", .{ transport.localPort(), options.matches, protocol.max_players, tick_rate });

    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    while (true) {
        for (0..try ticks.wait()) |_| server.tick();
    }
}

const testing = std.testing;

test "options default to #2's settings" {
    const options = parseOptions(&.{}).?;
    try testing.expectEqual(4242, options.port);
    try testing.expectEqual(5, options.matches);
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
    try testing.expectEqual(1, parseOptions(&.{ "--matches", "1" }).?.matches);
}

test "bad options are refused" {
    try testing.expectEqual(null, parseOptions(&.{"--port"}));
    try testing.expectEqual(null, parseOptions(&.{ "--hit-points", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--snapshot-every", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--join-window", "-1" }));
    try testing.expectEqual(null, parseOptions(&.{ "--invulnerability", "2000" })); // beyond a u16 of Ticks
    try testing.expectEqual(null, parseOptions(&.{ "--game-over-pause", "nan" }));
    try testing.expectEqual(null, parseOptions(&.{ "--speed", "2" }));
    try testing.expectEqual(null, parseOptions(&.{ "--matches", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--matches", "256" }));
}

test {
    _ = matches_;
}
