//! r-type_client: shows the Match and sends the Player's inputs every Tick.
//! Players are numbered from 1 on screen and in logs; the protocol counts from 0.
//!
//! The Engine's network thread receives the Server's datagrams; the main
//! thread drains them every Frame, sends one input per Tick whatever the frame
//! rate, and draws the newest snapshot.

const std = @import("std");
const Io = std.Io;
const engine = @import("engine_client");
const net = @import("engine_headless").net;
const FixedStep = @import("engine_headless").time.FixedStep;
const game = @import("game");
const protocol = game.protocol;
const Buttons = protocol.Buttons;
const tick_rate = game.match.tick_rate;
const world_width = game.match.world_width;
const world_height = game.match.world_height;

const sound = @import("sound.zig");
const sprites = @import("sprites.zig");
const Starfield = @import("starfield.zig").Starfield;

const usage = "usage: r-type_client [--host <host>] [--port <port>] [--script <n>] [--frames <n> [--screenshot <file.png>]]";

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4242,
    /// Play unattended, following pattern N.
    script: ?u32 = null,
    /// Quit after N Frames.
    frames: ?u32 = null,
    /// Save the last Frame there.
    screenshot: ?[:0]const u8 = null,
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
        } else if (std.mem.eql(u8, name, "--script")) {
            options.script = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, name, "--frames")) {
            const frames = std.fmt.parseInt(u32, value, 10) catch return null;
            if (frames == 0) return null;
            options.frames = frames;
        } else if (std.mem.eql(u8, name, "--screenshot")) {
            options.screenshot = value;
        } else return null;
    }
    if (options.screenshot != null and options.frames == null) return null;
    return options;
}

fn keyboardButtons(window: *const engine.Window) Buttons {
    return .{
        .up = window.isKeyDown(.up),
        .down = window.isKeyDown(.down),
        .left = window.isKeyDown(.left),
        .right = window.isKeyDown(.right),
        .fire = window.isKeyDown(.space),
    };
}

/// Unattended play: every pattern flies a square, starting on a different
/// side, and fires every two seconds.
fn scriptedButtons(pattern: u32, tick: u32) Buttons {
    const legs = [_]Buttons{ .{ .right = true }, .{ .down = true }, .{ .left = true }, .{ .up = true } };
    const leg_ticks = 45;
    var buttons = legs[((tick / leg_ticks) +% pattern) % legs.len];
    buttons.fire = tick % (2 * tick_rate) == 0;
    return buttons;
}

fn drawHud(frame: *engine.Frame, me: ?u8, snapshot: *const protocol.Snapshot, server: net.Endpoint) void {
    var buffer: [64]u8 = undefined;
    if (me) |player| {
        const text = std.fmt.bufPrint(&buffer, "Player {d}", .{player + 1}) catch unreachable;
        frame.drawText(text, 16, 12, 20, sprites.player_colors[player]);
    } else {
        const text = std.fmt.bufPrint(&buffer, "Connecting to {f}...", .{server}) catch unreachable;
        frame.drawText(text, 16, 12, 20, .white);
    }
    const players = std.fmt.bufPrint(&buffer, "{d}/{d} Players", .{ snapshot.shipSlice().len, protocol.max_players }) catch unreachable;
    frame.drawText(players, world_width - 150, 12, 20, .white);
}

/// The Client's end of the conversation with the Server: numbers the
/// datagrams it sends, and drops the ones that arrive out of order.
const ServerLink = struct {
    transport: *net.UdpTransport,
    server: net.Endpoint,
    sequence: u32 = 0,
    server_sequence: u32 = 0,

    fn send(link: *ServerLink, message: protocol.Message) void {
        link.sequence +%= 1;
        const encoded = protocol.encode(.{ .sequence = link.sequence, .message = message });
        link.transport.send(link.server, encoded.bytes());
    }

    /// The next message from the Server, oldest first; null once none is left.
    fn receive(link: *ServerLink) ?protocol.Message {
        while (link.transport.receive()) |datagram| {
            if (!datagram.from.eql(link.server)) continue;
            const packet = protocol.decode(datagram.bytes()) catch continue; // malformed
            if (packet.sequence <= link.server_sequence) continue; // overtaken by a newer datagram
            link.server_sequence = packet.sequence;
            return packet.message;
        }
        return null;
    }
};

fn run(gpa: std.mem.Allocator, io: Io, options: Options) !void {
    const server = net.resolve(io, options.host, options.port) orelse return error.CannotResolve;
    const transport = try net.UdpTransport.open(gpa, io, 0);
    defer transport.close();
    var link: ServerLink = .{ .transport = transport, .server = server };

    // Released in the reverse order, by the defers: the sound before the
    // audio device, the textures before the window.
    var window = try engine.Window.open(world_width, world_height, "R-Type", 60);
    defer window.close();
    var audio: ?engine.AudioDevice = engine.AudioDevice.open() catch |err| no_audio: {
        log(io, "r-type_client: cannot open the audio output ({t}); playing without sound", .{err});
        break :no_audio null;
    };
    defer if (audio) |*device| device.close();
    const samples = sound.synthesizePew();
    const pew: ?engine.Sound = if (audio) |*device| device.loadSound(&samples, sound.sample_rate) catch |err| no_sound: {
        log(io, "r-type_client: cannot load the sound ({t})", .{err});
        break :no_sound null;
    } else null;
    defer if (pew) |*p| p.unload();
    const ships = try sprites.ShipSprites.load(&window);
    defer ships.unload();
    var starfield: Starfield = .init(world_width, world_height, 2026);

    var me: ?u8 = null; // our Player index, once accepted
    var latest: protocol.Snapshot = .{};
    var input: protocol.Input = .{};
    var tick: u32 = 0;
    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    log(io, "r-type_client: connecting to {f}", .{server});

    var frame_count: u32 = 0;
    while (!window.shouldClose()) {
        frame_count += 1;
        while (link.receive()) |message| {
            switch (message) {
                .accept => |accepted| {
                    if (me != accepted.player) log(io, "Joined the Match as Player {d}", .{accepted.player + 1});
                    me = accepted.player;
                },
                .reject => return error.MatchFull,
                .snapshot => |snapshot| latest = snapshot,
                .player_left => |left| {
                    log(io, "Player {d} left the Match", .{left.player + 1});
                    if (me == left.player) me = null; // dropped by the Server: connect again
                },
                // Messages only Clients send.
                .connect, .input, .disconnect => {},
            }
        }

        for (0..ticks.poll()) |_| {
            tick +%= 1;
            const buttons = if (options.script) |pattern| scriptedButtons(pattern, tick) else keyboardButtons(&window);
            const previous = input.recent;
            input.recent = .{ .{ .tick = tick, .buttons = buttons }, previous[0], previous[1] };
            if (buttons.fire and !previous[0].buttons.fire) {
                if (pew) |*p| p.play();
            }
            if (me != null) {
                link.send(.{ .input = input });
            } else if (tick % (tick_rate / 2) == 1) {
                link.send(.connect); // twice a second, until the Server answers
            }
        }

        starfield.scroll(window.frameTime());
        const last_frame = if (options.frames) |frames| frame_count >= frames else false;
        var frame = window.beginFrame(.black);
        starfield.draw(&frame);
        for (latest.shipSlice()) |ship| ships.draw(&frame, ship);
        drawHud(&frame, me, &latest, server);
        if (last_frame) {
            if (options.screenshot) |path| {
                if (frame.saveScreenshot(path)) {
                    log(io, "r-type_client: saved {s}", .{path});
                } else |err| {
                    log(io, "r-type_client: cannot save {s} ({t})", .{ path, err });
                }
            }
        }
        frame.end();
        if (last_frame) break;
    }

    if (me != null) link.send(.disconnect);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) orelse {
        log(io, usage, .{});
        return 2;
    };
    run(init.gpa, io, options) catch |err| {
        switch (err) {
            error.CannotResolve => log(io, "r-type_client: cannot resolve {s}", .{options.host}),
            error.MatchFull => log(io, "r-type_client: the Match is full", .{}),
            else => log(io, "r-type_client: {t}", .{err}),
        }
        return 1;
    };
    return 0;
}
