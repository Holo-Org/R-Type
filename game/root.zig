//! The Game: R-Type's messages and rules, built on the Engine's headless part.
//! It must stay headless, since the Server links it.

pub const protocol = @import("protocol.zig");
pub const match = @import("match.zig");
pub const rules = @import("rules.zig");
pub const world = @import("world.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
