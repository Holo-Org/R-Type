// r-type_server: runs one Match for up to four Players.
// Players are numbered from 1 in logs; the protocol counts from 0.
//
// Two threads: the Engine's network thread receives datagrams into the
// transport's inbox, and the main thread runs the 60 Hz Tick loop, which
// drains the inbox, advances the Match and sends every Player a snapshot.
// Logs go to stderr, one write per line, so they show up at once even when
// redirected.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import "../engine/headless"
import "../game"

USAGE :: "usage: r-type_server [--port <port>]"

log :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
}

// A decimal number up to `max_value`; digits only.
parse_number :: proc(text: string, max_value: u64) -> (value: u64, ok: bool) {
	if len(text) == 0 || len(text) > 10 {
		return // ten digits cannot overflow a u64
	}
	for c in text {
		if c < '0' || c > '9' {
			return
		}
	}
	value = strconv.parse_u64_of_base(text, 10) or_return
	return value, value <= max_value
}

parse_port :: proc(args: []string) -> (port: u16, ok: bool) {
	if len(args) == 0 {
		return 4242, true
	}
	if len(args) != 2 || args[0] != "--port" {
		return
	}
	value := parse_number(args[1], 65535) or_return
	return u16(value), true
}

Server :: struct {
	transport: ^headless.Udp_Transport,
	match:     game.Match,
	// Sequence number of the last datagram sent.
	sequence:  u32,
	received:  int,
	malformed: int,
	ignored:   int,
}

tick :: proc(s: ^Server) {
	// At most one inbox's worth per Tick, so a flood cannot stall the loop.
	for _ in 0 ..< headless.INBOX_CAPACITY {
		datagram := headless.receive(s.transport) or_break
		handle(s, &datagram)
	}
	for player in game.step(&s.match) {
		log("Tick %d: Player %d timed out", s.match.tick, player + 1)
		tell_everyone(s, game.Player_Left{player = u8(player)})
	}
	tell_everyone(s, game.snapshot(&s.match))
	if s.match.tick % (5 * game.TICK_RATE) == 0 {
		report(s)
	}
}

handle :: proc(s: ^Server, datagram: ^headless.Datagram) {
	s.received += 1
	packet, err := game.decode(headless.datagram_bytes(datagram))
	if err != .None {
		s.malformed += 1
		return
	}
	player, known := game.find(&s.match, datagram.from)
	switch message in packet.message {
	case game.Connect:
		connect(s, datagram.from)
	case game.Input:
		if known {
			game.receive(&s.match, player, message)
		} else {
			s.ignored += 1
		}
	case game.Disconnect:
		if known {
			leave(s, player)
		} else {
			s.ignored += 1
		}
	// Messages only the Server sends.
	case game.Accept, game.Reject, game.Snapshot, game.Player_Left:
		s.ignored += 1
	}
}

connect :: proc(s: ^Server, peer: headless.Endpoint) {
	_, known := game.find(&s.match, peer)
	player, joined := game.join(&s.match, peer)
	if !joined {
		send(s, peer, game.Reject{reason = .Match_Full})
		return
	}
	if !known {
		address: [32]byte
		log("Tick %d: Player %d joined from %s", s.match.tick, player + 1, headless.endpoint_string(peer, address[:]))
	}
	send(s, peer, game.Accept{player = player})
}

leave :: proc(s: ^Server, player: u8) {
	game.leave(&s.match, player)
	log("Tick %d: Player %d left", s.match.tick, player + 1)
	tell_everyone(s, game.Player_Left{player = player})
}

send :: proc(s: ^Server, to: headless.Endpoint, message: game.Message) {
	s.sequence += 1
	encoded := game.encode({sequence = s.sequence, message = message})
	headless.send(s.transport, to, game.encoded_bytes(&encoded))
}

tell_everyone :: proc(s: ^Server, message: game.Message) {
	for index in s.match.present {
		send(s, s.match.players[index].peer, message)
	}
}

report :: proc(s: ^Server) {
	log("Tick %d: %d Players, %d datagrams received, %d malformed, %d ignored, %d dropped by the transport",
		s.match.tick, game.player_count(&s.match), s.received, s.malformed, s.ignored, headless.dropped_count(s.transport))
}

main :: proc() {
	port, ok := parse_port(os.args[1:])
	if !ok {
		log(USAGE)
		os.exit(2)
	}
	transport, err := headless.open(port)
	if err != nil {
		log("r-type_server: cannot listen on UDP port %d: %v", port, err)
		os.exit(1)
	}
	server := Server{transport = transport}
	log("r-type_server: listening on UDP port %d, %d Ticks per second", transport.port, game.TICK_RATE)

	ticks := headless.fixed_step(time.Second / game.TICK_RATE)
	for {
		// Not `for _ in 0 ..< headless.wait(&ticks)`: Odin evaluates a
		// range's upper bound again before every iteration.
		due := headless.wait(&ticks)
		for _ in 0 ..< due {
			tick(&server)
		}
	}
}
