// The Ships' look: one colour per Player, from the provided sprite sheet.
package main

import engine "../engine/client"
import "../game"

// The sheet, compiled into the program so that it runs on its own.
SHEET_GIF :: #load("../assets/r-typesheet42.gif")

// The sheet is a grid of 33x17 cells: one row per colour, and five frames per
// row, from banking down to banking up; the middle one flies level.
CELL_WIDTH :: 33.0
CELL_HEIGHT :: 17.0
LEVEL_FRAME :: 2.0

// Matches the sheet's rows: cyan, magenta, green, red.
PLAYER_COLORS :: [game.MAX_PLAYERS]engine.Color {
	{90, 220, 255, 255},
	{255, 120, 255, 255},
	{120, 255, 120, 255},
	{255, 110, 90, 255},
}

Ship_Sprites :: struct {
	sheet: engine.Texture,
}

load_ship_sprites :: proc(window: ^engine.Window) -> (sprites: Ship_Sprites, err: engine.Error) {
	sprites.sheet = engine.load_texture(window, ".gif", SHEET_GIF) or_return
	return
}

unload_ship_sprites :: proc(sprites: Ship_Sprites) {
	engine.unload_texture(sprites.sheet)
}

draw_ship :: proc(sprites: ^Ship_Sprites, frame: ^engine.Frame, ship: game.Ship_State) {
	cell := engine.Rect {
		x      = LEVEL_FRAME * CELL_WIDTH,
		y      = f32(ship.player) * CELL_HEIGHT,
		width  = CELL_WIDTH,
		height = CELL_HEIGHT,
	}
	on_screen := engine.Rect {
		x      = f32(ship.x),
		y      = f32(ship.y),
		width  = game.SHIP_WIDTH,
		height = game.SHIP_HEIGHT,
	}
	engine.draw_texture(frame, sprites.sheet, cell, on_screen, engine.WHITE)
}
