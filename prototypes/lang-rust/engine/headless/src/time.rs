//! Fixed-step timing on the monotonic clock: the step rate does not depend on
//! CPU speed, frame rate or wall-clock adjustments.

use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct FixedStep {
    step: Duration,
    next: Instant,
    max_catch_up: u32,
}

impl FixedStep {
    /// Steps of `step`, catching up on at most 5 overdue steps at a time.
    pub fn new(step: Duration) -> Self {
        Self::with_max_catch_up(step, 5)
    }

    /// `max_catch_up` bounds how many overdue steps one call reports; beyond
    /// that (a debugger pause, a suspended laptop) the backlog is dropped
    /// instead of being replayed all at once.
    pub fn with_max_catch_up(step: Duration, max_catch_up: u32) -> Self {
        Self {
            step,
            next: Instant::now() + step,
            max_catch_up,
        }
    }

    /// Number of steps that fell due since the last call. Never blocks.
    pub fn poll(&mut self) -> u32 {
        let now = Instant::now();
        let mut due = 0;
        while self.next <= now && due < self.max_catch_up {
            self.next += self.step;
            due += 1;
        }
        if self.next <= now {
            self.next = now + self.step;
        }
        due
    }

    /// Sleeps until at least one step is due, then returns how many are.
    pub fn wait(&mut self) -> u32 {
        thread::sleep(self.next.saturating_duration_since(Instant::now()));
        self.poll()
    }
}
