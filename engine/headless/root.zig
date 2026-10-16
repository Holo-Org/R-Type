//! The Engine's headless part: what both the Server and the Clients need, and
//! nothing that draws, plays sound or reads a keyboard. Like all of the Engine,
//! it knows nothing about R-Type (ADR 0001).

pub const bytes = @import("bytes.zig");
pub const net = @import("net.zig");
pub const time = @import("time.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
