// r-type_client: shows the Match and sends the Player's inputs every Tick.
// Players are numbered from 1 on screen and in logs; the protocol counts from 0.
//
// The Engine's network thread receives the Server's datagrams; the main
// thread drains them every Frame, sends one input per Tick whatever the frame
// rate, and draws the newest snapshot.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import engine "../engine/client"
import "../engine/headless"
import "../game"

USAGE :: "usage: r-type_client [--host <host>] [--port <port>] [--script <n>] [--frames <n> [--screenshot <file.png>]]"

log :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
}

Options :: struct {
	host:       string,
	port:       u16,
	// Play unattended, following pattern N.
	script:     Maybe(u32),
	// Quit after N Frames.
	frames:     Maybe(u32),
	// Save the last Frame there.
	screenshot: Maybe(string),
}

// A decimal number up to `max_value`; digits only.
parse_number :: proc(text: string, max_value: u64) -> (value: u64, ok: bool) {
	if len(text) == 0 || len(text) > 10 {
		return // ten digits cannot overflow a u64
	}
	for c in text {
		if c < '0' || c > '9' {
			return
		}
	}
	value = strconv.parse_u64_of_base(text, 10) or_return
	return value, value <= max_value
}

parse_options :: proc(args: []string) -> (options: Options, ok: bool) {
	options = Options{host = "127.0.0.1", port = 4242}
	if len(args) % 2 != 0 {
		return // an option without its value
	}
	for i := 0; i < len(args); i += 2 {
		name, value := args[i], args[i + 1]
		switch name {
		case "--host":
			options.host = value
		case "--port":
			options.port = u16(parse_number(value, u64(max(u16))) or_return)
		case "--script":
			options.script = u32(parse_number(value, u64(max(u32))) or_return)
		case "--frames":
			frames := parse_number(value, u64(max(u32))) or_return
			if frames == 0 {
				return
			}
			options.frames = u32(frames)
		case "--screenshot":
			options.screenshot = value
		case:
			return
		}
	}
	if options.screenshot != nil && options.frames == nil {
		return
	}
	return options, true
}

keyboard_buttons :: proc(window: ^engine.Window) -> (buttons: game.Buttons) {
	bindings := [?]struct {
		key:    engine.Key,
		button: game.Button,
	}{{.Up, .Up}, {.Down, .Down}, {.Left, .Left}, {.Right, .Right}, {.Space, .Fire}}
	for binding in bindings {
		if engine.is_key_down(window, binding.key) {
			buttons += {binding.button}
		}
	}
	return
}

// Unattended play: every pattern flies a square, starting on a different
// side, and fires every two seconds.
scripted_buttons :: proc(pattern, tick: u32) -> game.Buttons {
	LEGS :: [4]game.Buttons{{.Right}, {.Down}, {.Left}, {.Up}}
	LEG_TICKS :: 45
	legs := LEGS
	buttons := legs[(tick / LEG_TICKS + pattern) % len(legs)]
	if tick % (2 * game.TICK_RATE) == 0 {
		buttons += {.Fire}
	}
	return buttons
}

draw_hud :: proc(frame: ^engine.Frame, me: Maybe(u8), snapshot: ^game.Snapshot, server: headless.Endpoint) {
	buffer: [64]byte
	if player, joined := me.?; joined {
		colors := PLAYER_COLORS
		engine.draw_text(frame, fmt.bprintf(buffer[:], "Player %d", player + 1), 16, 12, 20, colors[player])
	} else {
		address: [32]byte
		text := fmt.bprintf(buffer[:], "Connecting to %s...", headless.endpoint_string(server, address[:]))
		engine.draw_text(frame, text, 16, 12, 20, engine.WHITE)
	}
	players := fmt.bprintf(buffer[:], "%d/%d Players", len(snapshot.ships), game.MAX_PLAYERS)
	engine.draw_text(frame, players, game.WORLD_WIDTH - 150, 12, 20, engine.WHITE)
}

// The Client's end of the conversation with the Server: numbers the
// datagrams it sends, and drops the ones that arrive out of order.
Server_Link :: struct {
	transport:       ^headless.Udp_Transport,
	server:          headless.Endpoint,
	sequence:        u32,
	server_sequence: u32,
}

link_send :: proc(link: ^Server_Link, message: game.Message) {
	link.sequence += 1
	encoded := game.encode({sequence = link.sequence, message = message})
	headless.send(link.transport, link.server, game.encoded_bytes(&encoded))
}

// The next message from the Server, oldest first; not ok once none is left.
link_receive :: proc(link: ^Server_Link) -> (message: game.Message, ok: bool) {
	for {
		datagram := headless.receive(link.transport) or_return
		if datagram.from != link.server {
			continue
		}
		packet, err := game.decode(headless.datagram_bytes(&datagram))
		if err != .None {
			continue // malformed
		}
		if packet.sequence <= link.server_sequence {
			continue // overtaken by a newer datagram
		}
		link.server_sequence = packet.sequence
		return packet.message, true
	}
}

// Plays until the window closes or the Frames run out. On failure, returns
// what failed, for main to print.
run :: proc(options: Options) -> (failure: string) {
	server, resolved := headless.resolve(options.host, options.port)
	if !resolved {
		return fmt.tprintf("cannot resolve %s", options.host)
	}
	transport, open_err := headless.open(0)
	if open_err != nil {
		return fmt.tprintf("cannot open a UDP socket: %v", open_err)
	}
	defer headless.close(transport)
	link := Server_Link{transport = transport, server = server}

	// Released in the reverse order, by the defers: the sound before the
	// audio device, the textures before the window.
	window, window_err := engine.open_window(game.WORLD_WIDTH, game.WORLD_HEIGHT, "R-Type", 60)
	if window_err != .None {
		return fmt.tprintf("cannot open a window (%v)", window_err)
	}
	defer engine.close_window(&window)
	audio, audio_err := engine.open_audio()
	if audio_err != .None {
		log("r-type_client: cannot open the audio output (%v); playing without sound", audio_err)
	}
	defer if audio_err == .None {
		engine.close_audio(&audio)
	}
	samples := synthesize_pew()
	pew: Maybe(engine.Sound)
	if audio_err == .None {
		sound, sound_err := engine.load_sound(&audio, samples[:], SAMPLE_RATE)
		if sound_err != .None {
			log("r-type_client: cannot load the sound (%v)", sound_err)
		} else {
			pew = sound
		}
	}
	defer if sound, loaded := pew.?; loaded {
		engine.unload_sound(sound)
	}
	ships, sprites_err := load_ship_sprites(&window)
	if sprites_err != .None {
		return fmt.tprintf("cannot load the sprite sheet (%v)", sprites_err)
	}
	defer unload_ship_sprites(ships)
	starfield := make_starfield(game.WORLD_WIDTH, game.WORLD_HEIGHT, 2026)

	me: Maybe(u8) // our Player index, once accepted
	latest: game.Snapshot
	input: game.Input
	tick: u32
	ticks := headless.fixed_step(time.Second / game.TICK_RATE)
	address: [32]byte
	log("r-type_client: connecting to %s", headless.endpoint_string(server, address[:]))

	frame_count: u32
	for !engine.should_close(&window) {
		frame_count += 1
		for message in link_receive(&link) {
			switch m in message {
			case game.Accept:
				if me != m.player {
					log("Joined the Match as Player %d", m.player + 1)
				}
				me = m.player
			case game.Reject:
				return "the Match is full"
			case game.Snapshot:
				latest = m
			case game.Player_Left:
				log("Player %d left the Match", m.player + 1)
				if me == m.player {
					me = nil // dropped by the Server: connect again
				}
			// Messages only Clients send.
			case game.Connect, game.Input, game.Disconnect:
			}
		}

		// Not `for _ in 0 ..< headless.poll(&ticks)`: Odin evaluates a
		// range's upper bound again before every iteration.
		due := headless.poll(&ticks)
		for _ in 0 ..< due {
			tick += 1
			buttons: game.Buttons
			if pattern, scripted := options.script.?; scripted {
				buttons = scripted_buttons(pattern, tick)
			} else {
				buttons = keyboard_buttons(&window)
			}
			previous := input.recent
			input.recent = {{tick = u32le(tick), buttons = buttons}, previous[0], previous[1]}
			if .Fire in buttons && .Fire not_in previous[0].buttons {
				if sound, loaded := pew.?; loaded {
					engine.play_sound(sound)
				}
			}
			if me != nil {
				link_send(&link, input)
			} else if tick % (game.TICK_RATE / 2) == 1 {
				link_send(&link, game.Connect{}) // twice a second, until the Server answers
			}
		}

		scroll_starfield(&starfield, engine.frame_time(&window))
		frames, limited := options.frames.?
		last_frame := limited && frame_count >= frames
		frame := engine.begin_frame(&window, engine.BLACK)
		draw_starfield(&starfield, &frame)
		for ship in latest.ships {
			draw_ship(&ships, &frame, ship)
		}
		draw_hud(&frame, me, &latest, server)
		if path, wanted := options.screenshot.?; last_frame && wanted {
			if err := engine.save_screenshot(&frame, path); err == .None {
				log("r-type_client: saved %s", path)
			} else {
				log("r-type_client: cannot save %s (%v)", path, err)
			}
		}
		engine.end_frame(&frame)
		if last_frame {
			break
		}
	}

	if me != nil {
		link_send(&link, game.Disconnect{})
	}
	return ""
}

main :: proc() {
	options, ok := parse_options(os.args[1:])
	if !ok {
		log(USAGE)
		os.exit(2)
	}
	if failure := run(options); failure != "" {
		log("r-type_client: %s", failure)
		os.exit(1)
	}
}
