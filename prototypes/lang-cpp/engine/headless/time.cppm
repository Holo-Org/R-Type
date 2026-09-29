// Fixed-step timing on the steady clock: the step rate does not depend on
// CPU speed, frame rate or wall-clock adjustments.
export module engine.time;

import std;

export namespace engine {

class FixedStep {
public:
    using Clock = std::chrono::steady_clock;

    // `max_catch_up` bounds how many overdue steps one call reports; beyond
    // that (a debugger pause, a suspended laptop) the backlog is dropped
    // instead of being replayed all at once.
    explicit FixedStep(Clock::duration step, int max_catch_up = 5)
        : step_{step}, next_{Clock::now() + step}, max_catch_up_{max_catch_up} {}

    // Number of steps that fell due since the last call. Never blocks.
    int poll() {
        const auto now = Clock::now();
        int due = 0;
        while (next_ <= now && due < max_catch_up_) {
            next_ += step_;
            ++due;
        }
        if (next_ <= now) {
            next_ = now + step_;
        }
        return due;
    }

    // Sleeps until at least one step is due, then returns how many are.
    int wait() {
        std::this_thread::sleep_until(next_);
        return poll();
    }

private:
    Clock::duration step_;
    Clock::time_point next_;
    int max_catch_up_;
};

} // namespace engine
