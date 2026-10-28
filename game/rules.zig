//! Every number the Match rules play by, in one compile-time table: the screen,
//! the Ship and its fire, each Enemy kind, the Waves and their ramp. They come
//! from "What are a Match's rules in Part 1?" (#2) and "Which Enemies and Waves
//! does Part 1 ship?" (#3). Distances are in pixels, durations in Ticks.

/// Ticks per second.
pub const tick_rate = 60;

pub const screen_width = 1280;
pub const screen_height = 720;

/// A hit box: every entity kind has one, about its sprite's size at 2×.
pub const Box = struct { width: f32, height: f32 };

pub const ship = .{
    .box = Box{ .width = 66, .height = 34 }, // a 33x17 sprite
    .speed = 6,
    // Where a Player's Ship appears: x, then y for Player 0, one step lower
    // for each next Player.
    .spawn_x = 64,
    .spawn_y = 90,
    .spawn_step = 160,
};

/// Fixed in Part 1, since they set how many Ship Projectiles a Snapshot holds.
pub const ship_fire = .{
    .every = 12,
    .speed = 16,
    // Ship Projectiles in flight per Ship; at most 7 fit on screen.
    .per_ship = 8,
    .box = Box{ .width = 32, .height = 8 }, // the blue bolt
};

pub const EnemyKind = enum { dart, pod };

pub const Enemy = struct {
    box: Box,
    /// Leftward, per Tick.
    speed: f32,
    hit_points: u8,
    /// Out of 100 Waves.
    share: u8,
    wave_min: u8,
    wave_max: u8,
    /// Between two Enemies of a Wave, left to right.
    spacing: f32,
    /// Of the sine wave a Dart flies on; 0 for a straight line.
    amplitude: f32,
    period: u16,
    /// Ticks between two shots once fully on screen; 0 if it never fires.
    fire_every: u16,
    projectile_speed: f32,
};

pub const enemies = struct {
    pub const dart: Enemy = .{
        .box = .{ .width = 60, .height = 60 }, // 16 frames of about 33x36
        .speed = 4,
        .hit_points = 1,
        .share = 70,
        .wave_min = 4,
        .wave_max = 6,
        .spacing = 80,
        .amplitude = 60,
        .period = 2 * tick_rate,
        .fire_every = 0,
        .projectile_speed = 0,
    };
    pub const pod: Enemy = .{
        .box = .{ .width = 34, .height = 36 }, // 12 frames of about 17x18
        .speed = 2,
        .hit_points = 3,
        .share = 30,
        .wave_min = 1,
        .wave_max = 3,
        .spacing = 80,
        .amplitude = 0,
        .period = 0,
        .fire_every = 2 * tick_rate,
        .projectile_speed = 5,
    };

    pub fn of(comptime kind: EnemyKind) Enemy {
        return @field(enemies, @tagName(kind));
    }
};

pub const enemy_projectile = .{
    .box = Box{ .width = 16, .height = 16 }, // the orange orb
};

pub const waves = .{
    // After the join window closes.
    .first_after = 2 * tick_rate,
    // The interval to the next Wave is drawn in this range...
    .gap_start = .{ 2 * tick_rate, 4 * tick_rate },
    // ...which shrinks linearly to this one over `ramp` Ticks, then holds.
    .gap_end = .{ 1 * tick_rate, 2 * tick_rate },
    .ramp = 3 * 60 * tick_rate,
};

comptime {
    if (enemies.dart.share + enemies.pod.share != 100) @compileError("Wave shares must add up to 100");
}
