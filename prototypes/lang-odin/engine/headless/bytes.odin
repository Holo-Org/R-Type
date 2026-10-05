// The Engine's headless part: byte encoding, the UDP transport, the fixed-step
// clock and a seedable random generator. It imports the core library only.
//
// This file: little-endian encoding, so that the wire format never depends on
// the host's byte order.
//
// A wire value is a `#packed` struct whose fields are one byte wide (`u8`,
// `enum u8`, `bit_set[...; u8]`) or explicitly little-endian (`u16le`,
// `u32le`), or arrays of such. Its bytes in memory are then its bytes on the
// wire, on any host: `write` and `read` copy them, and the type declaration is
// the layout. The compiler checks that the struct has no padding; a unit test
// (`game/protocol_test.odin`) checks the rest of the rule on the Game's types.
//
// Every read is checked here, in code, so the checks hold in every build,
// `-no-bounds-check` included.
package headless

import "base:intrinsics"

// Writes into a caller-provided buffer. A write that does not fit is dropped
// and marks the writer as failed: check `ok` once, after the last write.
Byte_Writer :: struct {
	buffer:  []byte,
	written: int,
	ok:      bool,
}

writer :: proc(buffer: []byte) -> Byte_Writer {
	return Byte_Writer{buffer = buffer, ok = true}
}

// Writes the bytes of a wire value (see the top of this file).
write :: proc(w: ^Byte_Writer, value: $T) where intrinsics.type_is_struct(T), !intrinsics.type_struct_has_implicit_padding(T) {
	value := value
	write_bytes(w, ([^]byte)(&value)[:size_of(T)])
}

write_u8 :: proc(w: ^Byte_Writer, value: u8) {
	value := value
	write_bytes(w, ([^]byte)(&value)[:1])
}

write_u16 :: proc(w: ^Byte_Writer, value: u16) {
	value := u16le(value)
	write_bytes(w, ([^]byte)(&value)[:2])
}

write_u32 :: proc(w: ^Byte_Writer, value: u32) {
	value := u32le(value)
	write_bytes(w, ([^]byte)(&value)[:4])
}

write_bytes :: proc(w: ^Byte_Writer, bytes: []byte) {
	if !w.ok || len(w.buffer) - w.written < len(bytes) {
		w.ok = false
		return
	}
	copy(w.buffer[w.written:], bytes)
	w.written += len(bytes)
}

// Reads from untrusted bytes. A read past the end fails and consumes nothing.
Byte_Reader :: struct {
	bytes: []byte,
}

reader :: proc(bytes: []byte) -> Byte_Reader {
	return Byte_Reader{bytes = bytes}
}

// Bytes not read yet.
remaining :: proc(r: Byte_Reader) -> int {
	return len(r.bytes)
}

// Reads a wire value (see the top of this file), only if all of its bytes
// are there. The caller checks the values it holds.
@(require_results)
read :: proc(r: ^Byte_Reader, $T: typeid) -> (value: T, ok: bool) where intrinsics.type_is_struct(T), !intrinsics.type_struct_has_implicit_padding(T) {
	if len(r.bytes) < size_of(T) {
		return
	}
	value = intrinsics.unaligned_load((^T)(raw_data(r.bytes)))
	r.bytes = r.bytes[size_of(T):]
	return value, true
}

@(require_results)
read_u8 :: proc(r: ^Byte_Reader) -> (value: u8, ok: bool) {
	if len(r.bytes) < 1 {
		return
	}
	value = r.bytes[0]
	r.bytes = r.bytes[1:]
	return value, true
}

@(require_results)
read_u16 :: proc(r: ^Byte_Reader) -> (value: u16, ok: bool) {
	if len(r.bytes) < 2 {
		return
	}
	value = u16(intrinsics.unaligned_load((^u16le)(raw_data(r.bytes))))
	r.bytes = r.bytes[2:]
	return value, true
}

@(require_results)
read_u32 :: proc(r: ^Byte_Reader) -> (value: u32, ok: bool) {
	if len(r.bytes) < 4 {
		return
	}
	value = u32(intrinsics.unaligned_load((^u32le)(raw_data(r.bytes))))
	r.bytes = r.bytes[4:]
	return value, true
}
