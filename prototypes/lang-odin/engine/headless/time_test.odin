#+test
package headless

import "core:testing"
import "core:time"

@(test)
no_step_is_due_at_once_and_waiting_yields_one :: proc(t: ^testing.T) {
	steps := fixed_step(5 * time.Millisecond)
	testing.expect_value(t, poll(&steps), 0)
	testing.expect(t, wait(&steps) >= 1)
}

@(test)
a_long_pause_is_replayed_as_at_most_max_catch_up_steps :: proc(t: ^testing.T) {
	steps := fixed_step(50 * time.Millisecond, max_catch_up = 3)
	time.sleep(300 * time.Millisecond)
	testing.expect_value(t, poll(&steps), 3)
	testing.expect_value(t, poll(&steps), 0) // the rest of the backlog was dropped
}
