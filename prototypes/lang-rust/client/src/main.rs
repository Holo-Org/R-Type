//! r-type_client: shows the Match and sends the Player's inputs every Tick.
//! Players are numbered from 1 on screen and in logs; the protocol counts from 0.
//!
//! The Engine's network thread receives the Server's datagrams; the main
//! thread drains them every Frame, sends one input per Tick whatever the frame
//! rate, and draws the newest snapshot.

mod sound;
mod sprites;
mod starfield;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use engine_client::{AudioDevice, Color, Frame, Key, Window};
use engine_headless::net::{self, Endpoint, UdpTransport};
use engine_headless::time::FixedStep;
use game::protocol::{self, Buttons, Input, InputState, MAX_PLAYERS, Message, Packet, Snapshot};
use game::rules::{TICK_RATE, WORLD_HEIGHT, WORLD_WIDTH};

use sprites::{PLAYER_COLORS, ShipSprites};
use starfield::Starfield;

const USAGE: &str = "usage: r-type_client [--host <host>] [--port <port>] [--script <n>] [--frames <n> [--screenshot <file.png>]]";

#[derive(Debug)]
struct Options {
    host: String,
    port: u16,
    /// Play unattended, following pattern N.
    script: Option<u32>,
    /// Quit after N Frames.
    frames: Option<u32>,
    /// Save the last Frame there.
    screenshot: Option<PathBuf>,
}

fn parse_options(args: &[String]) -> Option<Options> {
    let mut options = Options {
        host: "127.0.0.1".into(),
        port: 4242,
        script: None,
        frames: None,
        screenshot: None,
    };
    // Pairs of arguments, as arrays, and whatever is left over.
    let (pairs, dangling) = args.as_chunks::<2>();
    for [name, value] in pairs {
        match name.as_str() {
            "--host" => options.host = value.clone(),
            "--port" => options.port = value.parse().ok()?,
            "--script" => options.script = Some(value.parse().ok()?),
            "--frames" => options.frames = Some(value.parse().ok().filter(|&n| n > 0)?),
            "--screenshot" => options.screenshot = Some(value.into()),
            _ => return None,
        }
    }
    if !dangling.is_empty() || (options.screenshot.is_some() && options.frames.is_none()) {
        return None;
    }
    Some(options)
}

fn keyboard_buttons(window: &Window) -> Buttons {
    let bindings = [
        (Key::Up, Buttons::UP),
        (Key::Down, Buttons::DOWN),
        (Key::Left, Buttons::LEFT),
        (Key::Right, Buttons::RIGHT),
        (Key::Space, Buttons::FIRE),
    ];
    let mut buttons = Buttons::NONE;
    for (key, button) in bindings {
        if window.is_key_down(key) {
            buttons |= button;
        }
    }
    buttons
}

/// Unattended play: every pattern flies a square, starting on a different
/// side, and fires every two seconds.
fn scripted_buttons(pattern: u32, tick: u32) -> Buttons {
    const LEGS: [Buttons; 4] = [Buttons::RIGHT, Buttons::DOWN, Buttons::LEFT, Buttons::UP];
    const LEG_TICKS: u32 = 45;
    let leg = (tick / LEG_TICKS).wrapping_add(pattern) % 4;
    let mut buttons = LEGS[leg as usize];
    if tick.is_multiple_of(2 * TICK_RATE) {
        buttons |= Buttons::FIRE;
    }
    buttons
}

fn draw_hud(frame: &mut Frame, me: Option<u8>, snapshot: &Snapshot, server: Endpoint) {
    match me {
        Some(me) => {
            let color = PLAYER_COLORS.get(usize::from(me)).copied();
            let color = color.unwrap_or(Color::WHITE);
            frame.draw_text(&format!("Player {}", me + 1), 16, 12, 20, color);
        }
        None => {
            let text = format!("Connecting to {server}...");
            frame.draw_text(&text, 16, 12, 20, Color::WHITE);
        }
    }
    let players = format!("{}/{MAX_PLAYERS} Players", snapshot.ships().len());
    frame.draw_text(&players, WORLD_WIDTH - 150, 12, 20, Color::WHITE);
}

/// The Client's end of the conversation with the Server: numbers the
/// datagrams it sends, and drops the ones that arrive out of order.
struct ServerLink {
    transport: UdpTransport,
    server: Endpoint,
    sequence: u32,
    server_sequence: u32,
}

impl ServerLink {
    fn send(&mut self, message: Message) {
        self.sequence = self.sequence.wrapping_add(1);
        let packet = Packet {
            sequence: self.sequence,
            message,
        };
        self.transport
            .send(self.server, protocol::encode(&packet).as_bytes());
    }

    /// The Server's messages received since the last call, oldest first.
    fn receive(&mut self) -> Vec<Message> {
        let mut messages = Vec::new();
        for datagram in self.transport.receive() {
            if datagram.from != self.server {
                continue;
            }
            let Ok(packet) = protocol::decode(&datagram.bytes) else {
                continue; // malformed
            };
            if packet.sequence <= self.server_sequence {
                continue; // overtaken by a newer datagram
            }
            self.server_sequence = packet.sequence;
            messages.push(packet.message);
        }
        messages
    }
}

fn run(options: &Options) -> Result<(), String> {
    let server = net::resolve(&options.host, options.port)
        .ok_or_else(|| format!("cannot resolve {}", options.host))?;
    let transport =
        UdpTransport::bind(0).map_err(|error| format!("cannot open a UDP socket: {error}"))?;
    let mut link = ServerLink {
        transport,
        server,
        sequence: 0,
        server_sequence: 0,
    };

    // Declared in this order, dropped in the reverse one: the sound before
    // the audio device (the compiler insists), the textures before the window.
    let mut window = Window::open(WORLD_WIDTH, WORLD_HEIGHT, "R-Type", 60);
    let audio = AudioDevice::open()
        .inspect_err(|error| eprintln!("r-type_client: {error}; playing without sound"))
        .ok();
    let samples = sound::synthesize_pew();
    let pew = match &audio {
        Some(audio) => audio
            .load_sound(&samples, sound::SAMPLE_RATE)
            .inspect_err(|error| eprintln!("r-type_client: {error}"))
            .ok(),
        None => None,
    };
    let ships = ShipSprites::load(&mut window).map_err(|error| error.to_string())?;
    let mut starfield = Starfield::new(WORLD_WIDTH as f32, WORLD_HEIGHT as f32, 2026);

    let mut me: Option<u8> = None; // our Player index, once accepted
    let mut latest = Snapshot::default();
    let mut input = Input::default();
    let mut tick: u32 = 0;
    let mut ticks = FixedStep::new(Duration::from_secs(1) / TICK_RATE);
    eprintln!("r-type_client: connecting to {server}");

    let mut frame_count: u32 = 0;
    while !window.should_close() {
        frame_count += 1;
        for message in link.receive() {
            match message {
                Message::Accept { player } => {
                    if me != Some(player) {
                        eprintln!("Joined the Match as Player {}", player + 1);
                    }
                    me = Some(player);
                }
                Message::Reject { .. } => return Err("the Match is full".into()),
                Message::Snapshot(snapshot) => latest = snapshot,
                Message::PlayerLeft { player } => {
                    eprintln!("Player {} left the Match", player + 1);
                    if me == Some(player) {
                        me = None; // dropped by the Server: connect again
                    }
                }
                // Messages only Clients send.
                Message::Connect | Message::Input(_) | Message::Disconnect => {}
            }
        }

        for _ in 0..ticks.poll() {
            tick = tick.wrapping_add(1);
            let buttons = match options.script {
                Some(pattern) => scripted_buttons(pattern, tick),
                None => keyboard_buttons(&window),
            };
            let previous = input.recent[0].buttons;
            input.recent.rotate_right(1);
            input.recent[0] = InputState { tick, buttons };
            let fire_pressed = buttons.contains(Buttons::FIRE) && !previous.contains(Buttons::FIRE);
            if fire_pressed && let Some(pew) = &pew {
                pew.play();
            }
            if me.is_some() {
                link.send(Message::Input(input));
            } else if tick % (TICK_RATE / 2) == 1 {
                link.send(Message::Connect); // twice a second, until the Server answers
            }
        }

        starfield.scroll(window.frame_time());
        let last_frame = options.frames.is_some_and(|frames| frame_count >= frames);
        let mut frame = window.begin_frame(Color::BLACK);
        starfield.draw(&mut frame);
        for ship in latest.ships() {
            ships.draw(&mut frame, ship);
        }
        draw_hud(&mut frame, me, &latest, server);
        if last_frame && let Some(path) = &options.screenshot {
            match frame.save_screenshot(path) {
                Ok(()) => eprintln!("r-type_client: saved {}", path.display()),
                Err(error) => eprintln!("r-type_client: {error}"),
            }
        }
        drop(frame); // ends the Frame, which shows it
        if last_frame {
            break;
        }
    }

    if me.is_some() {
        link.send(Message::Disconnect);
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(options) = parse_options(&args) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    match run(&options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("r-type_client: {error}");
            ExitCode::FAILURE
        }
    }
}
