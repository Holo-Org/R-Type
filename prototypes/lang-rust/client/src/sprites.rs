//! The Ships' look: one colour per Player, from the provided sprite sheet.

use engine_client::{Color, Error, Frame, Rect, Texture, Window};
use game::protocol::ShipState;
use game::rules::{SHIP_HEIGHT, SHIP_WIDTH};

/// The sheet, compiled into the program so that it runs on its own.
const SHEET_GIF: &[u8] = include_bytes!("../../assets/r-typesheet42.gif");

// The sheet is a grid of 33x17 cells: one row per colour, and five frames per
// row, from banking down to banking up; the middle one flies level.
const CELL_WIDTH: f32 = 33.0;
const CELL_HEIGHT: f32 = 17.0;
const LEVEL_FRAME: f32 = 2.0;

/// Matches the sheet's rows: cyan, magenta, green, red.
pub const PLAYER_COLORS: [Color; 4] = [
    Color::rgb(90, 220, 255),
    Color::rgb(255, 120, 255),
    Color::rgb(120, 255, 120),
    Color::rgb(255, 110, 90),
];

pub struct ShipSprites {
    sheet: Texture,
}

impl ShipSprites {
    pub fn load(window: &mut Window) -> Result<Self, Error> {
        let sheet = window.load_texture(".gif", SHEET_GIF)?;
        Ok(Self { sheet })
    }

    pub fn draw(&self, frame: &mut Frame, ship: &ShipState) {
        let cell = Rect {
            x: LEVEL_FRAME * CELL_WIDTH,
            y: f32::from(ship.player) * CELL_HEIGHT,
            width: CELL_WIDTH,
            height: CELL_HEIGHT,
        };
        let on_screen = Rect {
            x: f32::from(ship.x),
            y: f32::from(ship.y),
            width: SHIP_WIDTH as f32,
            height: SHIP_HEIGHT as f32,
        };
        frame.draw_texture(&self.sheet, cell, on_screen, Color::WHITE);
    }
}
