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
    \\                     [--game-over-pause <seconds>] [--stats <file.csv>]
;

/// A Player's Connection, as the Server keeps it: its reliable channel, and
/// what it has carried.
const Connection = struct {
    channel: Channel = .{},
    /// The Tick the Connection began at.
    since: u32,
    /// UDP payload bytes, without the IP and UDP headers.
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
};

/// A Match's Connections, by Player index; null where no Player is.
const Connections = [protocol.max_players]?Connection;

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
    /// A CSV file the Server writes each Connection's figures to, at every
    /// report and when the Connection ends.
    stats: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, name, "--stats")) {
            options.stats = value;
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
    /// Each Match's Connections, by the Match's index.
    connections: []Connections,
    snapshot_every: u8,
    /// Where `--stats` writes; null without it, or once writing failed.
    stats: ?Io.File = null,
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
                if (s.connections[m][player] != null) s.send(.{ .match = m, .player = @intCast(player) }, .{ .snapshot = snapshot });
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
        if (place) |p| {
            if (s.connections[p.match][p.player]) |*connection| {
                connection.bytes_in += datagram.bytes().len;
                // Only acknowledgements: a Client sends no Announcements.
                connection.channel.incoming(engine.time.timestamp(s.io), packet.link, &.{});
            }
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
            const slot = &s.connections[place.match][place.player];
            slot.* = .{ .since = s.now() };
            slot.*.?.channel.incoming(engine.time.timestamp(s.io), link, &.{});
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

    /// Ends a Connection, reporting what it measured over its whole life.
    fn close(s: *Server, place: Place) void {
        const slot = &s.connections[place.match][place.player];
        const connection = &(slot.* orelse return);
        s.resent += connection.channel.resent;
        s.reportConnection(place, connection, .closed);
        slot.* = null;
    }

    /// Sends a Player `message`, with the Announcements their channel has
    /// to send again or for the first time.
    fn send(s: *Server, place: Place, message: protocol.Message) void {
        const connection = &(s.connections[place.match][place.player] orelse return);
        const peer = (s.matches[place.match].players[place.player] orelse return).peer;
        var room: [protocol.max_announcements]protocol.Numbered = undefined;
        const out = connection.channel.outgoing(engine.time.timestamp(s.io), &room);
        var packet: protocol.Packet = .{ .link = out.header, .message = message };
        for (out.messages) |entry| packet.announcements.add(entry);
        connection.bytes_out += s.transmit(peer, &packet);
    }

    /// Answers a peer that has no Connection.
    fn sendOutside(s: *Server, peer: net.Endpoint, message: protocol.Message) void {
        _ = s.transmit(peer, &.{ .message = message });
    }

    /// Sends `packet` to `peer`, and returns its size.
    fn transmit(s: *Server, peer: net.Endpoint, packet: *const protocol.Packet) usize {
        const encoded = protocol.encode(packet.*);
        s.bytes_sent += encoded.len;
        s.transport.send(peer, encoded.bytes());
        return encoded.len;
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
            const connection = &(s.connections[m][index] orelse continue);
            connection.channel.send(announcement) catch {
                log(s.io, "Tick {d}: Match {d}, Player {d} timed out: {d} Announcements unacknowledged", .{ match.tick, m + 1, place.player + 1, engine.reliable.window });
                match.leave(place.player);
                s.close(place);
                // Told to the Players left; at most once per Player, so this ends.
                s.announce(m, .{ .player_timed_out = .{ .player = place.player } });
            };
        }
    }

    /// Every 5 s: the whole Server's counts, then each Connection's figures.
    fn report(s: *Server) void {
        var resent = s.resent;
        for (s.connections) |*connections| {
            for (connections) |slot| resent += if (slot) |connection| connection.channel.resent else 0;
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
        for (s.connections, 0..) |*connections, m| {
            for (connections, 0..) |*slot, player| {
                const connection = &(slot.* orelse continue);
                s.reportConnection(.{ .match = @intCast(m), .player = @intCast(player) }, connection, .report);
            }
        }
    }

    const Moment = enum { report, closed };

    /// Logs a Connection's figures, and writes them to the `--stats` file.
    /// "In" is what the Server received from the Client, "out" what it sent.
    fn reportConnection(s: *Server, place: Place, connection: *const Connection, moment: Moment) void {
        const figures: Figures = .of(connection, s.now());
        log(s.io, "Tick {d}: Match {d}, Player {d}{s}: round trip {d} ms; in: {d} datagrams, {d} lost ({d:.1}%), {d} duplicated, {d} late, {d} B each, {d:.1} KB/s; out: {d} datagrams, {d} unacknowledged, {d} B each, {d:.1} KB/s", .{
            s.now(),
            place.match + 1,
            place.player + 1,
            if (moment == .closed) ", at the end" else "",
            figures.round_trip_ms,
            figures.traffic.received,
            figures.traffic.lost,
            figures.lost_percent,
            figures.traffic.duplicated,
            figures.traffic.late,
            figures.average_in,
            figures.kbps_in,
            figures.traffic.sent,
            figures.traffic.unacknowledged,
            figures.average_out,
            figures.kbps_out,
        });
        const file = s.stats orelse return;
        var buffer: [256]u8 = undefined;
        const row = figures.csvRow(&buffer, place, s.now(), moment) catch unreachable;
        file.writeStreamingAll(s.io, row) catch |err| {
            log(s.io, "r-type_server: cannot write the stats file ({t}); stopped writing it", .{err});
            file.close(s.io);
            s.stats = null;
        };
    }
};

/// A Connection's figures, from its reliable channel and its byte counts.
const Figures = struct {
    traffic: engine.reliable.Traffic,
    round_trip_ms: i64,
    seconds: f64,
    lost_percent: f64,
    bytes_in: u64,
    bytes_out: u64,
    /// Average datagram sizes, in bytes.
    average_in: u64,
    average_out: u64,
    kbps_in: f64,
    kbps_out: f64,

    pub const csv_header = "tick,seconds,match,player,moment,round_trip_ms,received,lost,duplicated,late,sent,unacknowledged,bytes_in,bytes_out\n";

    fn of(connection: *const Connection, now: u32) Figures {
        const traffic = connection.channel.traffic();
        const seconds = @max(1.0 / @as(f64, tick_rate), @as(f64, @floatFromInt(now -% connection.since)) / tick_rate);
        const expected = traffic.received + traffic.lost;
        return .{
            .traffic = traffic,
            .round_trip_ms = @intCast(@divTrunc(traffic.round_trip.nanoseconds, std.time.ns_per_ms)),
            .seconds = seconds,
            .lost_percent = ratio(traffic.lost, expected) * 100,
            .bytes_in = connection.bytes_in,
            .bytes_out = connection.bytes_out,
            .average_in = if (traffic.received == 0) 0 else connection.bytes_in / traffic.received,
            .average_out = if (traffic.sent == 0) 0 else connection.bytes_out / traffic.sent,
            .kbps_in = @as(f64, @floatFromInt(connection.bytes_in)) / 1000 / seconds,
            .kbps_out = @as(f64, @floatFromInt(connection.bytes_out)) / 1000 / seconds,
        };
    }

    fn ratio(part: u64, whole: u64) f64 {
        return if (whole == 0) 0 else @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
    }

    /// One line of the `--stats` file, matching `csv_header`.
    fn csvRow(f: *const Figures, buffer: []u8, place: Place, now: u32, moment: Server.Moment) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{d},{d:.1},{d},{d},{t},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            now,
            f.seconds,
            place.match + 1,
            place.player + 1,
            moment,
            f.round_trip_ms,
            f.traffic.received,
            f.traffic.lost,
            f.traffic.duplicated,
            f.traffic.late,
            f.traffic.sent,
            f.traffic.unacknowledged,
            f.bytes_in,
            f.bytes_out,
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
    const connections = try arena.alloc(Connections, options.matches);
    @memset(connections, @splat(null));
    var server: Server = .{ .io = io, .transport = transport, .matches = matches, .connections = connections, .snapshot_every = options.snapshot_every };
    if (options.stats) |path| {
        const file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            log(io, "r-type_server: cannot create {s}: {t}", .{ path, err });
            return 1;
        };
        file.writeStreamingAll(io, Figures.csv_header) catch |err| {
            log(io, "r-type_server: cannot write {s}: {t}", .{ path, err });
            return 1;
        };
        server.stats = file;
    }
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
    try testing.expectEqualStrings("run.csv", parseOptions(&.{ "--stats", "run.csv" }).?.stats.?);
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

test "a Connection's figures, and their row in the stats file" {
    var connection: Connection = .{ .since = 0, .bytes_in = 6000, .bytes_out = 60000 };
    for ([_]u16{ 1, 2, 4 }) |sequence| {
        connection.channel.incoming(.zero, .{ .sequence = sequence, .ack = 0, .ack_bits = 0 }, &.{});
    }
    const figures: Figures = .of(&connection, 5 * tick_rate);
    try testing.expectEqual(5, figures.seconds);
    try testing.expectEqual(1, figures.traffic.lost); // 3
    try testing.expectApproxEqAbs(25, figures.lost_percent, 0.001);
    try testing.expectEqual(2000, figures.average_in);
    try testing.expectEqual(12, figures.kbps_out);
    var buffer: [256]u8 = undefined;
    const row = try figures.csvRow(&buffer, .{ .match = 1, .player = 2 }, 300, .report);
    try testing.expectEqualStrings("300,5.0,2,3,report,200,3,1,0,0,0,0,6000,60000\n", row);
    try testing.expectEqual(std.mem.count(u8, Figures.csv_header, ","), std.mem.count(u8, row, ","));
}

test {
    _ = matches_;
}
