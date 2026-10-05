#+test
package game

import "base:runtime"
import "core:slice"
import "core:testing"

// The bytes of a packet with sequence 0x01020304: the header, then `body`.
@(private = "file")
with_header :: proc(kind: u8, body: []byte, buffer: ^[64]byte) -> []byte {
	header := [8]byte{'R', 'T', 1, kind, 0x04, 0x03, 0x02, 0x01}
	copy(buffer[:], header[:])
	copy(buffer[8:], body)
	return buffer[:8 + len(body)]
}

@(private = "file")
expect_bytes :: proc(t: ^testing.T, expected: []byte, message: Message, loc := #caller_location) {
	encoded := encode({sequence = 0x01020304, message = message})
	got := encoded_bytes(&encoded)
	testing.expectf(t, slice.equal(got, expected), "%v encodes as % x, not % x", message, got, expected, loc = loc)
}

@(test)
the_layout_matches_the_wire_format :: proc(t: ^testing.T) {
	buffer: [64]byte
	// The example in the POC's report: an accept for Player 2, sequence 0x01020304.
	expect_bytes(t, {0x52, 0x54, 0x01, 0x02, 0x04, 0x03, 0x02, 0x01, 0x02}, Accept{player = 2})
	expect_bytes(t, with_header(1, {}, &buffer), Connect{})
	expect_bytes(t, with_header(3, {1}, &buffer), Reject{reason = .Match_Full})
	input := Input {
		recent = {
			{tick = 0x0A0B0C0D, buttons = {.Up, .Fire}},
			{tick = 7, buttons = {}},
			{tick = 6, buttons = {.Right}},
		},
	}
	expect_bytes(t, with_header(4, {0x0D, 0x0C, 0x0B, 0x0A, 0x11, 7, 0, 0, 0, 0, 6, 0, 0, 0, 8}, &buffer), input)
	snapshot := Snapshot{tick = 9}
	append(&snapshot.ships, Ship_State{player = 1, x = 0x0102, y = 0x0304})
	append(&snapshot.ships, Ship_State{player = 3, x = 5, y = 6})
	expect_bytes(t, with_header(5, {9, 0, 0, 0, 2, 1, 0x02, 0x01, 0x04, 0x03, 3, 5, 0, 6, 0}, &buffer), snapshot)
	expect_bytes(t, with_header(6, {}, &buffer), Disconnect{})
	expect_bytes(t, with_header(7, {3}, &buffer), Player_Left{player = 3})
}

@(test)
decodes_what_it_encodes :: proc(t: ^testing.T) {
	snapshot := Snapshot{tick = max(u32)}
	append(&snapshot.ships, Ship_State{})
	messages := [?]Message{Connect{}, Accept{player = 3}, Reject{reason = .Match_Full}, Input{}, snapshot, Disconnect{}, Player_Left{player = 0}}
	for message in messages {
		encoded := encode({sequence = 42, message = message})
		packet, err := decode(encoded_bytes(&encoded))
		testing.expect_value(t, err, Decode_Error.None)
		testing.expect_value(t, packet.sequence, 42)
		again := encode(packet)
		testing.expect(t, slice.equal(encoded_bytes(&again), encoded_bytes(&encoded)))
	}
}

@(test)
rejects_malformed_datagrams :: proc(t: ^testing.T) {
	error_of :: proc(bytes: []byte) -> Decode_Error {
		_, err := decode(bytes)
		return err
	}
	buffer: [64]byte
	too_long: [MAX_DATAGRAM_SIZE + 1]byte
	testing.expect_value(t, error_of(too_long[:]), Decode_Error.Too_Long)
	testing.expect_value(t, error_of({}), Decode_Error.Truncated)
	testing.expect_value(t, error_of(with_header(1, {}, &buffer)[:7]), Decode_Error.Truncated)
	testing.expect_value(t, error_of({'R', 'X', 1, 1, 0, 0, 0, 0}), Decode_Error.Bad_Protocol)
	testing.expect_value(t, error_of({'R', 'T', 2, 1, 0, 0, 0, 0}), Decode_Error.Bad_Version)
	testing.expect_value(t, error_of(with_header(0, {}, &buffer)), Decode_Error.Unknown_Type)
	testing.expect_value(t, error_of(with_header(8, {}, &buffer)), Decode_Error.Unknown_Type)
	testing.expect_value(t, error_of(with_header(2, {}, &buffer)), Decode_Error.Truncated)
	testing.expect_value(t, error_of(with_header(2, {4}, &buffer)), Decode_Error.Bad_Value)
	testing.expect_value(t, error_of(with_header(3, {2}, &buffer)), Decode_Error.Bad_Value)
	testing.expect_value(t, error_of(with_header(1, {0}, &buffer)), Decode_Error.Trailing_Bytes)
	// Input: unknown button bits, ticks out of order, and truncation first.
	unknown_button := [15]byte{4 = 0x20}
	testing.expect_value(t, error_of(with_header(4, unknown_button[:], &buffer)), Decode_Error.Bad_Value)
	testing.expect_value(t, error_of(with_header(4, unknown_button[:14], &buffer)), Decode_Error.Truncated)
	out_of_order := [15]byte{5 = 1}
	testing.expect_value(t, error_of(with_header(4, out_of_order[:], &buffer)), Decode_Error.Bad_Value)
	// Snapshot: too many Ships, a Player out of range, a Player twice.
	testing.expect_value(t, error_of(with_header(5, {0, 0, 0, 0, 5}, &buffer)), Decode_Error.Bad_Value)
	testing.expect_value(t, error_of(with_header(5, {0, 0, 0, 0, 1, 4, 0, 0, 0, 0}, &buffer)), Decode_Error.Bad_Value)
	twice := [15]byte{0, 0, 0, 0, 2, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0}
	testing.expect_value(t, error_of(with_header(5, twice[:], &buffer)), Decode_Error.Bad_Value)
	testing.expect_value(t, error_of(with_header(5, twice[:12], &buffer)), Decode_Error.Truncated)
}

// The compiler checks that a wire value has no padding; this checks the rest
// of the rule in engine/headless/bytes.odin: packed, and every field one byte
// wide or explicitly little-endian.
@(private = "file")
wire_safe :: proc(info: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Integer:
		return info.size == 1 || v.endianness == .Little
	case runtime.Type_Info_Enum:
		return wire_safe(v.base)
	case runtime.Type_Info_Bit_Set:
		return info.size == 1
	case runtime.Type_Info_Array:
		return wire_safe(v.elem)
	case runtime.Type_Info_Struct:
		if v.field_count > 0 && .packed not_in v.flags {
			return false
		}
		for i in 0 ..< v.field_count {
			if !wire_safe(v.types[i]) {
				return false
			}
		}
		return true
	}
	return false
}

@(test)
wire_values_are_packed_and_little_endian :: proc(t: ^testing.T) {
	wire_types := [?]typeid{Header, Connect, Accept, Reject, Input_State, Input, Snapshot_Head, Ship_State, Disconnect, Player_Left}
	for type in wire_types {
		testing.expectf(t, wire_safe(type_info_of(type)), "%v is not a wire value", type)
	}
	// And the check itself is not blind.
	Platform_Endian :: struct #packed {
		tick: u32,
	}
	Padded :: struct {
		player: u8,
		tick:   u32le,
	}
	testing.expect(t, !wire_safe(type_info_of(Platform_Endian)))
	testing.expect(t, !wire_safe(type_info_of(Padded)))
}
