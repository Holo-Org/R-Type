//! Which of the Server's Matches a Player plays in. The Server runs several
//! Matches side by side, each for up to four Players, so that more Players
//! can play at once than one Match takes. A Client never chooses: each new
//! Player goes to the first Match that takes them.

const std = @import("std");
const game = @import("game");
const Endpoint = @import("engine_headless").net.Endpoint;
const Match = game.match.Match;
const JoinError = game.match.JoinError;

/// Where a Player plays: a Match's index among the Server's, and the
/// Player's index in that Match.
pub const Place = struct { match: u8, player: u8 };

/// Where `peer` plays, if it plays in one of `matches`.
pub fn find(matches: []const Match, peer: Endpoint) ?Place {
    for (matches, 0..) |*match, index| {
        if (match.find(peer)) |player| return .{ .match = @intCast(index), .player = player };
    }
    return null;
}

/// Where `peer` plays: the Match it already plays in, or else the first
/// Match that lets it join, which fills each Match before the next one
/// opens. When none does, `AlreadyStarted` if a Match is being played, since
/// its join window opens again after game over; `MatchFull` only when every
/// Match is full outside play.
pub fn place(matches: []Match, peer: Endpoint) JoinError!Place {
    if (find(matches, peer)) |known| return known;
    var started = false;
    for (matches, 0..) |*match, index| {
        const player = match.join(peer) catch |err| {
            if (err == error.AlreadyStarted) started = true;
            continue;
        };
        return .{ .match = @intCast(index), .player = player };
    }
    return if (started) error.AlreadyStarted else error.MatchFull;
}

/// Sets up `matches` with `settings`: the first keeps their seed, so that a
/// Server of one Match replays as before, and each next one gets a seed
/// drawn from it.
pub fn init(matches: []Match, settings: game.match.Settings) void {
    var seeds: std.Random.DefaultPrng = .init(settings.seed);
    for (matches, 0..) |*match, index| {
        var own = settings;
        if (index > 0) own.seed = seeds.random().int(u64);
        match.* = .init(own);
    }
}

const testing = std.testing;

fn client(port: u16) Endpoint {
    return .loopback(port);
}

/// Steps every Match until its join window has closed.
fn play(matches: []Match) void {
    for (matches) |*match| {
        for (0..match.settings.join_window + 2) |_| _ = match.step();
    }
}

test "Players fill the first Match before the next" {
    var matches: [3]Match = undefined;
    init(&matches, .{ .seed = 1 });
    for (0..4) |i| try testing.expectEqual(Place{ .match = 0, .player = @intCast(i) }, try place(&matches, client(@intCast(i))));
    try testing.expectEqual(Place{ .match = 1, .player = 0 }, try place(&matches, client(4)));
}

test "a repeated connect finds the same place" {
    var matches: [2]Match = undefined;
    init(&matches, .{ .seed = 1 });
    _ = try place(&matches, client(1));
    const second = try place(&matches, client(2));
    try testing.expectEqual(second, try place(&matches, client(2)));
    try testing.expectEqual(second, find(&matches, client(2)).?);
    try testing.expectEqual(null, find(&matches, client(3)));
}

test "a Match being played is skipped" {
    var matches: [2]Match = undefined;
    init(&matches, .{ .seed = 1, .join_window = 1 });
    _ = try place(&matches, client(1));
    play(matches[0..1]);
    try testing.expectEqual(.playing, matches[0].phase);
    try testing.expectEqual(Place{ .match = 1, .player = 0 }, try place(&matches, client(2)));
}

test "with no room, a Match being played means waiting" {
    var matches: [2]Match = undefined;
    init(&matches, .{ .seed = 1, .join_window = 1 });
    _ = try place(&matches, client(1));
    play(matches[0..1]);
    for (2..6) |port| _ = try place(&matches, client(@intCast(port)));
    try testing.expectError(error.AlreadyStarted, place(&matches, client(9)));
}

test "with every Match full outside play, the Server is full" {
    var matches: [2]Match = undefined;
    init(&matches, .{ .seed = 1 });
    for (0..8) |port| _ = try place(&matches, client(@intCast(port)));
    try testing.expectError(error.MatchFull, place(&matches, client(9)));
}

test "the first Match keeps the Server's seed, and the others differ" {
    var matches: [3]Match = undefined;
    init(&matches, .{ .seed = 42 });
    try testing.expectEqual(42, matches[0].settings.seed);
    try testing.expect(matches[1].settings.seed != matches[2].settings.seed);
    try testing.expect(matches[1].settings.seed != 42);
}
