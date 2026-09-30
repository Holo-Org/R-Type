//! A small seedable pseudo-random generator, for procedural content and tests;
//! not for anything secret. The standard library has none, and this saves
//! depending on the `rand` crate for a Star-field and a fuzz test.

use std::collections::hash_map::RandomState;
use std::hash::BuildHasher;

/// SplitMix64 (Steele, Lea and Flood, 2014): the same seed always gives the
/// same sequence.
#[derive(Clone, Debug)]
pub struct Random {
    state: u64,
}

impl Random {
    pub const fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// A seed that differs from run to run. std keeps a random key for hash
    /// maps; hashing nothing with it is a dependency-free way to read one.
    pub fn fresh_seed() -> u64 {
        RandomState::new().hash_one(())
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    pub fn next_u32(&mut self) -> u32 {
        // The high half: the better-mixed bits.
        (self.next_u64() >> 32) as u32
    }

    /// A number in `0..bound`, or 0 when `bound` is 0.
    pub fn below(&mut self, bound: u32) -> u32 {
        self.next_u32().checked_rem(bound).unwrap_or(0)
    }

    /// A number in `[0, 1)`.
    pub fn unit(&mut self) -> f32 {
        // 24 random bits: exactly what an f32 mantissa holds.
        (self.next_u32() >> 8) as f32 / (1u32 << 24) as f32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_sequence() {
        let mut a = Random::new(42);
        let mut b = Random::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn matches_the_reference_splitmix64() {
        // First two outputs of https://prng.di.unimi.it/splitmix64.c for seed 0.
        let mut random = Random::new(0);
        assert_eq!(random.next_u64(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(random.next_u64(), 0x6E78_9E6A_A1B9_65F4);
    }

    #[test]
    fn stays_in_range() {
        let mut random = Random::new(7);
        for _ in 0..10_000 {
            assert!(random.below(3) < 3);
            let unit = random.unit();
            assert!((0.0..1.0).contains(&unit));
        }
        assert_eq!(random.below(0), 0);
    }
}
