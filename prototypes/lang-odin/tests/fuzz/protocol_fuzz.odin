// protocol_fuzz: throws random and mutated datagrams at the protocol decoder,
// which must never crash, never allocate, and reject anything but well-formed
// packets.
//
// usage: protocol_fuzz [datagrams [seed]]
//
// The datagrams are the Rust POC's, draw for draw: the same generator
// (SplitMix64, taking the high 32 bits, bounded by remainder) and the same
// order of draws, so for the same seed the tallies compare directly.
//
// Crashes: a failed bounds check prints its location and stops the program
// with a trap. On macOS and Linux, a signal handler (watch_posix.odin) prints
// the datagram being decoded first. A completed run means that nothing failed.
//
// Allocations, counted two ways while `decode` runs:
// - Odin passes an allocator in the implicit `context`. Both of its
//   allocators are replaced by a counting one, so any allocation through
//   `context.allocator` or `context.temp_allocator` is counted.
// - Code can also bypass the context: `runtime.heap_alloc`, `core:c/libc`'s
//   `malloc`, `core:mem/virtual`. On macOS and Linux, all of them end up in
//   the C library's `malloc` family or `mmap`, which watch_posix.odin counts.
// A self-check proves that both counters see allocations before fuzzing.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"

import "../../engine/headless"
import "../../game"

// ---- Allocations through the context --------------------------------------

Counting_Allocator :: struct {
	backing: runtime.Allocator,
	count:   int,
}

counting_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	counter := (^Counting_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		counter.count += 1
	}
	return counter.backing.procedure(counter.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

counting_allocator :: proc(counter: ^Counting_Allocator) -> runtime.Allocator {
	return runtime.Allocator{procedure = counting_allocator_proc, data = counter}
}

// Fails unless the counters see allocations: a counter that sees nothing
// would always read 0.
check_the_counters :: proc() -> (ok: bool) {
	counter := Counting_Allocator{backing = context.allocator}
	{
		context.allocator = counting_allocator(&counter)
		block := new(int)
		free(block)
	}
	if counter.count != 1 {
		fmt.eprintln("protocol_fuzz: the context counter missed an allocation")
		return false
	}
	return check_the_c_library_counter()
}

// ---- The Rust POC's generator ------------------------------------------------

random_player :: proc(r: ^headless.Random) -> u8 {
	return u8(headless.random_below(r, game.MAX_PLAYERS))
}

shuffle :: proc(items: []u8, r: ^headless.Random) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := headless.random_below(r, u32(i + 1))
		items[i], items[j] = items[j], items[i]
	}
}

random_message :: proc(r: ^headless.Random) -> game.Message {
	switch headless.random_below(r, 7) {
	case 0:
		return game.Connect{}
	case 1:
		return game.Accept{player = random_player(r)}
	case 2:
		return game.Reject{reason = .Match_Full}
	case 3:
		input: game.Input
		tick := headless.random_u32(r)
		for &state in input.recent {
			bits := u8(headless.random_u32(r))
			state = {tick = u32le(tick), buttons = transmute(game.Buttons)(bits & 0b1_1111)}
			tick -= min(tick, headless.random_below(r, 3))
		}
		return input
	case 4:
		snapshot := game.Snapshot{tick = headless.random_u32(r)}
		count := headless.random_below(r, game.MAX_PLAYERS + 1)
		players := [game.MAX_PLAYERS]u8{0, 1, 2, 3}
		shuffle(players[:], r)
		for player in players[:count] {
			x := u16(headless.random_u32(r))
			y := u16(headless.random_u32(r))
			append(&snapshot.ships, game.Ship_State{player = player, x = u16le(x), y = u16le(y)})
		}
		return snapshot
	case 5:
		return game.Disconnect{}
	case:
		return game.Player_Left{player = random_player(r)}
	}
}

random_packet :: proc(r: ^headless.Random) -> game.Packet {
	sequence := headless.random_u32(r)
	return game.Packet{sequence = sequence, message = random_message(r)}
}

// Odin's `==` does not compare unions that hold a fixed-capacity array.
packets_equal :: proc(a, b: game.Packet) -> bool {
	if a.sequence != b.sequence {
		return false
	}
	switch x in a.message {
	case game.Connect:
		_, same := b.message.(game.Connect)
		return same
	case game.Accept:
		y, same := b.message.(game.Accept)
		return same && x == y
	case game.Reject:
		y, same := b.message.(game.Reject)
		return same && x == y
	case game.Input:
		y, same := b.message.(game.Input)
		return same && x == y
	case game.Disconnect:
		_, same := b.message.(game.Disconnect)
		return same
	case game.Player_Left:
		y, same := b.message.(game.Player_Left)
		return same && x == y
	case game.Snapshot:
		y, same := b.message.(game.Snapshot)
		if !same || x.tick != y.tick || len(x.ships) != len(y.ships) {
			return false
		}
		for ship, i in x.ships {
			if ship != y.ships[i] {
				return false
			}
		}
		return true
	}
	return false
}

// A datagram under construction: at most 1500 bytes of noise, or a small
// packet plus a few appended bytes.
Datagram :: struct {
	buffer: [1600]byte,
	len:    int,
}

push :: proc(d: ^Datagram, value: u8) {
	d.buffer[d.len] = value
	d.len += 1
}

// One to three mutations: flip a bit, overwrite a byte, truncate, or append.
// Where the Rust test indexes a byte and draws the new value in one
// assignment, Rust draws the value first; so does this code.
mutate :: proc(d: ^Datagram, r: ^headless.Random) {
	mutations := 1 + headless.random_below(r, 3)
	for _ in 0 ..< mutations {
		length := u32(d.len)
		switch headless.random_below(r, 4) {
		case 0:
			if length > 0 {
				bit := headless.random_below(r, 8)
				d.buffer[headless.random_below(r, length)] ~= u8(1) << bit
			}
		case 1:
			if length > 0 {
				value := u8(headless.random_u32(r))
				d.buffer[headless.random_below(r, length)] = value
			}
		case 2:
			d.len = int(headless.random_below(r, length + 1))
		case:
			appended := 1 + headless.random_below(r, 8)
			for _ in 0 ..< appended {
				push(d, u8(headless.random_u32(r)))
			}
		}
	}
}

// ---- The test ----------------------------------------------------------------

// The datagram under construction, then being decoded: global, for the crash
// report.
datagram: Datagram

parse_args :: proc(args: []string) -> (count: u64, seed: u64, seeded: bool, ok: bool) {
	if len(args) > 2 {
		return
	}
	count = 100_000
	if len(args) > 0 {
		count = strconv.parse_u64_of_base(args[0], 10) or_return
	}
	if len(args) > 1 {
		seed = strconv.parse_u64_of_base(args[1], 10) or_return
		seeded = true
	}
	return count, seed, seeded, true
}

main :: proc() {
	count, seed, seeded, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: protocol_fuzz [datagrams [seed]]")
		os.exit(2)
	}
	if !seeded {
		_ = runtime.random_generator_read_ptr(context.random_generator, &seed, size_of(seed))
	}
	if !check_the_counters() {
		os.exit(1)
	}
	install_crash_report()

	random := headless.Random{state = seed}
	fmt.printfln("protocol_fuzz: seed %d", seed)

	// Whatever encode() writes, decode() must read back unchanged.
	ROUND_TRIPS :: 10_000
	mismatches := 0
	for _ in 0 ..< ROUND_TRIPS {
		packet := random_packet(&random)
		encoded := game.encode(packet)
		decoded, err := game.decode(game.encoded_bytes(&encoded))
		if err != .None || !packets_equal(decoded, packet) {
			mismatches += 1
		}
	}
	fmt.printfln("round trip: %d packets, %d mismatches", ROUND_TRIPS, mismatches)

	// Half pure noise of any length up to 1500 bytes, half mutated valid packets.
	rejected: [game.Decode_Error]int
	accepted := 0
	c_library_allocations := 0
	counter := Counting_Allocator{backing = context.allocator}
	for i in 0 ..< count {
		datagram.len = 0
		if i % 2 == 0 {
			length := headless.random_below(&random, 1501)
			for _ in 0 ..< length {
				push(&datagram, u8(headless.random_u32(&random)))
			}
		} else {
			encoded := game.encode(random_packet(&random))
			copy(datagram.buffer[:], game.encoded_bytes(&encoded))
			datagram.len = encoded.len
			mutate(&datagram, &random)
		}

		err: game.Decode_Error
		{
			context.allocator = counting_allocator(&counter)
			context.temp_allocator = counting_allocator(&counter)
			before := c_allocation_count()
			watch_decoding(datagram.len)
			_, err = game.decode(datagram.buffer[:datagram.len])
			watch_decoding(-1)
			c_library_allocations += c_allocation_count() - before
		}
		if err == .None {
			accepted += 1
		} else {
			rejected[err] += 1
		}
	}

	total_rejected := 0
	for times in rejected {
		total_rejected += times
	}
	fmt.printfln("fuzz: %d datagrams, %d rejected, %d accepted, 0 panics, %d allocations in decode()",
		count, total_rejected, accepted, counter.count + c_library_allocations)
	for err in game.Decode_Error {
		if err != .None {
			// `%7d` would pad with zeros: core:fmt pads integers with spaces
			// only under the space flag.
			fmt.printfln("  % 7d %s", rejected[err], game.describe(err))
		}
	}
	when COUNTING_C {
		fmt.printfln("allocations in decode(): %d through the context, %d from the C library", counter.count, c_library_allocations)
	} else {
		fmt.printfln("allocations in decode(): %d through the context; the C library is not watched on this system", counter.count)
	}
	os.exit(0 if mismatches == 0 && counter.count + c_library_allocations == 0 else 1)
}
