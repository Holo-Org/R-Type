#+build !darwin
#+build !linux
// Elsewhere, such as on Windows, the fuzz test counts the allocations made
// through the context only, and a crash is reported without the datagram.
package main

COUNTING_C :: false

c_allocation_count :: proc "contextless" () -> int {
	return 0
}

check_the_c_library_counter :: proc() -> bool {
	return true
}

watch_decoding :: proc "contextless" (length: int) {}

install_crash_report :: proc() {}
