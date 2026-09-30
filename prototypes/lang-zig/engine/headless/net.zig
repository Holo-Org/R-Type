//! UDP transport: a socket served by its own network thread, which hands the
//! datagrams it receives to the Tick loop through a bounded inbox.
//!
//! Built on `std.Io.net`, Zig 0.16's networking. The network thread is a task
//! started with `io.concurrent`: with `std.Io.Threaded`, that is a thread of
//! its own, and cancelling it interrupts its blocked receive.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

/// An IPv4 address and a UDP port: a plain value that can key a peer table,
/// compares with `eql`, and prints as `127.0.0.1:4242` with `{f}`.
pub const Endpoint = net.Ip4Address;

/// Larger datagrams are dropped unread; this stays below common MTUs.
pub const max_datagram_size = 1200;
/// Datagrams left waiting for the Tick loop; any more are dropped.
pub const inbox_capacity = 256;

/// Resolves a dotted address or a host name to its first IPv4 endpoint.
pub fn resolve(io: Io, host: []const u8, port: u16) ?Endpoint {
    if (net.Ip4Address.parse(host, port)) |address| return address else |_| {}
    const name = net.HostName.init(host) catch return null;
    // 16 slots: enough for lookup() never to block (see its documentation).
    var slots: [16]net.HostName.LookupResult = undefined;
    var results: Io.Queue(net.HostName.LookupResult) = .init(&slots);
    name.lookup(io, &results, .{ .port = port, .family = .ip4 }) catch return null;
    while (results.getOne(io)) |result| switch (result) {
        .address => |address| switch (address) {
            .ip4 => |ip4| return ip4,
            .ip6 => {},
        },
        .canonical_name => {},
    } else |_| return null; // lookup() closes the queue when it is done
}

/// One datagram, as it arrived.
pub const Datagram = struct {
    from: Endpoint,
    len: u16,
    buffer: [max_datagram_size]u8,

    pub fn bytes(datagram: *const Datagram) []const u8 {
        return datagram.buffer[0..datagram.len];
    }
};

/// A UDP socket served by its own network thread. The thread fills a bounded
/// inbox, which `receive` drains; `send` sends from the calling thread.
pub const UdpTransport = struct {
    gpa: std.mem.Allocator,
    io: Io,
    socket: net.Socket,
    inbox: Io.Queue(Datagram),
    inbox_slots: [inbox_capacity]Datagram,
    dropped: std.atomic.Value(usize),
    network_thread: Io.Future(Io.Cancelable!void),

    pub const OpenError = net.IpAddress.BindError || Io.ConcurrentError || std.mem.Allocator.Error;

    /// Binds to `port` on every IPv4 interface (0 picks a free port) and
    /// starts the network thread. The transport lives on the heap, since the
    /// network thread holds a pointer to it: about 300 KB, mostly the inbox.
    pub fn open(gpa: std.mem.Allocator, io: Io, port: u16) OpenError!*UdpTransport {
        const t = try gpa.create(UdpTransport);
        errdefer gpa.destroy(t);
        const any_interface: net.IpAddress = .{ .ip4 = .unspecified(port) };
        const socket = try any_interface.bind(io, .{ .mode = .dgram, .protocol = .udp });
        errdefer socket.close(io);
        t.* = .{
            .gpa = gpa,
            .io = io,
            .socket = socket,
            .inbox = undefined,
            .inbox_slots = undefined,
            .dropped = .init(0),
            .network_thread = undefined,
        };
        t.inbox = .init(&t.inbox_slots);
        t.network_thread = try io.concurrent(receiveUntilCanceled, .{t});
        return t;
    }

    /// Stops the network thread, then closes the socket.
    pub fn close(t: *UdpTransport) void {
        t.network_thread.cancel(t.io) catch {}; // error.Canceled: stopped as asked
        t.socket.close(t.io);
        t.gpa.destroy(t);
    }

    /// Sends one datagram. UDP gives no delivery guarantee, so a failed send
    /// is just a lost datagram. A socket may be used by two threads at once,
    /// so unlike an Asio socket it needs no detour through the network thread.
    pub fn send(t: *UdpTransport, to: Endpoint, bytes: []const u8) void {
        const address: net.IpAddress = .{ .ip4 = to };
        t.socket.send(t.io, &address, bytes) catch {};
    }

    /// Takes the oldest datagram received and not taken yet, if any. Never
    /// blocks.
    pub fn receive(t: *UdpTransport) ?Datagram {
        var datagram: [1]Datagram = undefined;
        const count = t.inbox.getUncancelable(t.io, &datagram, 0) catch return null;
        return if (count == 1) datagram[0] else null;
    }

    /// Datagrams dropped so far: too large, inbox full, or a receive error.
    pub fn droppedCount(t: *const UdpTransport) usize {
        return t.dropped.load(.monotonic);
    }

    pub fn localPort(t: *const UdpTransport) u16 {
        return t.socket.address.getPort();
    }

    /// The network thread. Returns only when cancelled, by `close`.
    fn receiveUntilCanceled(t: *UdpTransport) Io.Cancelable!void {
        // One spare byte: a datagram that fills it was too large.
        var buffer: [max_datagram_size + 1]u8 = undefined;
        while (true) {
            const message = t.socket.receive(t.io, &buffer) catch |err| switch (err) {
                error.Canceled => |e| return e,
                // A transient error, such as Windows reporting an ICMP "port
                // unreachable" from an earlier send: count it, keep receiving.
                else => {
                    t.drop();
                    continue;
                },
            };
            const from = switch (message.from) {
                .ip4 => |ip4| ip4,
                .ip6 => {
                    t.drop();
                    continue;
                },
            };
            if (message.data.len > max_datagram_size or message.flags.trunc) {
                t.drop();
                continue;
            }
            var datagram: Datagram = .{ .from = from, .len = @intCast(message.data.len), .buffer = undefined };
            @memcpy(datagram.buffer[0..message.data.len], message.data);
            // At least 0 datagrams: never waits for room in a full inbox.
            const added = t.inbox.put(t.io, &.{datagram}, 0) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => return,
            };
            if (added == 0) t.drop();
        }
    }

    fn drop(t: *UdpTransport) void {
        _ = t.dropped.fetchAdd(1, .monotonic);
    }
};

test "a datagram crosses the loopback interface, and close stops the network thread" {
    const io = std.testing.io;
    const a = try UdpTransport.open(std.testing.allocator, io, 0);
    defer a.close();
    const b = try UdpTransport.open(std.testing.allocator, io, 0);
    defer b.close();

    b.send(.loopback(a.localPort()), "hello");
    for (0..2000) |_| {
        if (a.receive()) |datagram| {
            try std.testing.expectEqualStrings("hello", datagram.bytes());
            try std.testing.expectEqual(b.localPort(), datagram.from.port);
            return;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}
