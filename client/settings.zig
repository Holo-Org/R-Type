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
    /// Fire toggles firing on and off rather than being held.
    auto_fire: bool = false,
    /// From 0, silent, to 1; values beyond are clamped.
    effects_volume: f32 = 1.0,

    /// Whether the Ship fires, from whether it fired the Tick before, and
    /// whether fire is held now and was the Tick before. Without auto-fire,
    /// firing is holding fire.
    pub fn firing(settings: *const Settings, was_firing: bool, held: bool, held_before: bool) bool {
        if (!settings.auto_fire) return held;
        return if (held and !held_before) !was_firing else was_firing;
    }
};

test "auto-fire toggles on each press" {
    const toggled: Settings = .{ .auto_fire = true };
    try std.testing.expect(toggled.firing(false, true, false)); // pressed: on
    try std.testing.expect(toggled.firing(true, true, true)); // held: still on
    try std.testing.expect(toggled.firing(true, false, true)); // released: still on
    try std.testing.expect(!toggled.firing(true, true, false)); // pressed again: off
    const held: Settings = .{};
    try std.testing.expect(held.firing(false, true, true) and !held.firing(true, false, true));
}

/// The file written for the Player when there is none: `Settings{}`, with
/// comments explaining each setting.
pub const defaults_file = @embedFile("settings.zon");

test "settings.zon holds the defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, arena.allocator(), defaults_file, null, .{});
    try std.testing.expectEqualDeep(Settings{}, parsed);
}
