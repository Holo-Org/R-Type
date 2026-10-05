#+build darwin, linux
// What the fuzz test watches on macOS and Linux, beyond the context: the C
// library's allocation functions, and crashes.
//
// Allocations: this file defines counting versions of `malloc`, `calloc`,
// `realloc`, `posix_memalign`, `aligned_alloc` and `mmap`, which forward each
// call to the C library. Odin refuses a second procedure linked as `malloc`
// (the core library declares the C one), so they are exported as
// `counting_malloc` and so on, and scripts/build.sh asks the linker to make
// them this program's `malloc` and so on (`-alias` on macOS, `--defsym` on
// Linux). Only the program's own calls are counted: the C library's internal
// calls stay bound to its own functions.
package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:sys/posix"

COUNTING_C :: true

// Calls to the C library's allocation functions made by this thread. Read and
// written as volatile: the optimiser knows `malloc` by name and assumes that
// it changes no memory of ours, so it would otherwise fold a count taken
// before a `malloc` and one taken after into the same value.
@(thread_local)
c_allocations: int

count_c_allocation :: proc "contextless" () {
	intrinsics.volatile_store(&c_allocations, intrinsics.volatile_load(&c_allocations) + 1)
}

c_allocation_count :: proc "contextless" () -> int {
	return intrinsics.volatile_load(&c_allocations)
}

// The C library's own definitions, found past this program's.
RTLD_NEXT :: posix.Symbol_Table(~uintptr(0)) // (void *)-1

C_Functions :: struct {
	malloc:         proc "c" (size: uint) -> rawptr,
	calloc:         proc "c" (count, size: uint) -> rawptr,
	realloc:        proc "c" (block: rawptr, size: uint) -> rawptr,
	posix_memalign: proc "c" (block: ^rawptr, alignment, size: uint) -> i32,
	aligned_alloc:  proc "c" (alignment, size: uint) -> rawptr,
	mmap:           proc "c" (address: rawptr, len: uint, protection, flags, fd: i32, offset: i64) -> rawptr,
}

c_functions: C_Functions

next :: proc "c" (field: ^$T, name: cstring) -> T {
	if field^ == nil {
		field^ = auto_cast posix.dlsym(RTLD_NEXT, name)
	}
	return field^
}

@(export, link_name = "counting_malloc")
counting_malloc :: proc "c" (size: uint) -> rawptr {
	count_c_allocation()
	return next(&c_functions.malloc, "malloc")(size)
}

@(export, link_name = "counting_calloc")
counting_calloc :: proc "c" (count, size: uint) -> rawptr {
	count_c_allocation()
	return next(&c_functions.calloc, "calloc")(count, size)
}

@(export, link_name = "counting_realloc")
counting_realloc :: proc "c" (block: rawptr, size: uint) -> rawptr {
	count_c_allocation()
	return next(&c_functions.realloc, "realloc")(block, size)
}

@(export, link_name = "counting_posix_memalign")
counting_posix_memalign :: proc "c" (block: ^rawptr, alignment, size: uint) -> i32 {
	count_c_allocation()
	return next(&c_functions.posix_memalign, "posix_memalign")(block, alignment, size)
}

@(export, link_name = "counting_aligned_alloc")
counting_aligned_alloc :: proc "c" (alignment, size: uint) -> rawptr {
	count_c_allocation()
	return next(&c_functions.aligned_alloc, "aligned_alloc")(alignment, size)
}

@(export, link_name = "counting_mmap")
counting_mmap :: proc "c" (address: rawptr, len: uint, protection, flags, fd: i32, offset: i64) -> rawptr {
	count_c_allocation()
	return next(&c_functions.mmap, "mmap")(address, len, protection, flags, fd, offset)
}

// Kept in a global, so that the optimiser cannot drop the allocations below.
kept: [2]rawptr

// Fails unless the counter sees the runtime's heap and virtual memory, which
// it does only once the linker has made the counting functions the program's.
check_the_c_library_counter :: proc() -> bool {
	before := c_allocation_count()
	kept[0] = runtime.heap_alloc(64) // calloc
	kept[1] = runtime.heap_alloc(64, zero_memory = false) // malloc
	runtime.heap_free(kept[0])
	runtime.heap_free(kept[1])
	if c_allocation_count() - before != 2 {
		fmt.eprintln("protocol_fuzz: the C library counter missed an allocation; were the linker aliases given?")
		return false
	}
	before = c_allocation_count()
	pages, err := virtual.reserve(1 << 16)
	if err != nil || c_allocation_count() - before != 1 {
		fmt.eprintln("protocol_fuzz: the C library counter missed a mapping; were the linker aliases given?")
		return false
	}
	virtual.release(raw_data(pages), len(pages))
	return true
}

// ---- Crashes ----------------------------------------------------------------

// The length of the datagram being decoded, -1 otherwise. Written as
// volatile: the optimiser does not know that the signal handler reads it.
decoding_length := -1

watch_decoding :: proc "contextless" (length: int) {
	intrinsics.volatile_store(&decoding_length, length)
}

// Prints the datagram being decoded, in hexadecimal, with write(2) only, then
// restores the default action, which ends the process when the faulting
// instruction runs again. (SA_RESETHAND should do that, but macOS 26 drops
// it for SIGTRAP, from C as from Odin, and the handler then runs forever.)
report_crash :: proc "c" (signal: posix.Signal) {
	default_action := posix.sigaction_t {
		sa_handler = auto_cast posix.SIG_DFL,
	}
	posix.sigaction(signal, &default_action, nil)
	length := intrinsics.volatile_load(&decoding_length)
	if length < 0 {
		return
	}
	digits := "0123456789abcdef"
	header := "protocol_fuzz: decode() crashed on this datagram:\n"
	posix.write(2, raw_data(header), len(header))
	line: [64]byte
	for start := 0; start < length; start += 16 {
		n := 0
		for i in start ..< min(start + 16, length) {
			line[n] = digits[datagram.buffer[i] >> 4]
			line[n + 1] = digits[datagram.buffer[i] & 15]
			line[n + 2] = ' '
			n += 3
		}
		line[n] = '\n'
		posix.write(2, raw_data(line[:]), uint(n + 1))
	}
}

install_crash_report :: proc() {
	action := posix.sigaction_t {
		sa_handler = report_crash,
	}
	for signal in ([?]posix.Signal{.SIGTRAP, .SIGILL, .SIGSEGV, .SIGBUS}) {
		posix.sigaction(signal, &action, nil)
	}
}
