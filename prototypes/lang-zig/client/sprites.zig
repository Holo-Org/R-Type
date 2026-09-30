//! The Ships' look: one colour per Player, from the provided sprite sheet.

const engine = @import("engine_client");
const game = @import("game");

/// The sheet, compiled into the program so that it runs on its own. build.zig
/// maps the name to assets/r-typesheet42.gif, which lies outside this module's
/// directory, where a plain path could not reach.
const sheet_gif = @embedFile("ship_sheet");

// The sheet is a grid of 33x17 cells: one row per colour, and five frames per
// row, from banking down to banking up; the middle one flies level.
const cell_width = 33.0;
const cell_height = 17.0;
const level_frame = 2.0;

/// Matches the sheet's rows: cyan, magenta, green, red.
pub const player_colors = [_]engine.Color{
    .rgb(90, 220, 255),
    .rgb(255, 120, 255),
    .rgb(120, 255, 120),
    .rgb(255, 110, 90),
};

pub const ShipSprites = struct {
    sheet: engine.Texture,

    pub fn load(window: *engine.Window) engine.Error!ShipSprites {
        return .{ .sheet = try window.loadTexture(".gif", sheet_gif) };
    }

    pub fn unload(sprites: *const ShipSprites) void {
        sprites.sheet.unload();
    }

    pub fn draw(sprites: *const ShipSprites, frame: *engine.Frame, ship: game.protocol.ShipState) void {
        const cell: engine.Rect = .{
            .x = level_frame * cell_width,
            .y = @as(f32, @floatFromInt(ship.player)) * cell_height,
            .width = cell_width,
            .height = cell_height,
        };
        const on_screen: engine.Rect = .{
            .x = @floatFromInt(ship.x),
            .y = @floatFromInt(ship.y),
            .width = game.match.ship_width,
            .height = game.match.ship_height,
        };
        frame.drawTexture(&sprites.sheet, cell, on_screen, .white);
    }
};
