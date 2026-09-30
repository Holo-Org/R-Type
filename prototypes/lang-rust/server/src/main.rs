//! r-type_server: runs one Match for up to four Players.
//! Players are numbered from 1 in logs; the protocol counts from 0.
//!
//! Two threads: the Engine's network thread receives datagrams into the
//! transport's inbox, and the main thread runs the 60 Hz Tick loop, which
//! drains the inbox, advances the Match and sends every Player a snapshot.
//! Logs go to stderr, which Rust never buffers, so they show up at once even
//! when redirected.

use std::io;
use std::process::ExitCode;
use std::time::Duration;

use engine_headless::net::{Datagram, Endpoint, UdpTransport};
use engine_headless::time::FixedStep;
use game::protocol::{self, Message, Packet, RejectReason};
use game::rules::{Match, TICK_RATE};

const USAGE: &str = "usage: r-type_server [--port <port>]";

fn parse_port(args: &[String]) -> Option<u16> {
    match args {
        [] => Some(4242),
        [flag, port] if flag == "--port" => port.parse().ok(),
        _ => None,
    }
}

/// The socket, and the sequence number of the last datagram sent through it.
///
/// A separate struct so that the Server can borrow it mutably while it reads
/// the Match: the borrow checker allows two borrows of distinct fields.
struct Network {
    transport: UdpTransport,
    sequence: u32,
}

impl Network {
    fn send(&mut self, to: Endpoint, message: Message) {
        self.sequence = self.sequence.wrapping_add(1);
        let packet = Packet {
            sequence: self.sequence,
            message,
        };
        let encoded = protocol::encode(&packet);
        self.transport.send(to, encoded.as_bytes());
    }
}

struct Server {
    network: Network,
    match_: Match,
    received: usize,
    malformed: usize,
    ignored: usize,
}

impl Server {
    fn bind(port: u16) -> io::Result<Self> {
        Ok(Self {
            network: Network {
                transport: UdpTransport::bind(port)?,
                sequence: 0,
            },
            match_: Match::new(),
            received: 0,
            malformed: 0,
            ignored: 0,
        })
    }

    fn tick(&mut self) {
        for datagram in self.network.transport.receive() {
            self.handle(&datagram);
        }
        for player in self.match_.step() {
            let tick = self.match_.tick();
            eprintln!("Tick {tick}: Player {} timed out", player + 1);
            self.tell_everyone(Message::PlayerLeft { player });
        }
        self.tell_everyone(Message::Snapshot(self.match_.snapshot()));
        if self.match_.tick().is_multiple_of(5 * TICK_RATE) {
            self.report();
        }
    }

    fn handle(&mut self, datagram: &Datagram) {
        self.received += 1;
        let Ok(packet) = protocol::decode(&datagram.bytes) else {
            self.malformed += 1;
            return;
        };
        let player = self.match_.find(datagram.from);
        match (packet.message, player) {
            (Message::Connect, _) => self.connect(datagram.from),
            (Message::Input(input), Some(player)) => self.match_.receive(player, &input),
            (Message::Disconnect, Some(player)) => self.leave(player),
            // Input or disconnect from a stranger, or a message only the Server sends.
            _ => self.ignored += 1,
        }
    }

    fn connect(&mut self, peer: Endpoint) {
        let known = self.match_.find(peer).is_some();
        let Some(player) = self.match_.join(peer) else {
            let reason = RejectReason::MatchFull;
            self.network.send(peer, Message::Reject { reason });
            return;
        };
        if !known {
            let tick = self.match_.tick();
            eprintln!("Tick {tick}: Player {} joined from {peer}", player + 1);
        }
        self.network.send(peer, Message::Accept { player });
    }

    fn leave(&mut self, player: u8) {
        self.match_.leave(player);
        eprintln!("Tick {}: Player {} left", self.match_.tick(), player + 1);
        self.tell_everyone(Message::PlayerLeft { player });
    }

    fn tell_everyone(&mut self, message: Message) {
        // Reads self.match_ while writing self.network: two different fields.
        for player in self.match_.players() {
            self.network.send(player.peer, message);
        }
    }

    fn report(&self) {
        eprintln!(
            "Tick {}: {} Players, {} datagrams received, {} malformed, {} ignored, {} dropped by the transport",
            self.match_.tick(),
            self.match_.players().count(),
            self.received,
            self.malformed,
            self.ignored,
            self.network.transport.dropped(),
        );
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(port) = parse_port(&args) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let mut server = match Server::bind(port) {
        Ok(server) => server,
        Err(error) => {
            eprintln!("r-type_server: cannot listen on UDP port {port}: {error}");
            return ExitCode::FAILURE;
        }
    };
    let port = server.network.transport.local_port().unwrap_or(port);
    eprintln!("r-type_server: listening on UDP port {port}, {TICK_RATE} Ticks per second");
    let mut ticks = FixedStep::new(Duration::from_secs(1) / TICK_RATE);
    loop {
        for _ in 0..ticks.wait() {
            server.tick();
        }
    }
}
