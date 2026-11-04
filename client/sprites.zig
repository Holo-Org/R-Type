//! What every entity and effect looks like: frames cut from the provided
//! sprite sheets, each drawn at twice its size (#3), and the Players' colours.

const std = @import("std");
const engine = @import("engine_client");
const game = @import("game");
const Box = game.rules.Box;
const Position = game.world.Position;
const Rect = engine.Rect;

/// Every sprite is drawn at twice its size on its sheet.
const scale = 2;

/// The sheets, by their number in assets/sprites.zip. Each is compiled into
/// the program so that it runs on its own: build.zig maps "r-typesheetN.gif"
/// to the file in assets/, which lies outside this module's directory, where
/// a plain path could not reach.
const Sheet = enum {
    sheet1,
    sheet3,
    sheet5,
    sheet42,
    sheet43,
    sheet44,

    fn file(sheet: Sheet) []const u8 {
        return switch (sheet) {
            inline else => |s| @embedFile("r-type" ++ @tagName(s) ++ ".gif"),
        };
    }
};

/// Frames of one sheet, played in order at `rate`, looping.
pub const Animation = struct {
    sheet: Sheet,
    frames: []const Rect,
    /// Frames per second.
    rate: f32,

    /// Seconds to play every frame once.
    pub fn duration(animation: Animation) f32 {
        return @as(f32, @floatFromInt(animation.frames.len)) / animation.rate;
    }

    /// The frame shown `seconds` after the animation started.
    fn frameAt(animation: Animation, seconds: f32) Rect {
        const index: usize = @intFromFloat(@max(0, seconds * animation.rate));
        return animation.frames[index % animation.frames.len];
    }
};

/// `count` cells of `width` by `height`, side by side from `x` every `step`
/// pixels.
fn strip(comptime count: usize, x: f32, step: f32, y: f32, width: f32, height: f32) [count]Rect {
    var cells: [count]Rect = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{ .x = x + step * @as(f32, @floatFromInt(i)), .y = y, .width = width, .height = height };
    }
    return cells;
}

/// The Dart: 16 frames, spinning.
pub const dart: Animation = .{ .sheet = .sheet5, .frames = &strip(16, 0, 33, 0, 33, 36), .rate = 12 };

/// The Pod: 12 frames, turning.
pub const pod: Animation = .{ .sheet = .sheet3, .frames = &strip(12, 0, 17, 0, 17, 18), .rate = 10 };

/// A Ship's Projectile: the blue bolt, flying right. Its neighbour on the
/// sheet is the same bolt flying left: alternating them would flicker.
pub const bolt: Animation = .{ .sheet = .sheet1, .frames = &strip(1, 249, 0, 105, 16, 8), .rate = 1 };

/// An Enemy's Projectile: the orange orb in row 1, which differs from the bolt
/// in shape as well as colour. Its frames are not evenly spaced.
pub const orb: Animation = .{ .sheet = .sheet43, .frames = &.{
    .{ .x = 136, .y = 6, .width = 7, .height = 6 },
    .{ .x = 153, .y = 6, .width = 7, .height = 6 },
    .{ .x = 170, .y = 6, .width = 7, .height = 6 },
    .{ .x = 188, .y = 6, .width = 7, .height = 6 },
    .{ .x = 205, .y = 6, .width = 7, .height = 6 },
    .{ .x = 223, .y = 6, .width = 7, .height = 6 },
    .{ .x = 240, .y = 6, .width = 7, .height = 6 },
    .{ .x = 257, .y = 6, .width = 7, .height = 6 },
}, .rate = 12 };

/// An Enemy destroyed: the yellow burst in row 4, from its flash to its
/// scattering. Each frame is as big as its picture, and drawn centred.
pub const explosion: Animation = .{ .sheet = .sheet43, .frames = &.{
    .{ .x = 2, .y = 60, .width = 18, .height = 15 },
    .{ .x = 30, .y = 57, .width = 27, .height = 20 },
    .{ .x = 62, .y = 54, .width = 32, .height = 27 },
    .{ .x = 97, .y = 54, .width = 32, .height = 29 },
    .{ .x = 132, .y = 54, .width = 32, .height = 30 },
    .{ .x = 167, .y = 54, .width = 32, .height = 30 },
    .{ .x = 201, .y = 54, .width = 32, .height = 30 },
}, .rate = 14 };

/// A Ship destroyed: the burst in row 1 of sheet 44, which grows into a ring
/// and fades. About as wide as a Ship.
pub const ship_explosion: Animation = .{ .sheet = .sheet44, .frames = &.{
    .{ .x = 130, .y = 1, .width = 32, .height = 31 },
    .{ .x = 162, .y = 1, .width = 32, .height = 31 },
    .{ .x = 194, .y = 1, .width = 32, .height = 31 },
    .{ .x = 228, .y = 1, .width = 32, .height = 31 },
    .{ .x = 261, .y = 1, .width = 32, .height = 31 },
    .{ .x = 294, .y = 1, .width = 32, .height = 31 },
    .{ .x = 327, .y = 1, .width = 32, .height = 31 },
}, .rate = 12 };

/// A Ship's Projectile hitting an Enemy: the white flash in row 2 of sheet
/// 43, breaking into sparks.
pub const impact: Animation = .{ .sheet = .sheet43, .frames = &.{
    .{ .x = 135, .y = 22, .width = 9, .height = 8 },
    .{ .x = 151, .y = 21, .width = 11, .height = 10 },
    .{ .x = 167, .y = 20, .width = 13, .height = 12 },
    .{ .x = 183, .y = 19, .width = 15, .height = 14 },
}, .rate = 16 };

// The Ships' sheet is a grid of 33x17 cells: one row per colour, and five
// frames per row, from banking down to banking up; the middle one flies level.
const ship_cell_width = 33.0;
const ship_cell_height = 17.0;
const ship_level_frame = 2.0;

/// From the Okabe-Ito palette, which stays distinct with every common colour
/// blindness: sky blue, reddish purple, bluish green and orange. Each is the
/// nearest to the Ship's own row of the sheet: cyan, magenta, green and red.
/// The Player's number is always drawn beside it, so colour is never needed.
pub const player_colors = [_]engine.Color{
    .rgb(86, 180, 233),
    .rgb(204, 121, 167),
    .rgb(0, 158, 115),
    .rgb(230, 159, 0),
};

/// The centre of a `box` whose top-left corner is at `position`.
pub fn centreOf(position: Position, box: Box) Position {
    return .{ .x = position.x + box.width / 2, .y = position.y + box.height / 2 };
}

pub const Sprites = struct {
    sheets: std.EnumArray(Sheet, engine.Texture),

    pub fn load(window: *engine.Window) engine.Error!Sprites {
        var sprites: Sprites = .{ .sheets = undefined };
        for (std.enums.values(Sheet), 0..) |sheet, loaded| {
            sprites.sheets.set(sheet, window.loadTexture(".gif", sheet.file()) catch |err| {
                for (std.enums.values(Sheet)[0..loaded]) |earlier| sprites.sheets.get(earlier).unload();
                return err;
            });
        }
        return sprites;
    }

    pub fn unload(sprites: *const Sprites) void {
        for (sprites.sheets.values) |texture| texture.unload();
    }

    /// The frame of `animation` shown `seconds` after it started, at twice
    /// its size, centred on `centre`.
    pub fn draw(sprites: *const Sprites, frame: *engine.Frame, animation: Animation, seconds: f32, centre: Position, tint: engine.Color) void {
        const cell = animation.frameAt(seconds);
        sprites.drawCell(frame, animation.sheet, cell, centre, tint);
    }

    /// Player `player`'s Ship, flying level, centred on `centre`.
    pub fn drawShip(sprites: *const Sprites, frame: *engine.Frame, player: u8, centre: Position, tint: engine.Color) void {
        const row: f32 = @floatFromInt(player % player_colors.len);
        const cell: Rect = .{
            .x = ship_level_frame * ship_cell_width,
            .y = row * ship_cell_height,
            .width = ship_cell_width,
            .height = ship_cell_height,
        };
        sprites.drawCell(frame, .sheet42, cell, centre, tint);
    }

    fn drawCell(sprites: *const Sprites, frame: *engine.Frame, sheet: Sheet, cell: Rect, centre: Position, tint: engine.Color) void {
        const width = cell.width * scale;
        const height = cell.height * scale;
        const on_screen: Rect = .{ .x = centre.x - width / 2, .y = centre.y - height / 2, .width = width, .height = height };
        frame.drawTexture(sprites.sheets.getPtrConst(sheet), cell, on_screen, tint);
    }
};

test "an animation loops over its frames at its rate" {
    try std.testing.expectEqual(16.0 / 12.0, dart.duration());
    try std.testing.expectEqual(dart.frames[0], dart.frameAt(0));
    try std.testing.expectEqual(dart.frames[1], dart.frameAt(1.0 / 12.0 + 0.001));
    try std.testing.expectEqual(dart.frames[0], dart.frameAt(dart.duration() + 0.001));
}

test "every frame lies inside its sheet" {
    for ([_]Animation{ dart, pod, bolt, orb, explosion, ship_explosion, impact }) |animation| {
        // A GIF gives its width and height right after its 6-byte signature.
        const file = animation.sheet.file();
        const width: f32 = @floatFromInt(std.mem.readInt(u16, file[6..8], .little));
        const height: f32 = @floatFromInt(std.mem.readInt(u16, file[8..10], .little));
        for (animation.frames) |cell| {
            try std.testing.expect(cell.x >= 0 and cell.x + cell.width <= width);
            try std.testing.expect(cell.y >= 0 and cell.y + cell.height <= height);
        }
    }
}
