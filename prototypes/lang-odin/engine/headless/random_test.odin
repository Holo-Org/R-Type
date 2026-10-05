#+test
package headless

import "core:testing"

@(test)
matches_the_reference_splitmix64 :: proc(t: ^testing.T) {
	// The first two outputs of https://prng.di.unimi.it/splitmix64.c for seed 0.
	random := Random{state = 0}
	testing.expect_value(t, random_u64(&random), 0xE220_A839_7B1D_CDAF)
	testing.expect_value(t, random_u64(&random), 0x6E78_9E6A_A1B9_65F4)
}

@(test)
stays_in_range :: proc(t: ^testing.T) {
	random := Random{state = 7}
	for _ in 0 ..< 10_000 {
		testing.expect(t, random_below(&random, 3) < 3)
		unit := random_unit(&random)
		testing.expect(t, unit >= 0 && unit < 1)
	}
	testing.expect_value(t, random_below(&random, 0), 0)
}
