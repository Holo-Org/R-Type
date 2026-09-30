//! Fixed-step timing on the monotonic clock: the step rate does not depend on
//! CPU speed, frame rate or wall-clock adjustments.

const std = @import("std");
const Io = std.Io;

pub const FixedStep = struct {
    io: Io,
    step: Io.Duration,
    next: Io.Timestamp,
    max_catch_up: u32,

    /// The monotonic clock: `CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on Linux.
    const clock: Io.Clock = .awake;

    /// Steps of `step`, catching up on at most 5 overdue steps at a time.
    pub fn init(io: Io, step: Io.Duration) FixedStep {
        return .initCatchUp(io, step, 5);
    }

    /// `max_catch_up` bounds how many overdue steps one call reports; beyond
    /// that (a debugger pause, a suspended laptop) the backlog is dropped
    /// instead of being replayed all at once.
    pub fn initCatchUp(io: Io, step: Io.Duration, max_catch_up: u32) FixedStep {
        return .{
            .io = io,
            .step = step,
            .next = clock.now(io).addDuration(step),
            .max_catch_up = max_catch_up,
        };
    }

    /// Number of steps that fell due since the last call. Never blocks.
    pub fn poll(s: *FixedStep) u32 {
        const now = clock.now(s.io);
        var due: u32 = 0;
        while (s.next.nanoseconds <= now.nanoseconds and due < s.max_catch_up) {
            s.next = s.next.addDuration(s.step);
            due += 1;
        }
        if (s.next.nanoseconds <= now.nanoseconds) s.next = now.addDuration(s.step);
        return due;
    }

    /// Sleeps until at least one step is due, then returns how many are.
    pub fn wait(s: *FixedStep) Io.Cancelable!u32 {
        try s.next.withClock(clock).wait(s.io);
        return s.poll();
    }
};

test "no step is due at once, and waiting yields one" {
    const io = std.testing.io;
    var steps: FixedStep = .init(io, .fromMilliseconds(5));
    try std.testing.expectEqual(0, steps.poll());
    try std.testing.expect(try steps.wait() >= 1);
}

test "a long pause is replayed as at most max_catch_up steps" {
    const io = std.testing.io;
    var steps: FixedStep = .initCatchUp(io, .fromMilliseconds(50), 3);
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expectEqual(3, steps.poll());
    try std.testing.expectEqual(0, steps.poll()); // the rest of the backlog was dropped
}
