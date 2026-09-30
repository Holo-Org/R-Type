//! The Star-field: three layers of procedurally placed stars scrolling left.
//! Nearer layers have bigger, brighter and faster stars, which gives depth.

use engine_client::{Color, Frame, Rect};
use engine_headless::random::Random;

struct Star {
    x: f32,
    y: f32,
}

struct Layer {
    speed: f32, // pixels per second
    size: f32,  // pixels
    color: Color,
    stars: Vec<Star>,
}

pub struct Starfield {
    width: f32,
    layers: [Layer; 3],
}

impl Starfield {
    pub fn new(width: f32, height: f32, seed: u64) -> Self {
        let mut random = Random::new(seed);
        let mut layer = |count, speed, size, color| Layer {
            speed,
            size,
            color,
            stars: (0..count)
                .map(|_| Star {
                    x: random.unit() * width,
                    y: random.unit() * height,
                })
                .collect(),
        };
        let layers = [
            layer(120, 25.0, 1.0, Color::rgb(90, 90, 120)),
            layer(60, 70.0, 2.0, Color::rgb(160, 160, 200)),
            layer(25, 160.0, 3.0, Color::WHITE),
        ];
        Self { width, layers }
    }

    pub fn scroll(&mut self, seconds: f32) {
        for layer in &mut self.layers {
            for star in &mut layer.stars {
                star.x -= layer.speed * seconds;
                if star.x < 0.0 {
                    star.x += self.width;
                }
            }
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        for layer in &self.layers {
            for star in &layer.stars {
                let rect = Rect {
                    x: star.x,
                    y: star.y,
                    width: layer.size,
                    height: layer.size,
                };
                frame.draw_rect(rect, layer.color);
            }
        }
    }
}
