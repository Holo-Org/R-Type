//! Sounds generated in code: no audio files ship with the game.

pub const SAMPLE_RATE: u32 = 44_100;

/// A short "pew": a square wave sweeping from 1400 Hz down to 300 Hz in
/// 0.18 s, fading out, as 16-bit mono samples.
pub fn synthesize_pew() -> Vec<i16> {
    const DURATION: f64 = 0.18;
    const START_HZ: f64 = 1400.0;
    const END_HZ: f64 = 300.0;
    const VOLUME: f64 = 0.3;

    let rate = f64::from(SAMPLE_RATE);
    let count = (DURATION * rate) as usize;
    let mut phase = 0.0;
    (0..count)
        .map(|i| {
            let t = i as f64 / count as f64;
            let frequency = START_HZ * (END_HZ / START_HZ).powf(t);
            phase = (phase + frequency / rate) % 1.0;
            let square = if phase < 0.5 { 1.0 } else { -1.0 };
            let envelope = (1.0 - t) * (1.0 - t);
            (square * envelope * VOLUME * 32767.0) as i16
        })
        .collect()
}
