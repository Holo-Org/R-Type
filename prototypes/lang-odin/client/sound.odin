// Sounds generated in code: no audio files ship with the game.
package main

import "core:math"

SAMPLE_RATE :: 44_100

// A short "pew": a square wave sweeping from 1400 Hz down to 300 Hz in
// 0.18 s, fading out, as 16-bit mono samples.
PEW_SAMPLE_COUNT :: int(0.18 * SAMPLE_RATE)

synthesize_pew :: proc() -> (samples: [PEW_SAMPLE_COUNT]i16) {
	START_HZ :: 1400.0
	END_HZ :: 300.0
	VOLUME :: 0.3

	phase := 0.0
	for &sample, i in samples {
		t := f64(i) / f64(len(samples))
		frequency := START_HZ * math.pow(END_HZ / START_HZ, t)
		phase = math.mod(phase + frequency / SAMPLE_RATE, 1.0)
		square := 1.0 if phase < 0.5 else -1.0
		envelope := (1 - t) * (1 - t)
		sample = i16(square * envelope * VOLUME * 32767)
	}
	return
}
