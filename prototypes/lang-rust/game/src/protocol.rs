//! The messages exchanged by the Server and the Clients, and their wire format.
//!
//! Every datagram is one packet: an 8-byte header, then the message body.
//! All integers are little-endian.
//!
//! ```text
//! header       u16 protocol id ("RT"), u8 version, u8 message type, u32 sequence
//! connect      (empty)                                          Client -> Server
//! accept       u8 Player index                                  Server -> Client
//! reject       u8 reason                                        Server -> Client
//! input        3 x (u32 Client Tick, u8 buttons), newest first  Client -> Server
//! snapshot     u32 Server Tick, u8 Ship count (0-4),
//!              count x (u8 Player index, u16 x, u16 y)          Server -> Client
//! disconnect   (empty)                                          Client -> Server
//! player_left  u8 Player index                                  Server -> Client
//! ```
//!
//! The sequence counts the datagrams sent by each peer; receivers use it to
//! ignore datagrams that arrive out of order.
//!
//! [`decode`] never panics and never allocates, whatever it is given: every
//! read is checked, and the lints below reject indexing, `unwrap` and
//! `expect`, the usual ways a Rust decoder panics on hostile input.
#![deny(
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic
)]

use std::fmt;
use std::ops::{BitOr, BitOrAssign};

use engine_headless::bytes::{ByteReader, ByteWriter, Truncated};
use engine_headless::net;

pub const PROTOCOL_ID: u16 = u16::from_le_bytes(*b"RT");
pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_DATAGRAM_SIZE: usize = net::MAX_DATAGRAM_SIZE;
pub const MAX_PLAYERS: usize = 4;
pub const INPUT_HISTORY: usize = 3;

/// The message type byte of each message.
mod kind {
    pub const CONNECT: u8 = 1;
    pub const ACCEPT: u8 = 2;
    pub const REJECT: u8 = 3;
    pub const INPUT: u8 = 4;
    pub const SNAPSHOT: u8 = 5;
    pub const DISCONNECT: u8 = 6;
    pub const PLAYER_LEFT: u8 = 7;
}

/// The buttons a Player holds, one bit each. Built only from known bits, so a
/// decoded value is always valid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Buttons(u8);

impl Buttons {
    pub const NONE: Self = Self(0);
    pub const UP: Self = Self(1 << 0);
    pub const DOWN: Self = Self(1 << 1);
    pub const LEFT: Self = Self(1 << 2);
    pub const RIGHT: Self = Self(1 << 3);
    pub const FIRE: Self = Self(1 << 4);
    pub const ALL: Self = Self(0b1_1111);

    /// The buttons whose bits are set, or `None` if a bit names no button.
    pub const fn from_bits(bits: u8) -> Option<Self> {
        if bits & !Self::ALL.0 == 0 {
            Some(Self(bits))
        } else {
            None
        }
    }

    /// The buttons whose bits are set, ignoring bits that name no button.
    pub const fn from_bits_truncate(bits: u8) -> Self {
        Self(bits & Self::ALL.0)
    }

    pub const fn bits(self) -> u8 {
        self.0
    }

    /// True if every button of `other` is held.
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Buttons {
    type Output = Self;

    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

impl BitOrAssign for Buttons {
    fn bitor_assign(&mut self, other: Self) {
        self.0 |= other.0;
    }
}

/// The buttons a Player held during one Client Tick.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct InputState {
    pub tick: u32,
    pub buttons: Buttons,
}

/// The last [`INPUT_HISTORY`] input states, newest first, so that one lost
/// datagram loses no input.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Input {
    pub recent: [InputState; INPUT_HISTORY],
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ShipState {
    pub player: u8,
    pub x: u16,
    pub y: u16,
}

/// Where the Ships are at one Server Tick: up to [`MAX_PLAYERS`] of them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub tick: u32,
    // Private, so that `ship_count <= MAX_PLAYERS` always holds.
    ship_count: u8,
    ships: [ShipState; MAX_PLAYERS],
}

impl Snapshot {
    /// A snapshot of the first [`MAX_PLAYERS`] Ships of `ships`; any more are
    /// left out.
    pub fn new(tick: u32, ships: impl IntoIterator<Item = ShipState>) -> Self {
        let mut snapshot = Self {
            tick,
            ..Self::default()
        };
        // `zip` stops at the shorter side: at most MAX_PLAYERS Ships.
        for (slot, ship) in snapshot.ships.iter_mut().zip(ships) {
            *slot = ship;
            snapshot.ship_count += 1;
        }
        snapshot
    }

    pub fn ships(&self) -> &[ShipState] {
        self.ships
            .get(..usize::from(self.ship_count))
            .unwrap_or_default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectReason {
    MatchFull = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Message {
    Connect,
    Accept { player: u8 },
    Reject { reason: RejectReason },
    Input(Input),
    Snapshot(Snapshot),
    Disconnect,
    PlayerLeft { player: u8 },
}

impl Message {
    const fn kind(&self) -> u8 {
        match self {
            Self::Connect => kind::CONNECT,
            Self::Accept { .. } => kind::ACCEPT,
            Self::Reject { .. } => kind::REJECT,
            Self::Input(_) => kind::INPUT,
            Self::Snapshot(_) => kind::SNAPSHOT,
            Self::Disconnect => kind::DISCONNECT,
            Self::PlayerLeft { .. } => kind::PLAYER_LEFT,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Packet {
    pub sequence: u32,
    pub message: Message,
}

/// Why a datagram is not a packet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeError {
    TooLong,
    Truncated,
    BadProtocol,
    BadVersion,
    UnknownType,
    BadValue,
    TrailingBytes,
}

impl DecodeError {
    /// Every error, in declaration order, for tallies: `error as usize` is its
    /// position here.
    pub const ALL: [Self; 7] = [
        Self::TooLong,
        Self::Truncated,
        Self::BadProtocol,
        Self::BadVersion,
        Self::UnknownType,
        Self::BadValue,
        Self::TrailingBytes,
    ];
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::TooLong => "too long",
            Self::Truncated => "truncated",
            Self::BadProtocol => "bad protocol id",
            Self::BadVersion => "bad version",
            Self::UnknownType => "unknown message type",
            Self::BadValue => "value out of range",
            Self::TrailingBytes => "trailing bytes",
        })
    }
}

impl std::error::Error for DecodeError {}

// Lets `?` turn a reader's `Truncated` into a `DecodeError`.
impl From<Truncated> for DecodeError {
    fn from(_: Truncated) -> Self {
        Self::Truncated
    }
}

/// An encoded packet, held in place: encoding never allocates.
#[derive(Clone, Debug)]
pub struct Encoded {
    buffer: [u8; MAX_DATAGRAM_SIZE],
    len: usize,
}

impl Encoded {
    pub fn as_bytes(&self) -> &[u8] {
        self.buffer.get(..self.len).unwrap_or_default()
    }
}

pub fn encode(packet: &Packet) -> Encoded {
    let mut encoded = Encoded {
        buffer: [0; MAX_DATAGRAM_SIZE],
        len: 0,
    };
    let mut out = ByteWriter::new(&mut encoded.buffer);
    out.u16(PROTOCOL_ID);
    out.u8(PROTOCOL_VERSION);
    out.u8(packet.message.kind());
    out.u32(packet.sequence);
    match &packet.message {
        Message::Connect | Message::Disconnect => {}
        Message::Accept { player } | Message::PlayerLeft { player } => out.u8(*player),
        Message::Reject { reason } => out.u8(*reason as u8),
        Message::Input(input) => {
            for state in &input.recent {
                out.u32(state.tick);
                out.u8(state.buttons.bits());
            }
        }
        Message::Snapshot(snapshot) => {
            out.u32(snapshot.tick);
            out.u8(snapshot.ship_count);
            for ship in snapshot.ships() {
                out.u8(ship.player);
                out.u16(ship.x);
                out.u16(ship.y);
            }
        }
    }
    // The largest message is a few dozen bytes, so this is a programming error.
    assert!(out.is_ok(), "packet does not fit in a datagram");
    encoded.len = out.written();
    encoded
}

/// Decodes one datagram. Never allocates, never panics, and rejects anything
/// but exactly one well-formed packet.
pub fn decode(datagram: &[u8]) -> Result<Packet, DecodeError> {
    if datagram.len() > MAX_DATAGRAM_SIZE {
        return Err(DecodeError::TooLong);
    }
    let mut input = ByteReader::new(datagram);
    let id = input.u16()?;
    let version = input.u8()?;
    let kind = input.u8()?;
    let sequence = input.u32()?;
    if id != PROTOCOL_ID {
        return Err(DecodeError::BadProtocol);
    }
    if version != PROTOCOL_VERSION {
        return Err(DecodeError::BadVersion);
    }
    let message = match kind {
        kind::CONNECT => Message::Connect,
        kind::ACCEPT => Message::Accept {
            player: read_player(&mut input)?,
        },
        kind::REJECT => Message::Reject {
            reason: read_reject_reason(&mut input)?,
        },
        kind::INPUT => Message::Input(read_input(&mut input)?),
        kind::SNAPSHOT => Message::Snapshot(read_snapshot(&mut input)?),
        kind::DISCONNECT => Message::Disconnect,
        kind::PLAYER_LEFT => Message::PlayerLeft {
            player: read_player(&mut input)?,
        },
        _ => return Err(DecodeError::UnknownType),
    };
    if input.remaining() != 0 {
        return Err(DecodeError::TrailingBytes);
    }
    Ok(Packet { sequence, message })
}

// Each body reader returns Truncated before BadValue when both apply, like
// the C++ decoder, so the two tally rejected datagrams the same way.

fn read_player(input: &mut ByteReader) -> Result<u8, DecodeError> {
    let player = input.u8()?;
    if usize::from(player) < MAX_PLAYERS {
        Ok(player)
    } else {
        Err(DecodeError::BadValue)
    }
}

fn read_reject_reason(input: &mut ByteReader) -> Result<RejectReason, DecodeError> {
    match input.u8()? {
        1 => Ok(RejectReason::MatchFull),
        _ => Err(DecodeError::BadValue),
    }
}

fn read_input(input: &mut ByteReader) -> Result<Input, DecodeError> {
    let mut recent = [InputState::default(); INPUT_HISTORY];
    // Every state is read before any is judged: a short datagram is
    // `Truncated` even if an earlier state held unknown buttons.
    let mut known_buttons = true;
    for state in &mut recent {
        state.tick = input.u32()?;
        match Buttons::from_bits(input.u8()?) {
            Some(buttons) => state.buttons = buttons,
            None => known_buttons = false,
        }
    }
    let newest_first = recent.is_sorted_by(|newer, older| newer.tick >= older.tick);
    if known_buttons && newest_first {
        Ok(Input { recent })
    } else {
        Err(DecodeError::BadValue)
    }
}

fn read_snapshot(input: &mut ByteReader) -> Result<Snapshot, DecodeError> {
    let tick = input.u32()?;
    let count = usize::from(input.u8()?);
    // Checked before use: an attacker-chosen count never sizes or indexes anything.
    if count > MAX_PLAYERS {
        return Err(DecodeError::BadValue);
    }
    let mut ships = [ShipState::default(); MAX_PLAYERS];
    let mut seen = [false; MAX_PLAYERS];
    for ship in ships.iter_mut().take(count) {
        *ship = ShipState {
            player: input.u8()?,
            x: input.u16()?,
            y: input.u16()?,
        };
        // `get_mut` is None for an index out of range: no panic possible.
        match seen.get_mut(usize::from(ship.player)) {
            Some(already_seen) if !*already_seen => *already_seen = true,
            _ => return Err(DecodeError::BadValue), // no such Player, or one twice
        }
    }
    Ok(Snapshot::new(tick, ships.into_iter().take(count)))
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, clippy::unwrap_used)]
mod tests {
    use super::*;

    const HEADER: [u8; 8] = [b'R', b'T', 1, 0, 0x04, 0x03, 0x02, 0x01];

    fn bytes_of(message: Message) -> Vec<u8> {
        let packet = Packet {
            sequence: 0x0102_0304,
            message,
        };
        encode(&packet).as_bytes().to_vec()
    }

    fn with_header(kind: u8, body: &[u8]) -> Vec<u8> {
        let mut bytes = HEADER.to_vec();
        bytes[3] = kind;
        bytes.extend_from_slice(body);
        bytes
    }

    #[test]
    fn layout_matches_the_wire_format() {
        assert_eq!(bytes_of(Message::Connect), with_header(1, &[]));
        let accept = Message::Accept { player: 2 };
        assert_eq!(bytes_of(accept), with_header(2, &[2]));
        let reject = Message::Reject {
            reason: RejectReason::MatchFull,
        };
        assert_eq!(bytes_of(reject), with_header(3, &[1]));
        let input = Input {
            recent: [
                InputState {
                    tick: 0x0A0B_0C0D,
                    buttons: Buttons::UP | Buttons::FIRE,
                },
                InputState {
                    tick: 7,
                    buttons: Buttons::NONE,
                },
                InputState {
                    tick: 6,
                    buttons: Buttons::RIGHT,
                },
            ],
        };
        let body = [0x0D, 0x0C, 0x0B, 0x0A, 0x11, 7, 0, 0, 0, 0, 6, 0, 0, 0, 8];
        assert_eq!(bytes_of(Message::Input(input)), with_header(4, &body));
        let ships = [
            ShipState {
                player: 1,
                x: 0x0102,
                y: 0x0304,
            },
            ShipState {
                player: 3,
                x: 5,
                y: 6,
            },
        ];
        let snapshot = Message::Snapshot(Snapshot::new(9, ships));
        let body = [9, 0, 0, 0, 2, 1, 0x02, 0x01, 0x04, 0x03, 3, 5, 0, 6, 0];
        assert_eq!(bytes_of(snapshot), with_header(5, &body));
        assert_eq!(bytes_of(Message::Disconnect), with_header(6, &[]));
        let player_left = Message::PlayerLeft { player: 3 };
        assert_eq!(bytes_of(player_left), with_header(7, &[3]));
    }

    #[test]
    fn decodes_what_it_encodes() {
        let messages = [
            Message::Connect,
            Message::Accept { player: 3 },
            Message::Reject {
                reason: RejectReason::MatchFull,
            },
            Message::Input(Input::default()),
            Message::Snapshot(Snapshot::new(u32::MAX, [ShipState::default()])),
            Message::Disconnect,
            Message::PlayerLeft { player: 0 },
        ];
        for message in messages {
            let packet = Packet {
                sequence: 42,
                message,
            };
            assert_eq!(decode(encode(&packet).as_bytes()), Ok(packet));
        }
    }

    #[test]
    fn rejects_malformed_datagrams() {
        let error = |bytes: &[u8]| decode(bytes).unwrap_err();
        assert_eq!(error(&[0; MAX_DATAGRAM_SIZE + 1]), DecodeError::TooLong);
        assert_eq!(error(&[]), DecodeError::Truncated);
        assert_eq!(error(&HEADER[..7]), DecodeError::Truncated);
        let other_protocol = [b'R', b'X', 1, 1, 0, 0, 0, 0];
        assert_eq!(error(&other_protocol), DecodeError::BadProtocol);
        let other_version = [b'R', b'T', 2, 1, 0, 0, 0, 0];
        assert_eq!(error(&other_version), DecodeError::BadVersion);
        assert_eq!(error(&with_header(0, &[])), DecodeError::UnknownType);
        assert_eq!(error(&with_header(8, &[])), DecodeError::UnknownType);
        assert_eq!(error(&with_header(2, &[])), DecodeError::Truncated);
        assert_eq!(error(&with_header(2, &[4])), DecodeError::BadValue);
        assert_eq!(error(&with_header(3, &[2])), DecodeError::BadValue);
        assert_eq!(error(&with_header(1, &[0])), DecodeError::TrailingBytes);
        // Input: unknown button bits, ticks out of order, truncation first.
        let mut input = [0; 15];
        input[4] = 0x20;
        assert_eq!(error(&with_header(4, &input)), DecodeError::BadValue);
        assert_eq!(error(&with_header(4, &input[..14])), DecodeError::Truncated);
        let mut input = [0; 15];
        input[5] = 1;
        assert_eq!(error(&with_header(4, &input)), DecodeError::BadValue);
        // Snapshot: too many Ships, a Player out of range, a Player twice.
        let five_ships = [0, 0, 0, 0, 5];
        assert_eq!(error(&with_header(5, &five_ships)), DecodeError::BadValue);
        let one_ship = [0, 0, 0, 0, 1, 4, 0, 0, 0, 0];
        assert_eq!(error(&with_header(5, &one_ship)), DecodeError::BadValue);
        let twice = [0, 0, 0, 0, 2, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0];
        assert_eq!(error(&with_header(5, &twice)), DecodeError::BadValue);
        assert_eq!(error(&with_header(5, &twice[..12])), DecodeError::Truncated);
    }
}
