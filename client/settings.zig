//! The Client's settings: what the Player can change in settings.zon. Where
//! that file is looked for, and what happens when it is missing or not valid,
//! is the Engine's `engine_headless.settings`.

const std = @import("std");
const engine = @import("engine_client");
const Action = @import("game").protocol.Action;

pub const Settings = struct {
    /// The defaults must be those of settings.zon: a test checks it.
    bindings: engine.Bindings(Action) = .{
        .up = &.{ .{ .key = .up }, .{ .gamepad = .dpad_up }, .{ .gamepad = .left_stick_up } },
        .down = &.{ .{ .key = .down }, .{ .gamepad = .dpad_down }, .{ .gamepad = .left_stick_down } },
        .left = &.{ .{ .key = .left }, .{ .gamepad = .dpad_left }, .{ .gamepad = .left_stick_left } },
        .right = &.{ .{ .key = .right }, .{ .gamepad = .dpad_right }, .{ .gamepad = .left_stick_right } },
        .fire = &.{ .{ .key = .space }, .{ .gamepad = .face_down } },
    },
};

/// The file written for the Player when there is none: `Settings{}`, with
/// comments explaining each setting.
pub const defaults_file = @embedFile("settings.zon");

test "settings.zon holds the defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, arena.allocator(), defaults_file, null, .{});
    try std.testing.expectEqualDeep(Settings{}, parsed);
}
