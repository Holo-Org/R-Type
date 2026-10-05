// A small seedable pseudo-random generator, for procedural content and tests;
// not for anything secret. `core:math/rand` offers xoshiro256 and PCG, but
// this is the Rust POC's generator, so that the fuzz tests draw the same
// datagrams and the Star-fields place the same stars.
package headless

// SplitMix64 (Steele, Lea and Flood, 2014): the same seed always gives the
// same sequence.
Random :: struct {
	state: u64,
}

random_u64 :: proc(r: ^Random) -> u64 {
	// Odin's unsigned arithmetic wraps, as SplitMix64 needs.
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

random_u32 :: proc(r: ^Random) -> u32 {
	return u32(random_u64(r) >> 32) // the high half: the better-mixed bits
}

// A number in 0..<bound, or 0 when bound is 0.
random_below :: proc(r: ^Random, bound: u32) -> u32 {
	n := random_u32(r)
	return 0 if bound == 0 else n % bound
}

// A number in [0, 1).
random_unit :: proc(r: ^Random) -> f32 {
	// 24 random bits: exactly what an f32 mantissa holds.
	return f32(random_u32(r) >> 8) / f32(1 << 24)
}
