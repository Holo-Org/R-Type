//! Sounds generated in code: no audio files ship with the game.

const std = @import("std");

pub const sample_rate = 44_100;

/// A short "pew": a square wave sweeping from 1400 Hz down to 300 Hz in
/// 0.18 s, fading out, as 16-bit mono samples.
pub const Pew = [@trunc(0.18 * sample_rate)]i16;

pub fn synthesizePew() Pew {
    const start_hz = 1400.0;
    const end_hz = 300.0;
    const volume = 0.3;

    var samples: Pew = undefined;
    var phase: f64 = 0;
    for (&samples, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / samples.len;
        const frequency = start_hz * std.math.pow(f64, end_hz / start_hz, t);
        phase = @mod(phase + frequency / sample_rate, 1.0);
        const square: f64 = if (phase < 0.5) 1 else -1;
        const envelope = (1 - t) * (1 - t);
        sample.* = @trunc(square * envelope * volume * 32767);
    }
    return samples;
}
