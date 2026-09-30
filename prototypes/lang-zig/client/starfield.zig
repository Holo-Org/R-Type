//! The Star-field: three layers of procedurally placed stars scrolling left.
//! Nearer layers have bigger, brighter and faster stars, which gives depth.

const std = @import("std");
const engine = @import("engine_client");

const Star = struct {
    x: f32,
    y: f32,
};

const Layer = struct {
    count: usize,
    /// Pixels per second.
    speed: f32,
    /// Pixels.
    size: f32,
    color: engine.Color,
};

const layers = [_]Layer{
    .{ .count = 120, .speed = 25, .size = 1, .color = .rgb(90, 90, 120) },
    .{ .count = 60, .speed = 70, .size = 2, .color = .rgb(160, 160, 200) },
    .{ .count = 25, .speed = 160, .size = 3, .color = .white },
};

const star_count = count: {
    var total: usize = 0;
    for (layers) |layer| total += layer.count;
    break :count total;
};

pub const Starfield = struct {
    width: f32,
    /// Every layer's stars, one layer after the other.
    stars: [star_count]Star,

    pub fn init(width: f32, height: f32, seed: u64) Starfield {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var starfield: Starfield = .{ .width = width, .stars = undefined };
        for (&starfield.stars) |*star| {
            star.* = .{ .x = random.float(f32) * width, .y = random.float(f32) * height };
        }
        return starfield;
    }

    pub fn scroll(starfield: *Starfield, seconds: f32) void {
        var stars: []Star = &starfield.stars;
        for (layers) |layer| {
            for (stars[0..layer.count]) |*star| {
                star.x -= layer.speed * seconds;
                if (star.x < 0) star.x += starfield.width;
            }
            stars = stars[layer.count..];
        }
    }

    pub fn draw(starfield: *const Starfield, frame: *engine.Frame) void {
        var stars: []const Star = &starfield.stars;
        for (layers) |layer| {
            for (stars[0..layer.count]) |star| {
                frame.drawRect(.{ .x = star.x, .y = star.y, .width = layer.size, .height = layer.size }, layer.color);
            }
            stars = stars[layer.count..];
        }
    }
};
