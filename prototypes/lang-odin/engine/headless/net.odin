// UDP transport: a socket served by its own network thread, which hands the
// datagrams it receives to the Tick loop through a bounded inbox.
//
// Built on `core:net`, whose receive blocks and cannot be cancelled. To stop
// the network thread, `close` raises a flag, then sends the socket a one-byte
// datagram on the loopback interface: the blocked receive returns, and the
// thread sees the flag. It repeats the datagram until the thread has ended, in
// case one is lost. (An empty datagram would do, but `net.send_udp` sends
// nothing at all when given no bytes, everywhere but on Linux.)
package headless

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

// An IPv4 address and a UDP port: a plain value that can key a peer table and
// compares with `==`.
Endpoint :: struct {
	address: [4]u8,
	port:    u16,
}

// Larger datagrams are dropped unread; this stays below common MTUs.
MAX_DATAGRAM_SIZE :: 1200
// Datagrams left waiting for the Tick loop; any more are dropped.
INBOX_CAPACITY :: 256

loopback :: proc(port: u16) -> Endpoint {
	return Endpoint{address = {127, 0, 0, 1}, port = port}
}

// Writes `endpoint` as `127.0.0.1:4242` into `buffer`, and returns that part.
endpoint_string :: proc(endpoint: Endpoint, buffer: []byte) -> string {
	a := endpoint.address
	return fmt.bprintf(buffer, "%d.%d.%d.%d:%d", a[0], a[1], a[2], a[3], endpoint.port)
}

// Resolves a dotted address or a host name to its first IPv4 endpoint.
resolve :: proc(host: string, port: u16) -> (endpoint: Endpoint, ok: bool) {
	if address, is_address := net.parse_ip4_address(host); is_address {
		return Endpoint{address = ([4]u8)(address), port = port}, true
	}
	// core:net's own resolver, which reads /etc/hosts and /etc/resolv.conf
	// on macOS and Linux; it allocates from the temporary allocator.
	found, err := net.resolve_ip4(host)
	if err != nil {
		return
	}
	address := found.address.(net.IP4_Address) or_return
	return Endpoint{address = ([4]u8)(address), port = port}, true
}

// One datagram, as it arrived.
Datagram :: struct {
	from:   Endpoint,
	len:    u16,
	buffer: [MAX_DATAGRAM_SIZE]byte,
}

datagram_bytes :: proc(datagram: ^Datagram) -> []byte {
	return datagram.buffer[:datagram.len]
}

// A UDP socket served by its own network thread. The thread fills a bounded
// inbox, which `receive` drains; `send` sends from the calling thread.
Udp_Transport :: struct {
	socket:         net.UDP_Socket,
	port:           u16,
	inbox:          chan.Chan(Datagram),
	// Updated atomically: datagrams dropped so far.
	dropped:        int,
	// Updated atomically: set by `close`.
	stopping:       bool,
	network_thread: ^thread.Thread,
	allocator:      runtime.Allocator,
}

Open_Error :: union #shared_nil {
	net.Create_Socket_Error,
	net.Bind_Error,
	net.Socket_Info_Error,
	runtime.Allocator_Error,
}

// Binds to `port` on every IPv4 interface (0 picks a free port) and starts
// the network thread. The transport and its inbox, about 300 KB, come from
// `allocator`; nothing else is allocated until `close`.
open :: proc(port: u16, allocator := context.allocator) -> (t: ^Udp_Transport, err: Open_Error) {
	socket := net.make_unbound_udp_socket(.IP4) or_return
	defer if err != nil {
		net.close(socket)
	}
	net.bind(socket, {address = net.IP4_Any, port = int(port)}) or_return
	bound := net.bound_endpoint(socket) or_return

	t = new(Udp_Transport, allocator) or_return
	defer if err != nil {
		free(t, allocator)
	}
	t.socket = socket
	t.port = u16(bound.port)
	t.allocator = allocator
	t.inbox = chan.create_buffered(chan.Chan(Datagram), INBOX_CAPACITY, allocator) or_return
	t.network_thread = thread.create_and_start_with_poly_data(t, receive_until_stopped)
	if t.network_thread == nil {
		chan.destroy(t.inbox)
		return nil, .Out_Of_Memory
	}
	return t, nil
}

// Stops the network thread, then closes the socket and frees the transport.
close :: proc(t: ^Udp_Transport) {
	sync.atomic_store(&t.stopping, true)
	wake_up := [1]byte{0}
	for !thread.is_done(t.network_thread) {
		send(t, loopback(t.port), wake_up[:])
		time.sleep(time.Millisecond)
	}
	thread.join(t.network_thread)
	thread.destroy(t.network_thread)
	net.close(t.socket)
	chan.destroy(t.inbox)
	free(t, t.allocator)
}

// Sends one datagram. UDP gives no delivery guarantee, so a failed send is
// just a lost datagram. A socket may be used by two threads at once, so the
// send needs no detour through the network thread.
send :: proc(t: ^Udp_Transport, to: Endpoint, bytes: []byte) {
	_, _ = net.send_udp(t.socket, bytes, {address = net.IP4_Address(to.address), port = int(to.port)})
}

// Takes the oldest datagram received and not taken yet, if any. Never blocks.
receive :: proc(t: ^Udp_Transport) -> (datagram: Datagram, ok: bool) {
	return chan.try_recv(t.inbox)
}

// Datagrams dropped so far: too large, inbox full, or a receive error.
dropped_count :: proc(t: ^Udp_Transport) -> int {
	return sync.atomic_load(&t.dropped)
}

// The network thread. Returns once `close` has raised `stopping`.
@(private)
receive_until_stopped :: proc(t: ^Udp_Transport) {
	// One spare byte: a datagram that fills it was too large.
	buffer: [MAX_DATAGRAM_SIZE + 1]byte
	for {
		size, from, err := net.recv_udp(t.socket, buffer[:])
		if sync.atomic_load(&t.stopping) {
			return
		}
		if err != nil {
			// A transient error, such as Windows reporting an ICMP "port
			// unreachable" from an earlier send: count it, keep receiving.
			drop(t)
			continue
		}
		address, is_ip4 := from.address.(net.IP4_Address)
		if !is_ip4 || size > MAX_DATAGRAM_SIZE {
			drop(t)
			continue
		}
		datagram := Datagram {
			from = Endpoint{address = ([4]u8)(address), port = u16(from.port)},
			len  = u16(size),
		}
		copy(datagram.buffer[:], buffer[:size])
		// Never waits for room in a full inbox.
		if !chan.try_send(t.inbox, datagram) {
			drop(t)
		}
	}
}

@(private)
drop :: proc(t: ^Udp_Transport) {
	sync.atomic_add(&t.dropped, 1)
}
