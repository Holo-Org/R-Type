#+test
package headless

import "core:testing"

@(test)
integers_are_little_endian :: proc(t: ^testing.T) {
	buffer: [7]byte
	out := writer(buffer[:])
	write_u8(&out, 0x01)
	write_u16(&out, 0x0302)
	write_u32(&out, 0x07060504)
	testing.expect(t, out.ok)
	testing.expect_value(t, out.written, 7)
	testing.expect_value(t, buffer, [7]byte{1, 2, 3, 4, 5, 6, 7})

	input := reader(buffer[:])
	a, a_ok := read_u8(&input)
	b, b_ok := read_u16(&input)
	c, c_ok := read_u32(&input)
	testing.expect(t, a_ok && b_ok && c_ok)
	testing.expect_value(t, a, 0x01)
	testing.expect_value(t, b, 0x0302)
	testing.expect_value(t, c, 0x07060504)
	testing.expect_value(t, remaining(input), 0)
}

@(test)
overflowing_writes_and_reads_fail_without_panicking :: proc(t: ^testing.T) {
	buffer: [3]byte
	out := writer(buffer[:])
	write_u16(&out, 0xFFFF)
	write_u16(&out, 0xFFFF)
	testing.expect(t, !out.ok)
	testing.expect_value(t, out.written, 2)

	bytes := [3]byte{1, 2, 3}
	input := reader(bytes[:])
	_, ok := read_u32(&input)
	testing.expect(t, !ok)
	testing.expect_value(t, remaining(input), 3) // a failed read consumes nothing
	value, value_ok := read_u16(&input)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, 0x0201)
}

@(test)
wire_values_are_copied_whole :: proc(t: ^testing.T) {
	Kind :: enum u8 {
		One = 1,
		Two = 2,
	}
	Flag :: enum u8 {
		A,
		B,
	}
	Record :: struct #packed {
		kind:  Kind,
		flags: bit_set[Flag; u8],
		pair:  [2]u16le,
	}
	buffer: [6]byte
	out := writer(buffer[:])
	write(&out, Record{kind = .Two, flags = {.B}, pair = {0x0102, 3}})
	testing.expect_value(t, buffer, [6]byte{2, 0b10, 0x02, 0x01, 3, 0})

	input := reader(buffer[:])
	record, ok := read(&input, Record)
	testing.expect(t, ok)
	testing.expect_value(t, record.kind, Kind.Two)
	testing.expect_value(t, record.flags, bit_set[Flag; u8]{.B})
	testing.expect_value(t, record.pair[0], 0x0102)

	// One byte short: nothing is read.
	short := reader(buffer[:5])
	_, short_ok := read(&short, Record)
	testing.expect(t, !short_ok)
	testing.expect_value(t, remaining(short), 5)
}
