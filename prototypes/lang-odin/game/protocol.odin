// The Game: R-Type's messages and rules, on top of the Engine's headless part.
//
// This file: the messages exchanged by the Server and the Clients, and their
// wire format.
//
// Every datagram is one packet: an 8-byte header, then the message body.
// All integers are little-endian.
//
//     header       u16 protocol id ("RT"), u8 version, u8 message type, u32 sequence
//     connect      (empty)                                          Client -> Server
//     accept       u8 Player index                                  Server -> Client
//     reject       u8 reason                                        Server -> Client
//     input        3 x (u32 Client Tick, u8 buttons), newest first  Client -> Server
//     snapshot     u32 Server Tick, u8 Ship count (0-4),
//                  count x (u8 Player index, u16 x, u16 y)          Server -> Client
//     disconnect   (empty)                                          Client -> Server
//     player_left  u8 Player index                                  Server -> Client
//
// The sequence counts the datagrams sent by each peer; receivers use it to
// ignore datagrams that arrive out of order.
//
// The message bodies below are wire values (see engine/headless/bytes.odin):
// `#packed` structs of one-byte and little-endian fields, so their
// declarations are the layout, and the Engine's `write` and `read` copy them
// whole. Only their value checks are written by hand, and the snapshot, whose
// length varies, spells out its own encoding.
package game

import "../engine/headless"

PROTOCOL_ID :: u16('R') | u16('T') << 8
PROTOCOL_VERSION :: 1
MAX_DATAGRAM_SIZE :: headless.MAX_DATAGRAM_SIZE
MAX_PLAYERS :: 4
INPUT_HISTORY :: 3

// The message type byte of each message.
Message_Type :: enum u8 {
	Connect = 1,
	Accept,
	Reject,
	Input,
	Snapshot,
	Disconnect,
	Player_Left,
}

// The buttons a Player holds, one bit each, `Up` in the lowest bit. A byte
// holds three more bits, which name no button: the decoder rejects them.
Button :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	Fire,
}
Buttons :: bit_set[Button; u8]
ALL_BUTTONS :: Buttons{.Up, .Down, .Left, .Right, .Fire}

// The buttons a Player held during one Client Tick.
Input_State :: struct #packed {
	tick:    u32le,
	buttons: Buttons,
}

// The last INPUT_HISTORY input states, newest first, so that one lost
// datagram loses no input.
Input :: struct #packed {
	recent: [INPUT_HISTORY]Input_State,
}

Connect :: struct {}

Accept :: struct #packed {
	player: u8, // the Player index in the Match, from 0
}

Reject_Reason :: enum u8 {
	Match_Full = 1,
}

Reject :: struct #packed {
	reason: Reject_Reason,
}

Ship_State :: struct #packed {
	player: u8,
	x:      u16le,
	y:      u16le,
}

// Where the Ships are at one Server Tick. The fixed-capacity array holds at
// most MAX_PLAYERS Ships, and appending to it never allocates.
Snapshot :: struct {
	tick:  u32,
	ships: [dynamic; MAX_PLAYERS]Ship_State,
}

Disconnect :: struct {}

Player_Left :: struct #packed {
	player: u8,
}

Message :: union #no_nil {
	Connect,
	Accept,
	Reject,
	Input,
	Snapshot,
	Disconnect,
	Player_Left,
}

Packet :: struct {
	sequence: u32,
	message:  Message,
}

// Why a datagram is not a packet, in the order the fuzz test tallies them.
Decode_Error :: enum u8 {
	None,
	Too_Long,
	Truncated,
	Bad_Protocol,
	Bad_Version,
	Unknown_Type,
	Bad_Value,
	Trailing_Bytes,
}

describe :: proc(err: Decode_Error) -> string {
	switch err {
	case .None:           return "none"
	case .Too_Long:       return "too long"
	case .Truncated:      return "truncated"
	case .Bad_Protocol:   return "bad protocol id"
	case .Bad_Version:    return "bad version"
	case .Unknown_Type:   return "unknown message type"
	case .Bad_Value:      return "value out of range"
	case .Trailing_Bytes: return "trailing bytes"
	}
	return "unknown error"
}

Header :: struct #packed {
	protocol_id: u16le,
	version:     u8,
	kind:        u8,
	sequence:    u32le,
}

// The fixed-size head of a snapshot; its Ships follow.
Snapshot_Head :: struct #packed {
	tick:       u32le,
	ship_count: u8,
}

// An encoded packet, held in place: encoding never allocates.
Encoded :: struct {
	buffer: [MAX_DATAGRAM_SIZE]byte,
	len:    int,
}

encoded_bytes :: proc(encoded: ^Encoded) -> []byte {
	return encoded.buffer[:encoded.len]
}

encode :: proc(packet: Packet) -> (encoded: Encoded) {
	out := headless.writer(encoded.buffer[:])
	sequence := packet.sequence
	switch body in packet.message {
	case Connect:     write_packet(&out, .Connect, sequence, body)
	case Accept:      write_packet(&out, .Accept, sequence, body)
	case Reject:      write_packet(&out, .Reject, sequence, body)
	case Input:       write_packet(&out, .Input, sequence, body)
	case Disconnect:  write_packet(&out, .Disconnect, sequence, body)
	case Player_Left: write_packet(&out, .Player_Left, sequence, body)
	case Snapshot:
		ships := body.ships
		write_packet(&out, .Snapshot, sequence, Snapshot_Head{tick = u32le(body.tick), ship_count = u8(len(ships))})
		for ship in ships {
			headless.write(&out, ship)
		}
	}
	// The largest message is a few dozen bytes, so this is a programming error.
	assert(out.ok, "packet does not fit in a datagram")
	encoded.len = out.written
	return
}

@(private)
write_packet :: proc(out: ^headless.Byte_Writer, kind: Message_Type, sequence: u32, body: $T) {
	headless.write(out, Header{protocol_id = u16le(PROTOCOL_ID), version = PROTOCOL_VERSION, kind = u8(kind), sequence = u32le(sequence)})
	headless.write(out, body)
}

// Decodes one datagram. Takes no allocator, and rejects anything but exactly
// one well-formed packet. The checks run in the same order as in the C++,
// Rust and Zig decoders, so that all four tally rejected datagrams alike: a
// fixed-size body is read whole before its values are judged, so a short one
// is Truncated even when it also holds a bad value.
decode :: proc(datagram: []byte) -> (packet: Packet, err: Decode_Error) {
	if len(datagram) > MAX_DATAGRAM_SIZE {
		return {}, .Too_Long
	}
	input := headless.reader(datagram)
	header := read(&input, Header) or_return
	if u16(header.protocol_id) != PROTOCOL_ID {
		return {}, .Bad_Protocol
	}
	if header.version != PROTOCOL_VERSION {
		return {}, .Bad_Version
	}
	if header.kind < u8(min(Message_Type)) || header.kind > u8(max(Message_Type)) {
		return {}, .Unknown_Type
	}
	switch Message_Type(header.kind) {
	case .Connect:     packet.message = Connect{}
	case .Accept:      packet.message = read_valid(&input, Accept) or_return
	case .Reject:      packet.message = read_valid(&input, Reject) or_return
	case .Input:       packet.message = read_valid(&input, Input) or_return
	case .Snapshot:    packet.message = read_snapshot(&input) or_return
	case .Disconnect:  packet.message = Disconnect{}
	case .Player_Left: packet.message = read_valid(&input, Player_Left) or_return
	}
	if headless.remaining(input) != 0 {
		return {}, .Trailing_Bytes
	}
	packet.sequence = u32(header.sequence)
	return packet, .None
}

// The Engine's reader says only whether the bytes were there; `or_return`
// needs the Game's error type.
@(private)
read :: proc(input: ^headless.Byte_Reader, $T: typeid) -> (value: T, err: Decode_Error) {
	ok: bool
	value, ok = headless.read(input, T)
	return value, .None if ok else .Truncated
}

@(private)
read_valid :: proc(input: ^headless.Byte_Reader, $T: typeid) -> (value: T, err: Decode_Error) {
	value = read(input, T) or_return
	return value, .None if valid(value) else .Bad_Value
}

@(private)
valid :: proc{valid_accept, valid_reject, valid_input, valid_player_left}

@(private)
valid_accept :: proc(accept: Accept) -> bool {
	return accept.player < MAX_PLAYERS
}

@(private)
valid_player_left :: proc(left: Player_Left) -> bool {
	return left.player < MAX_PLAYERS
}

@(private)
valid_reject :: proc(reject: Reject) -> bool {
	return reject.reason == .Match_Full
}

@(private)
valid_input :: proc(input: Input) -> bool {
	for state, i in input.recent {
		if state.buttons - ALL_BUTTONS != {} {
			return false // a bit that names no button
		}
		if i > 0 && input.recent[i - 1].tick < state.tick {
			return false // not newest first
		}
	}
	return true
}

// Reads the Ships one at a time: like the other decoders, a bad Ship is
// rejected before the next one is read.
@(private)
read_snapshot :: proc(input: ^headless.Byte_Reader) -> (snapshot: Snapshot, err: Decode_Error) {
	head := read(input, Snapshot_Head) or_return
	// Checked before use: an attacker-chosen count never sizes or indexes anything.
	if head.ship_count > MAX_PLAYERS {
		return {}, .Bad_Value
	}
	snapshot.tick = u32(head.tick)
	seen: bit_set[0 ..< MAX_PLAYERS]
	for _ in 0 ..< head.ship_count {
		ship := read(input, Ship_State) or_return
		if ship.player >= MAX_PLAYERS || int(ship.player) in seen {
			return {}, .Bad_Value // no such Player, or one twice
		}
		seen += {int(ship.player)}
		append(&snapshot.ships, ship)
	}
	return snapshot, .None
}
