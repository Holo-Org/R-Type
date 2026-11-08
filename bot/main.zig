//! r-type_bot: runs scripted Clients in one process, to load-test the Server
//! and measure it: `--clients 20` stands in for a full 20-Player session.
//! Each bot has a socket of its own, so the Server sees a Player for each.
//! A bot connects, weaves up and down while holding fire, and leaves after
//! `--seconds`; then each prints what it measured of its Connection, and
//! the program fails if a bot never joined or lost the Server.
//!
//! Like the Server, it builds on the headless Engine and the Game only: no
//! window, no raylib. Bots are numbered from 1, Players too, as in the
//! Client's logs.

const std = @import("std");
const Io = std.Io;
const engine = @import("engine_headless");
const game = @import("game");
const net = engine.net;
const protocol = game.protocol;
const FixedStep = engine.time.FixedStep;
const Channel = engine.reliable.Channel(protocol.Announcement);
const tick_rate = game.match.tick_rate;

const usage = "usage: r-type_bot [--host <host>] [--port <port>] [--clients <n>] [--seconds <s>]";

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4242,
    clients: u16 = 20,
    seconds: u32 = 60,
};

fn parseOptions(args: []const [:0]const u8) ?Options {
    if (args.len % 2 != 0) return null; // an option without its value
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, name, "--host")) {
            options.host = value;
        } else if (std.mem.eql(u8, name, "--port")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch return null;
        } else if (std.mem.eql(u8, name, "--clients")) {
            options.clients = std.fmt.parseInt(u16, value, 10) catch return null;
            if (options.clients == 0 or options.clients > max_clients) return null;
        } else if (std.mem.eql(u8, name, "--seconds")) {
            options.seconds = std.fmt.parseInt(u32, value, 10) catch return null;
            if (options.seconds == 0) return null;
        } else return null;
    }
    return options;
}

/// Each bot runs a network thread: beyond a few hundred, use several
/// processes.
const max_clients = 256;

/// A bot that has heard nothing from the Server for this long has lost it,
/// as a Client would.
const silence_limit = 3 * tick_rate;

/// What bot `index` holds at Tick `tick`: it weaves up and down, each bot
/// out of step with the others, and holds fire, as auto-fire would.
fn scriptedActions(index: u16, tick: u32) protocol.Actions {
    const leg = 40;
    const up = ((tick +% @as(u32, index) * 7) / leg) % 2 == 0;
    return .{ .up = up, .down = !up, .fire = true };
}

const Bot = struct {
    index: u16,
    io: Io,
    transport: *net.UdpTransport,
    server: net.Endpoint,
    channel: Channel = .{},
    /// Our Player index, once accepted.
    me: ?u8 = null,
    /// Refused because every Match is full: it stops trying.
    gave_up: bool = false,
    tick: u32 = 0,
    input: protocol.Input = .{},
    /// The bot's Tick of its first accept, and of its latest datagram.
    joined_at: ?u32 = null,
    last_heard: ?u32 = null,
    snapshots: u64 = 0,
    announcements: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,

    fn step(bot: *Bot) void {
        bot.tick +%= 1;
        bot.receiveAll();
        if (bot.gave_up) return;
        if (bot.me != null) {
            const previous = bot.input.recent;
            bot.input.recent = .{ .{ .tick = bot.tick, .actions = scriptedActions(bot.index, bot.tick) }, previous[0], previous[1] };
            bot.send(.{ .input = bot.input });
        } else if (bot.tick % (tick_rate / 2) == 1) {
            bot.send(.{ .connect = .{} }); // twice a second, until the Server answers
        }
    }

    fn receiveAll(bot: *Bot) void {
        while (bot.transport.receive()) |datagram| {
            if (!datagram.from.eql(bot.server)) continue;
            const packet = protocol.decode(datagram.bytes()) catch continue; // malformed
            bot.bytes_in += datagram.bytes().len;
            bot.last_heard = bot.tick;
            bot.channel.incoming(engine.time.timestamp(bot.io), packet.link, packet.announcements.slice());
            while (bot.channel.next()) |announcement| {
                bot.announcements += 1;
                switch (announcement.event) {
                    // Dropped by the Server: connect again, afresh.
                    .player_left, .player_timed_out => |gone| if (bot.me == gone.player) {
                        bot.me = null;
                        bot.channel = .{};
                    },
                    else => {},
                }
            }
            switch (packet.message) {
                .accept => |accepted| {
                    if (bot.joined_at == null) bot.joined_at = bot.tick;
                    bot.me = accepted.player;
                },
                .refusal => |refusal| if (refusal.reason == .match_full) {
                    bot.gave_up = true;
                },
                .snapshot => bot.snapshots += 1,
                .connect, .input, .disconnect => {}, // messages only Clients send
            }
        }
    }

    fn send(bot: *Bot, message: protocol.Message) void {
        var none: [0]protocol.Numbered = .{};
        const out = bot.channel.outgoing(engine.time.timestamp(bot.io), &none);
        const encoded = protocol.encode(.{ .link = out.header, .message = message });
        bot.bytes_out += encoded.len;
        bot.transport.send(bot.server, encoded.bytes());
    }

    /// Whether the Server answered within `silence_limit` of the end.
    fn heardRecently(bot: *const Bot) bool {
        const last = bot.last_heard orelse return false;
        return bot.tick -% last <= silence_limit;
    }

    /// One line of what the bot measured, "in" being what it received from
    /// the Server, and "out" what it sent.
    fn report(bot: *const Bot) void {
        const traffic = bot.channel.traffic();
        const joined = bot.joined_at orelse {
            log(bot.io, "Bot {d}: never joined{s}", .{ bot.index + 1, if (bot.gave_up) ": every Match was full" else "" });
            return;
        };
        const seconds = @as(f64, @floatFromInt(@max(1, bot.tick -% joined))) / tick_rate;
        const expected = traffic.received + traffic.lost;
        log(bot.io, "Bot {d}: Player {d}, {d} Snapshots, {d} Announcements{s}; round trip {d} ms; in: {d} datagrams, {d} lost ({d:.1}%), {d} duplicated, {d} late, {d} B each, {d:.1} KB/s; out: {d} datagrams, {d} unacknowledged, {d} B each, {d:.1} KB/s", .{
            bot.index + 1,
            (bot.me orelse 0) + 1,
            bot.snapshots,
            bot.announcements,
            if (bot.heardRecently()) "" else ", Server lost",
            @divTrunc(traffic.round_trip.nanoseconds, std.time.ns_per_ms),
            traffic.received,
            traffic.lost,
            if (expected == 0) 0 else 100 * @as(f64, @floatFromInt(traffic.lost)) / @as(f64, @floatFromInt(expected)),
            traffic.duplicated,
            traffic.late,
            if (traffic.received == 0) 0 else bot.bytes_in / traffic.received,
            @as(f64, @floatFromInt(bot.bytes_in)) / 1000 / seconds,
            traffic.sent,
            traffic.unacknowledged,
            if (traffic.sent == 0) 0 else bot.bytes_out / traffic.sent,
            @as(f64, @floatFromInt(bot.bytes_out)) / 1000 / seconds,
        });
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseOptions(args[1..]) orelse {
        log(io, usage, .{});
        return 2;
    };
    const server = net.resolve(io, options.host, options.port) orelse {
        log(io, "r-type_bot: cannot resolve {s}", .{options.host});
        return 1;
    };

    const bots = try arena.alloc(Bot, options.clients);
    var opened: usize = 0;
    defer for (bots[0..opened]) |*bot| bot.transport.close();
    for (bots, 0..) |*bot, index| {
        const transport = net.UdpTransport.open(init.gpa, io, 0) catch |err| {
            log(io, "r-type_bot: cannot open a socket for bot {d}: {t}", .{ index + 1, err });
            return 1;
        };
        bot.* = .{ .index = @intCast(index), .io = io, .transport = transport, .server = server };
        opened += 1;
    }
    log(io, "r-type_bot: {d} bots playing on {f} for {d} s", .{ options.clients, server, options.seconds });

    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    var elapsed: u64 = 0;
    const total = @as(u64, options.seconds) * tick_rate;
    while (elapsed < total) {
        for (0..try ticks.wait()) |_| {
            for (bots) |*bot| bot.step();
            elapsed += 1;
        }
    }
    for (bots) |*bot| {
        if (bot.me != null) bot.send(.disconnect);
    }

    var failed: usize = 0;
    for (bots) |*bot| {
        bot.report();
        if (bot.joined_at == null or !bot.heardRecently()) failed += 1;
    }
    if (failed > 0) {
        log(io, "r-type_bot: {d} of {d} bots never joined or lost the Server", .{ failed, bots.len });
        return 1;
    }
    log(io, "r-type_bot: all {d} bots joined and kept the Server until the end", .{bots.len});
    return 0;
}

const testing = std.testing;

test "options" {
    const defaults = parseOptions(&.{}).?;
    try testing.expectEqual(20, defaults.clients);
    try testing.expectEqual(60, defaults.seconds);
    try testing.expectEqual(4, parseOptions(&.{ "--clients", "4", "--seconds", "10" }).?.clients);
    try testing.expectEqual(null, parseOptions(&.{ "--clients", "0" }));
    try testing.expectEqual(null, parseOptions(&.{ "--clients", "257" }));
    try testing.expectEqual(null, parseOptions(&.{ "--seconds", "0" }));
    try testing.expectEqual(null, parseOptions(&.{"--host"}));
}

test "bots weave out of step, and always fire" {
    try testing.expect(scriptedActions(0, 0).up);
    try testing.expect(scriptedActions(0, 40).down);
    try testing.expect(scriptedActions(0, 0).fire and scriptedActions(3, 99).fire);
    try testing.expect(scriptedActions(0, 39).up != scriptedActions(1, 39).up);
}
