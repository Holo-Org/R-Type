// Sounds generated in code: no audio files ship with the game.
export module client.sound;

import std;

export namespace client {

inline constexpr int sample_rate = 44'100;

// A short "pew": a square wave sweeping from 1400 Hz down to 300 Hz in
// 0.18 s, fading out, as 16-bit mono samples.
std::vector<std::int16_t> synthesize_pew() {
    constexpr double duration = 0.18;
    constexpr double start_hz = 1400;
    constexpr double end_hz = 300;
    constexpr double volume = 0.3;

    std::vector<std::int16_t> samples(static_cast<std::size_t>(duration * sample_rate));
    double phase = 0;
    for (std::size_t i = 0; i < samples.size(); ++i) {
        const double t = static_cast<double>(i) / static_cast<double>(samples.size());
        const double frequency = start_hz * std::pow(end_hz / start_hz, t);
        phase = std::fmod(phase + frequency / sample_rate, 1.0);
        const double square = phase < 0.5 ? 1.0 : -1.0;
        const double envelope = (1 - t) * (1 - t);
        samples[i] = static_cast<std::int16_t>(square * envelope * volume * 32767);
    }
    return samples;
}

} // namespace client
