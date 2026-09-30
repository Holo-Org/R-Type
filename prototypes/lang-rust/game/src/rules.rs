//! The rules of a Match: who plays, how Ships move, when a silent Player is dropped.

use engine_headless::net::Endpoint;

use crate::protocol::{Buttons, Input, MAX_PLAYERS, ShipState, Snapshot};

pub const WORLD_WIDTH: i32 = 1280;
pub const WORLD_HEIGHT: i32 = 720;
/// A 33x17 sprite drawn at twice its size.
pub const SHIP_WIDTH: i32 = 66;
pub const SHIP_HEIGHT: i32 = 34;
/// Pixels per Tick.
pub const SHIP_SPEED: i32 = 6;
/// Ticks per second.
pub const TICK_RATE: u32 = 60;
/// Ticks a Player may stay silent before being dropped.
pub const SILENCE_LIMIT: u32 = 3 * TICK_RATE;

/// A Player of the Match, as the Server knows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Player {
    pub peer: Endpoint,
    /// Server Tick of the Player's last packet.
    pub last_heard: u32,
    /// Client Tick of the newest input applied.
    pub last_input: u32,
    pub buttons: Buttons,
    pub x: i32,
    pub y: i32,
}

#[derive(Debug, Default)]
pub struct Match {
    players: [Option<Player>; MAX_PLAYERS],
    tick: u32,
}

impl Match {
    pub fn new() -> Self {
        Self::default()
    }

    /// The Player index of `peer`, joining it if it is new; `None` if the Match is full.
    pub fn join(&mut self, peer: Endpoint) -> Option<u8> {
        if let Some(existing) = self.find(peer) {
            return Some(existing); // a repeated connect, after a lost accept
        }
        let index = self.players.iter().position(Option::is_none)?;
        let player = index as u8; // below MAX_PLAYERS
        self.players[index] = Some(Player {
            peer,
            last_heard: self.tick,
            last_input: 0,
            buttons: Buttons::NONE,
            x: 64,
            y: 90 + 160 * i32::from(player),
        });
        Some(player)
    }

    pub fn find(&self, peer: Endpoint) -> Option<u8> {
        let index = self
            .players
            .iter()
            .position(|slot| slot.is_some_and(|player| player.peer == peer))?;
        Some(index as u8)
    }

    pub fn leave(&mut self, player: u8) {
        if let Some(slot) = self.players.get_mut(usize::from(player)) {
            *slot = None;
        }
    }

    /// Records the newest buttons held by a Player; also proves it is alive.
    pub fn receive(&mut self, player: u8, input: &Input) {
        let Some(Some(state)) = self.players.get_mut(usize::from(player)) else {
            return;
        };
        state.last_heard = self.tick;
        // Datagrams can arrive out of order: never go back to older buttons.
        let [newest, ..] = input.recent;
        if newest.tick > state.last_input {
            state.last_input = newest.tick;
            state.buttons = newest.buttons;
        }
    }

    /// Advances one Tick: moves every Ship, then drops and returns the
    /// Players who have been silent for longer than [`SILENCE_LIMIT`].
    pub fn step(&mut self) -> Vec<u8> {
        self.tick = self.tick.wrapping_add(1);
        let mut dropped = Vec::new();
        for (index, slot) in self.players.iter_mut().enumerate() {
            let Some(player) = slot else { continue };
            if self.tick.wrapping_sub(player.last_heard) > SILENCE_LIMIT {
                *slot = None;
                dropped.push(index as u8);
                continue;
            }
            let held = |button| i32::from(player.buttons.contains(button));
            let dx = held(Buttons::RIGHT) - held(Buttons::LEFT);
            let dy = held(Buttons::DOWN) - held(Buttons::UP);
            player.x = (player.x + dx * SHIP_SPEED).clamp(0, WORLD_WIDTH - SHIP_WIDTH);
            player.y = (player.y + dy * SHIP_SPEED).clamp(0, WORLD_HEIGHT - SHIP_HEIGHT);
        }
        dropped
    }

    pub fn snapshot(&self) -> Snapshot {
        let ships = self.players.iter().enumerate().filter_map(|(index, slot)| {
            slot.map(|player| ShipState {
                player: index as u8,
                // Clamped by step() to the world, which fits in a u16.
                x: player.x as u16,
                y: player.y as u16,
            })
        });
        Snapshot::new(self.tick, ships)
    }

    pub fn tick(&self) -> u32 {
        self.tick
    }

    pub fn players(&self) -> impl Iterator<Item = &Player> {
        self.players.iter().flatten()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::InputState;

    fn peer(port: u16) -> Endpoint {
        Endpoint::new([127, 0, 0, 1].into(), port)
    }

    #[test]
    fn four_players_join_and_a_fifth_is_refused() {
        let mut match_ = Match::new();
        for port in 0..4 {
            assert_eq!(match_.join(peer(port)), Some(port as u8));
        }
        let again = match_.join(peer(2));
        assert_eq!(again, Some(2), "a repeated connect keeps its index");
        assert_eq!(match_.join(peer(9)), None);
        match_.leave(1);
        assert_eq!(match_.join(peer(9)), Some(1), "a free slot is reused");
    }

    #[test]
    fn ships_move_with_the_newest_input_and_stay_in_the_world() {
        let mut match_ = Match::new();
        let player = match_.join(peer(1)).unwrap();
        let input = |tick, buttons| Input {
            recent: [InputState { tick, buttons }; 3],
        };
        match_.receive(player, &input(2, Buttons::LEFT | Buttons::UP));
        match_.receive(player, &input(1, Buttons::RIGHT)); // older: ignored
        for _ in 0..100 {
            match_.step();
        }
        let ship = match_.snapshot().ships()[0];
        assert_eq!((ship.x, ship.y), (0, 0));
    }

    #[test]
    fn a_silent_player_is_dropped_after_three_seconds() {
        let mut match_ = Match::new();
        match_.join(peer(1));
        for _ in 0..SILENCE_LIMIT {
            assert!(match_.step().is_empty());
        }
        assert_eq!(match_.step(), vec![0]);
        assert_eq!(match_.players().count(), 0);
    }
}
