//! What is drawn over the Match: the status line, every Player's hit points,
//! the join window's countdown and the game-over screen. Nothing blinks.

const std = @import("std");
const engine = @import("engine_client");
const game = @import("game");
const Scene = @import("scene.zig").Scene;
const PlayerSet = game.match.PlayerSet;
const player_colors = @import("sprites.zig").player_colors;
const screen_width = game.rules.screen_width;
const screen_height = game.rules.screen_height;

const margin = 16;

/// A line of text in the top-left corner, such as who we connect to.
pub fn drawStatus(frame: *engine.Frame, text: []const u8, color: engine.Color) void {
    frame.drawText(text, margin, 12, 20, color);
}

/// "Player N" in the Player's colour, so that each Player knows their Ship,
/// or "Player N: destroyed" once their Ship is.
pub fn drawPlayer(frame: *engine.Frame, player: u8, destroyed: bool) void {
    var buffer: [32]u8 = undefined;
    const suffix: []const u8 = if (destroyed) ": destroyed" else "";
    const text = std.fmt.bufPrint(&buffer, "Player {d}{s}", .{ player + 1, suffix }) catch unreachable;
    drawStatus(frame, text, player_colors[player % player_colors.len]);
}

/// A heart, one pixel art row per string.
const heart = [_][]const u8{
    ".##.##.",
    "#######",
    "#######",
    ".#####.",
    "..###..",
    "...#...",
};
const heart_pixel = 3;
const heart_width = heart[0].len * heart_pixel;
const heart_height = heart.len * heart_pixel;
/// Beyond this many hit points, one heart and a count stand for them.
const max_hearts = 5;

fn drawHeart(frame: *engine.Frame, x: f32, y: f32, color: engine.Color) void {
    for (heart, 0..) |line, row| {
        for (line, 0..) |pixel, column| {
            if (pixel != '#') continue;
            frame.drawRect(.{
                .x = x + @as(f32, @floatFromInt(column * heart_pixel)),
                .y = y + @as(f32, @floatFromInt(row * heart_pixel)),
                .width = heart_pixel,
                .height = heart_pixel,
            }, color);
        }
    }
}

/// In the bottom-left corner, one line per Player of the Match, Player 1 at
/// the top: the Player's number, then a heart per hit point, in their colour.
/// A destroyed Ship's line keeps its number, with no heart.
pub fn drawHeartBar(frame: *engine.Frame, players: PlayerSet, scene: *const Scene) void {
    const line_height = heart_height + 8;
    const count = players.count();
    var buffer: [16]u8 = undefined;
    var line: usize = 0;
    var listed = players.iterator(.{});
    while (listed.next()) |player| : (line += 1) {
        const color = player_colors[player % player_colors.len];
        const y: i32 = @intCast(screen_height - margin - (count - line) * line_height);
        const label = std.fmt.bufPrint(&buffer, "P{d}", .{player + 1}) catch unreachable;
        frame.drawText(label, margin, y, 20, color);
        const ship = for (scene.ships.slice()) |ship| {
            if (ship.player == player) break ship;
        } else continue; // destroyed
        const hit_points = ship.hit_points orelse continue; // not in today's Snapshots
        var x: f32 = margin + 36;
        for (0..@min(hit_points, max_hearts)) |_| {
            drawHeart(frame, x, @floatFromInt(y), color);
            x += heart_width + 4;
        }
        if (hit_points > max_hearts) {
            const more = std.fmt.bufPrint(&buffer, "x{d}", .{hit_points}) catch unreachable;
            frame.drawText(more, @intFromFloat(x), y, 20, color);
        }
    }
}

fn drawCentred(frame: *engine.Frame, text: []const u8, y: i32, size: i32, color: engine.Color) void {
    frame.drawText(text, @divTrunc(screen_width - frame.measureText(text, size), 2), y, size, color);
}

/// During the join window, the seconds left before the Waves come, in large
/// type. The join window is the wait: there is no other waiting screen.
pub fn drawCountdown(frame: *engine.Frame, scene: *const Scene) void {
    if (scene.phase != .join_window) return;
    const seconds = scene.secondsLeft().?;
    var buffer: [16]u8 = undefined;
    drawCentred(frame, "The Match starts in", 200, 30, .white);
    drawCentred(frame, std.fmt.bufPrint(&buffer, "{d}", .{seconds}) catch unreachable, 250, 120, .white);
}

/// After game over, until the next join window opens: the Match dimmed,
/// "Game over" in large type, and the seconds to the next Match beneath it.
pub fn drawGameOver(frame: *engine.Frame, scene: *const Scene) void {
    if (scene.phase != .game_over) return;
    frame.drawRect(.{ .width = screen_width, .height = screen_height }, .{ .r = 0, .g = 0, .b = 0, .a = 170 });
    drawCentred(frame, "Game over", 260, 96, .white);
    var buffer: [32]u8 = undefined;
    const next = std.fmt.bufPrint(&buffer, "Next Match in {d} s", .{scene.secondsLeft().?}) catch unreachable;
    drawCentred(frame, next, 380, 30, .rgb(180, 180, 200));
}
