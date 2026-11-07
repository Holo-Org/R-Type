//! Sounds generated in code: no audio files ship with the game. Each one
//! goes with something the screen also shows, so that none is the only way
//! to learn of anything: a Projectile leaving a Ship, an explosion, the
//! game-over screen.

const std = @import("std");

pub const sample_rate = 44_100;

/// 16-bit mono samples, lasting `seconds`.
fn Samples(comptime seconds: f64) type {
    return [@trunc(seconds * sample_rate)]i16;
}

/// A short "pew", when the Player's Ship fires: a square wave sweeping from
/// 1400 Hz down to 300 Hz in 0.18 s, fading out.
pub const Pew = Samples(0.18);

pub fn synthesizePew() Pew {
    var samples: Pew = undefined;
    sweep(&samples, 1400, 300, 0.3);
    return samples;
}

/// An Enemy exploding: 0.35 s of noise, darkening and fading out.
pub const Explosion = Samples(0.35);

pub fn synthesizeExplosion() Explosion {
    var samples: Explosion = undefined;
    noise(&samples, 0.45, 2026);
    return samples;
}

/// A Ship destroyed: longer and deeper than an Enemy's explosion, so that
/// the two are told apart by ear.
pub const ShipDestroyed = Samples(0.8);

pub fn synthesizeShipDestroyed() ShipDestroyed {
    var samples: ShipDestroyed = undefined;
    noise(&samples, 0.9, 1987);
    return samples;
}

/// Game over: three falling notes.
pub const GameOver = Samples(0.9);

pub fn synthesizeGameOver() GameOver {
    var samples: GameOver = undefined;
    const third = samples.len / 3;
    sweep(samples[0..third], 523, 494, 0.25);
    sweep(samples[third .. 2 * third], 392, 370, 0.25);
    sweep(samples[2 * third ..], 262, 220, 0.25);
    return samples;
}

/// A square wave from `start_hz` to `end_hz`, fading out.
fn sweep(samples: []i16, start_hz: f64, end_hz: f64, volume: f64) void {
    var phase: f64 = 0;
    for (samples, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples.len));
        const frequency = start_hz * std.math.pow(f64, end_hz / start_hz, t);
        phase = @mod(phase + frequency / sample_rate, 1.0);
        const square: f64 = if (phase < 0.5) 1 else -1;
        const envelope = (1 - t) * (1 - t);
        sample.* = @trunc(square * envelope * volume * 32767);
    }
}

/// White noise through a low-pass filter that closes as it fades: `depth`,
/// from 0 to 1, keeps more of the low end.
fn noise(samples: []i16, depth: f64, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var low: f64 = 0;
    for (samples, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples.len));
        const white = random.float(f64) * 2 - 1;
        const cutoff = (1 - depth) * (1 - t) + 0.02;
        low += cutoff * (white - low);
        const envelope = (1 - t) * (1 - t) * (1 - t);
        sample.* = @trunc(std.math.clamp(low * 3 * envelope, -1, 1) * 0.5 * 32767);
    }
}

test "every sound fades to silence, and none clips" {
    inline for (.{ synthesizePew(), synthesizeExplosion(), synthesizeShipDestroyed(), synthesizeGameOver() }) |samples| {
        var loudest: i32 = 0;
        for (samples) |sample| loudest = @max(loudest, @abs(@as(i32, sample)));
        try std.testing.expect(loudest > 1000 and loudest < 32767);
        try std.testing.expect(@abs(@as(i32, samples[samples.len - 1])) < 200);
    }
}
