//! Leaving the Match with Esc. While the Player's Ship is alive, the first
//! Esc only asks to confirm, so that a slip never destroys it; a second one
//! within 3 s quits. Anywhere else, Esc quits at once.

const std = @import("std");

/// How long the first Esc waits for the second, in seconds.
pub const confirm_seconds = 3;

pub const Leaving = struct {
    /// When the first Esc was pressed, on the View's clock; null: not asked.
    asked: ?f32 = null,

    /// Esc was pressed at `now`: whether to quit.
    pub fn escape(l: *Leaving, now: f32, ship_alive: bool) bool {
        if (!ship_alive or l.asking(now)) return true;
        l.asked = now;
        return false;
    }

    /// Whether to show "Press Esc again to leave the Match".
    pub fn asking(l: *const Leaving, now: f32) bool {
        const at = l.asked orelse return false;
        return now - at < confirm_seconds;
    }
};

const testing = std.testing;

test "with a Ship alive, Esc quits only when pressed twice within 3 s" {
    var l: Leaving = .{};
    try testing.expect(!l.escape(10, true));
    try testing.expect(l.asking(12.9));
    try testing.expect(l.escape(12.9, true));

    l = .{};
    try testing.expect(!l.escape(10, true));
    try testing.expect(!l.asking(13));
    try testing.expect(!l.escape(13, true)); // too late: asks again
    try testing.expect(l.escape(14, true));
}

test "without a Ship alive, Esc quits at once" {
    var l: Leaving = .{};
    try testing.expect(l.escape(0, false));
}
