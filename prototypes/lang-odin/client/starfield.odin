// The Star-field: three layers of procedurally placed stars scrolling left.
// Nearer layers have bigger, brighter and faster stars, which gives depth.
package main

import engine "../engine/client"
import "../engine/headless"

Star :: struct {
	x, y: f32,
}

Layer :: struct {
	count: int,
	// Pixels per second.
	speed: f32,
	// Pixels.
	size:  f32,
	color: engine.Color,
}

LAYERS :: [3]Layer {
	{count = 120, speed = 25, size = 1, color = {90, 90, 120, 255}},
	{count = 60, speed = 70, size = 2, color = {160, 160, 200, 255}},
	{count = 25, speed = 160, size = 3, color = engine.WHITE},
}

STAR_COUNT :: 120 + 60 + 25

Starfield :: struct {
	width: f32,
	// Every layer's stars, one layer after the other.
	stars: [STAR_COUNT]Star,
}

// Places the stars as the Rust POC does: same generator, seed and order.
make_starfield :: proc(width, height: f32, seed: u64) -> (starfield: Starfield) {
	random := headless.Random{state = seed}
	starfield.width = width
	for &star in starfield.stars {
		star.x = headless.random_unit(&random) * width
		star.y = headless.random_unit(&random) * height
	}
	return
}

scroll_starfield :: proc(starfield: ^Starfield, seconds: f32) {
	stars := starfield.stars[:]
	for layer in LAYERS {
		for &star in stars[:layer.count] {
			star.x -= layer.speed * seconds
			if star.x < 0 {
				star.x += starfield.width
			}
		}
		stars = stars[layer.count:]
	}
}

draw_starfield :: proc(starfield: ^Starfield, frame: ^engine.Frame) {
	stars := starfield.stars[:]
	for layer in LAYERS {
		for star in stars[:layer.count] {
			engine.draw_rect(frame, {star.x, star.y, layer.size, layer.size}, layer.color)
		}
		stars = stars[layer.count:]
	}
}
