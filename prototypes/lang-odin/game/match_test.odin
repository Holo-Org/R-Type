#+test
package game

import "core:testing"

import "../engine/headless"

@(test)
four_players_join_and_a_fifth_is_refused :: proc(t: ^testing.T) {
	m: Match
	for port in 0 ..< 4 {
		player, ok := join(&m, headless.loopback(u16(port)))
		testing.expect(t, ok)
		testing.expect_value(t, player, u8(port))
	}
	again, _ := join(&m, headless.loopback(2))
	testing.expect_value(t, again, 2) // a repeated connect keeps its index
	_, fifth := join(&m, headless.loopback(9))
	testing.expect(t, !fifth)
	leave(&m, 1)
	reused, _ := join(&m, headless.loopback(9))
	testing.expect_value(t, reused, 1) // a free slot is reused
}

@(test)
ships_move_with_the_newest_input_and_stay_in_the_world :: proc(t: ^testing.T) {
	input_of :: proc(tick: u32le, buttons: Buttons) -> Input {
		state := Input_State{tick = tick, buttons = buttons}
		return Input{recent = {state, state, state}}
	}
	m: Match
	player, _ := join(&m, headless.loopback(1))
	receive(&m, player, input_of(2, {.Left, .Up}))
	receive(&m, player, input_of(1, {.Right})) // older: ignored
	for _ in 0 ..< 100 {
		step(&m)
	}
	s := snapshot(&m)
	testing.expect_value(t, len(s.ships), 1)
	testing.expect_value(t, s.ships[0].x, 0)
	testing.expect_value(t, s.ships[0].y, 0)
}

@(test)
a_silent_player_is_dropped_after_three_seconds :: proc(t: ^testing.T) {
	m: Match
	join(&m, headless.loopback(1))
	for _ in 0 ..< SILENCE_LIMIT {
		testing.expect_value(t, card(step(&m)), 0)
	}
	testing.expect_value(t, step(&m), Player_Set{0})
	testing.expect_value(t, player_count(&m), 0)
}
