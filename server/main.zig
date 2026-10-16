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

const usage = "usage: r-type_server [--port <port>]";

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

fn parsePort(args: []const [:0]const u8) ?u16 {
    if (args.len == 0) return 4242;
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--port")) return null;
    return std.fmt.parseInt(u16, args[1], 10) catch null;
}

const Server = struct {
    io: Io,
    transport: *net.UdpTransport,
    match: Match = .{},
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
        var dropped = s.match.step().iterator(.{});
        while (dropped.next()) |player| {
            log(s.io, "Tick {d}: Player {d} timed out", .{ s.match.tick, player + 1 });
            s.tellEveryone(.{ .player_left = .{ .player = @intCast(player) } });
        }
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
        const player = s.match.join(peer) orelse {
            s.send(peer, .{ .reject = .{ .reason = .match_full } });
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
    const port = parsePort(args[1..]) orelse {
        log(io, usage, .{});
        return 2;
    };
    const transport = net.UdpTransport.open(init.gpa, io, port) catch |err| {
        log(io, "r-type_server: cannot listen on UDP port {d}: {t}", .{ port, err });
        return 1;
    };
    defer transport.close();
    var server: Server = .{ .io = io, .transport = transport };
    log(io, "r-type_server: listening on UDP port {d}, {d} Ticks per second", .{ transport.localPort(), tick_rate });

    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    while (true) {
        for (0..try ticks.wait()) |_| server.tick();
    }
}
