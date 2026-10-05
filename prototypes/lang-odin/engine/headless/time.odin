// Fixed-step timing on the monotonic clock: the step rate does not depend on
// CPU speed, frame rate or wall-clock adjustments.
package headless

import "core:time"

// `time.tick_now` reads CLOCK_MONOTONIC_RAW on macOS, CLOCK_MONOTONIC_RAW on
// Linux, and QueryPerformanceCounter on Windows.
Fixed_Step :: struct {
	step:         time.Duration,
	next:         time.Tick,
	max_catch_up: int,
}

// Steps of `step`. `max_catch_up` bounds how many overdue steps one call
// reports; beyond that (a debugger pause, a suspended laptop) the backlog is
// dropped instead of being replayed all at once.
fixed_step :: proc(step: time.Duration, max_catch_up := 5) -> Fixed_Step {
	return Fixed_Step{step = step, next = time.tick_add(time.tick_now(), step), max_catch_up = max_catch_up}
}

// Number of steps that fell due since the last call. Never blocks.
poll :: proc(s: ^Fixed_Step) -> int {
	now := time.tick_now()
	due := 0
	for time.tick_diff(s.next, now) >= 0 && due < s.max_catch_up {
		s.next = time.tick_add(s.next, s.step)
		due += 1
	}
	if time.tick_diff(s.next, now) >= 0 {
		s.next = time.tick_add(now, s.step)
	}
	return due
}

// Sleeps until at least one step is due, then returns how many are.
wait :: proc(s: ^Fixed_Step) -> int {
	if remaining := time.tick_diff(time.tick_now(), s.next); remaining > 0 {
		time.sleep(remaining)
	}
	return poll(s)
}
