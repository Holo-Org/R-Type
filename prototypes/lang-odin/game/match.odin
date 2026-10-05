// The rules of a Match: who plays, how Ships move, when a silent Player is
// dropped.
package game

import "../engine/headless"

WORLD_WIDTH :: 1280
WORLD_HEIGHT :: 720
// A 33x17 sprite drawn at twice its size.
SHIP_WIDTH :: 66
SHIP_HEIGHT :: 34
// Pixels per Tick.
SHIP_SPEED :: 6
// Ticks per second.
TICK_RATE :: 60
// Ticks a Player may stay silent before being dropped.
SILENCE_LIMIT :: 3 * TICK_RATE

// A Player of the Match, as the Server knows it.
Player :: struct {
	peer:       headless.Endpoint,
	// Server Tick of the Player's last packet.
	last_heard: u32,
	// Client Tick of the newest input applied.
	last_input: u32,
	buttons:    Buttons,
	x, y:       i32,
}

// Player indices, such as the ones a Tick dropped.
Player_Set :: bit_set[0 ..< MAX_PLAYERS; u8]

Match :: struct {
	players: [MAX_PLAYERS]Player,
	// Which entries of `players` are in the Match.
	present: Player_Set,
	tick:    u32,
}

// The Player index of `peer`, joining it if it is new; not ok if the Match is full.
join :: proc(m: ^Match, peer: headless.Endpoint) -> (player: u8, ok: bool) {
	if existing, found := find(m, peer); found {
		return existing, true // a repeated connect, after a lost accept
	}
	for index in 0 ..< MAX_PLAYERS {
		if index in m.present {
			continue
		}
		m.players[index] = Player{peer = peer, last_heard = m.tick, x = 64, y = 90 + 160 * i32(index)}
		m.present += {index}
		return u8(index), true
	}
	return 0, false
}

find :: proc(m: ^Match, peer: headless.Endpoint) -> (player: u8, ok: bool) {
	for index in m.present {
		if m.players[index].peer == peer {
			return u8(index), true
		}
	}
	return 0, false
}

leave :: proc(m: ^Match, player: u8) {
	if player < MAX_PLAYERS {
		m.present -= {int(player)}
	}
}

// Records the newest buttons held by a Player; also proves it is alive.
receive :: proc(m: ^Match, player: u8, input: Input) {
	if player >= MAX_PLAYERS || int(player) not_in m.present {
		return
	}
	state := &m.players[player]
	state.last_heard = m.tick
	// Datagrams can arrive out of order: never go back to older buttons.
	newest := input.recent[0]
	if u32(newest.tick) > state.last_input {
		state.last_input = u32(newest.tick)
		state.buttons = newest.buttons
	}
}

// Advances one Tick: moves every Ship, then drops and returns the Players who
// have been silent for longer than SILENCE_LIMIT.
step :: proc(m: ^Match) -> (dropped: Player_Set) {
	m.tick += 1 // wraps around, as Odin's unsigned arithmetic does
	for index in m.present {
		player := &m.players[index]
		if m.tick - player.last_heard > SILENCE_LIMIT {
			m.present -= {index}
			dropped += {index}
			continue
		}
		dx := axis(.Right in player.buttons, .Left in player.buttons)
		dy := axis(.Down in player.buttons, .Up in player.buttons)
		player.x = clamp(player.x + dx * SHIP_SPEED, 0, WORLD_WIDTH - SHIP_WIDTH)
		player.y = clamp(player.y + dy * SHIP_SPEED, 0, WORLD_HEIGHT - SHIP_HEIGHT)
	}
	return
}

@(private)
axis :: proc(positive, negative: bool) -> i32 {
	return (1 if positive else 0) - (1 if negative else 0)
}

snapshot :: proc(m: ^Match) -> (s: Snapshot) {
	s.tick = m.tick
	for index in m.present {
		player := m.players[index]
		// Clamped by step() to the world, which fits in a u16.
		append(&s.ships, Ship_State{player = u8(index), x = u16le(player.x), y = u16le(player.y)})
	}
	return
}

player_count :: proc(m: ^Match) -> int {
	return card(m.present)
}
