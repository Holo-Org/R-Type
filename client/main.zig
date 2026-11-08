//! r-type_client: shows the Match and sends the Player's inputs every Tick.
//! Players are numbered from 1 on screen and in logs; the protocol counts from 0.
//! The keys and gamepad buttons for each Action come from settings.zon.
//!
//! The Engine's network thread receives the Server's datagrams; the main
//! thread drains them every Frame, sends one input per Tick whatever the frame
//! rate, and draws the newest snapshot. Outside a Match, it keeps trying to
//! join and says why it waits. Esc leaves (see leaving.zig). With `--demo`, a
//! Match runs inside the Client instead, and no Server is needed.

const std = @import("std");
const Io = std.Io;
const engine = @import("engine_client");
const engine_headless = @import("engine_headless");
const net = engine_headless.net;
const FixedStep = engine_headless.time.FixedStep;
const Channel = engine_headless.reliable.Channel(protocol.Announcement);
const game = @import("game");
const protocol = game.protocol;
const Actions = protocol.Actions;
const tick_rate = game.match.tick_rate;
const screen_width = game.match.screen_width;
const screen_height = game.match.screen_height;

const Settings = @import("settings.zig").Settings;
const demo_ = @import("demo.zig");
const Demo = demo_.Demo;
const hud = @import("hud.zig");
const sound = @import("sound.zig");
const View = @import("view.zig").View;
const scene_ = @import("scene.zig");
const Connection = @import("connection.zig").Connection;
const Leaving = @import("leaving.zig").Leaving;

const usage = "usage: r-type_client [--host <host>] [--port <port>] [--demo <seed>] [--script <n>] [--frames <n> [--screenshot <file.png>]]";

fn log(io: Io, comptime format: []const u8, args: anytype) void {
    const stderr = io.lockStderr(&.{}, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format ++ "\n", args) catch {};
}

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4242,
    /// Play a Match run inside the Client, from this seed.
    demo: ?u64 = null,
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
        } else if (std.mem.eql(u8, name, "--demo")) {
            options.demo = std.fmt.parseInt(u64, value, 10) catch return null;
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

/// The Actions whose keys or gamepad buttons the Player holds.
fn heldActions(window: *const engine.Window, settings: *const Settings) Actions {
    return .of(window.actionsHeld(protocol.Action, settings.bindings));
}

/// The Client's end of the conversation with the Server: a reliable channel
/// that acknowledges every datagram and hands the Announcements over once
/// each, in order, and the newest Snapshot's Tick, to drop the older ones.
const ServerLink = struct {
    io: Io,
    transport: *net.UdpTransport,
    server: net.Endpoint,
    channel: Channel = .{},
    /// The Tick of the newest Snapshot shown; null before the first.
    newest: ?u32 = null,

    fn send(link: *ServerLink, message: protocol.Message) void {
        var none: [0]protocol.Numbered = .{};
        const out = link.channel.outgoing(engine_headless.time.timestamp(link.io), &none);
        const encoded = protocol.encode(.{ .link = out.header, .message = message });
        link.transport.send(link.server, encoded.bytes());
    }

    /// The next message from the Server, oldest first; null once none is
    /// left. The Announcements a datagram carries go to `channel`, before
    /// its message: call `channel.next` first.
    fn receive(link: *ServerLink) ?protocol.Message {
        while (link.transport.receive()) |datagram| {
            if (!datagram.from.eql(link.server)) continue;
            const packet = protocol.decode(datagram.bytes()) catch continue; // malformed
            link.channel.incoming(engine_headless.time.timestamp(link.io), packet.link, packet.announcements.slice());
            if (packet.message == .snapshot) {
                const tick = packet.message.snapshot.tick;
                if (link.newest) |newest| {
                    // Overtaken by a newer Snapshot, across the Tick counter wrapping.
                    if (tick -% newest -% 1 >= 1 << 31) continue;
                }
                link.newest = tick;
            }
            return packet.message;
        }
        return null;
    }

    /// Back to how it was before the first connect: the Server forgot the
    /// Connection, and the next one starts afresh.
    fn reset(link: *ServerLink) void {
        link.channel = .{};
        link.newest = null;
    }
};

/// Where the Scenes come from.
const Source = union(enum) {
    server: ServerLink,
    demo: Demo,
};

fn run(gpa: std.mem.Allocator, io: Io, options: Options, settings: *const Settings) !void {
    var transport: ?*net.UdpTransport = null;
    defer if (transport) |t| t.close();
    var source: Source = if (options.demo) |seed| .{ .demo = .init(seed) } else server: {
        const server = net.resolve(io, options.host, options.port) orelse return error.CannotResolve;
        transport = try net.UdpTransport.open(gpa, io, 0);
        break :server .{ .server = .{ .io = io, .transport = transport.?, .server = server } };
    };

    // Released in the reverse order, by the defers: the sound before the
    // audio device, the textures before the window.
    var window = try engine.Window.open(screen_width, screen_height, "R-Type", 60);
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
    var view: View = try .init(&window);
    defer view.deinit();

    var me: ?u8 = null; // our Player index, once accepted
    var connection: Connection = .init(0);
    var leaving: Leaving = .{};
    var input: protocol.Input = .{};
    var tick: u32 = 0;
    var ticks: FixedStep = .init(io, .fromNanoseconds(std.time.ns_per_s / tick_rate));
    switch (source) {
        .server => |link| log(io, "r-type_client: connecting to {f}", .{link.server}),
        .demo => |demo| {
            log(io, "r-type_client: playing a demo Match of seed {d}", .{demo.match.settings.seed});
            me = 0;
        },
    }

    var frame_count: u32 = 0;
    while (!window.shouldClose()) {
        frame_count += 1;
        if (source == .server) {
            const link = &source.server;
            while (link.receive()) |message| {
                connection.heard(tick);
                // The Announcements, before the Scene the entities vanished from.
                while (link.channel.next()) |announcement| {
                    const was = me;
                    announce(io, &view, &me, announcement);
                    if (was != null and me == null) { // dropped by the Server
                        link.reset();
                        view.clear();
                        connection.dropped(tick);
                    }
                }
                switch (message) {
                    .accept => |accepted| {
                        if (me != accepted.player) log(io, "Joined the Match as Player {d}", .{accepted.player + 1});
                        me = accepted.player;
                        connection.accepted();
                    },
                    // Connects keep going out until a join window takes one.
                    .refusal => |refusal| {
                        if (me == null) {
                            const before = connection.waiting;
                            connection.refused(tick, refusal.reason);
                            if (connection.waiting != before) log(io, "{s}", .{waitingText(connection.waiting.?)});
                        }
                    },
                    .snapshot => |snapshot| view.show(.fromSnapshot(&snapshot)),
                    // Messages only Clients send.
                    .connect, .input, .disconnect => {},
                }
            }
        }

        for (0..ticks.poll()) |_| {
            tick +%= 1;
            const actions = if (options.script) |pattern| demo_.scriptedActions(pattern, tick) else heldActions(&window, settings);
            const previous = input.recent;
            input.recent = .{ .{ .tick = tick, .actions = actions }, previous[0], previous[1] };
            if (actions.fire and !previous[0].actions.fire) {
                if (pew) |*p| p.play();
            }
            switch (source) {
                .server => |*link| {
                    if (connection.checkLost(tick)) {
                        log(io, "Lost the Server: reconnecting", .{});
                        me = null;
                        link.reset();
                        view.clear();
                    }
                    if (me != null) {
                        link.send(.{ .input = input });
                    } else if (connection.connectDue(tick)) {
                        link.send(.{ .connect = .{} });
                    }
                },
                .demo => |*demo| {
                    // The Announcements, before the Scene the entities vanished from.
                    const events = demo.step(actions);
                    for (events.explosionSlice()) |position| view.enemyDestroyed(position);
                    for (events.shipDestroyedSlice()) |destroyed| view.shipDestroyed(destroyed.position);
                    view.show(.fromSnapshot(&demo.match.snapshot()));
                },
            }
        }

        view.advance(window.frameTime());
        if (window.escapePressed() and leaving.escape(view.clock, view.shipAlive(me))) break;
        const last_frame = if (options.frames) |frames| frame_count >= frames else false;
        var frame = window.beginFrame(.black);
        view.draw(&frame, me);
        if (source == .server) {
            if (connection.waiting) |why| {
                var buffer: [64]u8 = undefined;
                const text = if (why == .connecting)
                    std.fmt.bufPrint(&buffer, "Connecting to {f}... {d} s", .{ source.server.server, connection.secondsWaiting(tick) }) catch unreachable
                else
                    waitingText(why);
                hud.drawWaiting(&frame, text);
            } else {
                const traffic = source.server.channel.traffic();
                const expected = traffic.received + traffic.lost;
                const lost = if (expected == 0) 0 else 100 * @as(f64, @floatFromInt(traffic.lost)) / @as(f64, @floatFromInt(expected));
                hud.drawNetwork(&frame, @intCast(@divTrunc(traffic.round_trip.nanoseconds, std.time.ns_per_ms)), lost);
            }
        }
        if (leaving.asking(view.clock)) hud.drawLeavePrompt(&frame);
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

    if (source == .server and me != null) source.server.send(.disconnect);
}

/// Why the Client waits, but for `connecting`, which names the Server.
fn waitingText(why: @import("connection.zig").Waiting) []const u8 {
    return switch (why) {
        .connecting => "Connecting...",
        .match_full => "The Match is full: waiting for the next one",
        .already_started => "The Match has already started: waiting for the next one",
        .lost => "Lost the Server: reconnecting...",
    };
}

/// Visual Announcements later than this are not shown: their entity has
/// long vanished from the screen.
const too_late = tick_rate / 4;

/// Logs what concerns the Players, and starts the effects of the visual
/// Announcements. Comes before the Scene the entities vanished from.
fn announce(io: Io, view: *View, me: *?u8, announcement: protocol.Announcement) void {
    const age = view.scene.tick -% announcement.tick;
    const late = age > too_late and age < 1 << 31; // not from a Tick ahead of the Scene
    switch (announcement.event) {
        .player_joined => |joined| log(io, "Player {d} joined the Match", .{joined.player + 1}),
        .player_left, .player_timed_out => |gone| {
            const how = if (announcement.event == .player_left) "left" else "timed out";
            log(io, "Player {d} {s}", .{ gone.player + 1, how });
            if (me.* == gone.player) me.* = null; // dropped by the Server: connect again
        },
        .explosion => |at| if (!late) view.enemyDestroyed(scene_.position(at.x, at.y)),
        .ship_destroyed => |ship| if (!late) view.shipDestroyed(scene_.position(ship.x, ship.y)),
        .game_over => log(io, "Game over", .{}),
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) orelse {
        log(io, usage, .{});
        return 2;
    };
    const settings = engine_headless.settings.load(Settings, init.arena.allocator(), io, init.environ_map, .{
        .app = "r-type",
        .name = "settings.zon",
        .defaults = @import("settings.zig").defaults_file,
    });
    run(init.gpa, io, options, &settings) catch |err| {
        switch (err) {
            error.CannotResolve => log(io, "r-type_client: cannot resolve {s}", .{options.host}),
            else => log(io, "r-type_client: {t}", .{err}),
        }
        return 1;
    };
    return 0;
}

test {
    _ = @import("settings.zig");
    _ = @import("sprites.zig");
    _ = @import("scene.zig");
    _ = @import("effects.zig");
    _ = @import("view.zig");
    _ = @import("connection.zig");
    _ = @import("leaving.zig");
    _ = demo_;
}
