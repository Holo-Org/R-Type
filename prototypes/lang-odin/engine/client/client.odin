// The Engine's client part: window, drawing, input and sound, over raylib
// (`vendor:raylib`, which comes with the compiler).
//
// raylib stays behind this package. No public declaration names a raylib
// type: Odin has no private struct fields, so `Texture` and `Sound` copy
// raylib's handles into plain fields, and the conversions are `@(private)`.
// `scripts/check_layering` fails the build if a public declaration of this
// package mentions raylib, and if any other package imports it.
package client

import "base:intrinsics"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The raylib release this Engine is written against, as odin.lock records it:
// an Odin upgrade that brings another one stops the build here.
#assert(rl.VERSION == "6.0" && rlgl.VERSION == "6.0", "vendor:raylib is not the raylib 6.0 recorded in odin.lock")

Color :: struct {
	r, g, b, a: u8,
}

WHITE :: Color{255, 255, 255, 255}
BLACK :: Color{0, 0, 0, 255}

Rect :: struct {
	x, y, width, height: f32,
}

Key :: enum {
	Up,
	Down,
	Left,
	Right,
	Space,
}

Error :: enum {
	None,
	// No window or graphics context could be opened.
	Window_Unavailable,
	// An image file could not be decoded.
	Image_Invalid,
	// An image could not be uploaded to the graphics card.
	Texture_Invalid,
	// The machine has no usable audio output.
	Audio_Unavailable,
	// raylib could not build a sound from the samples.
	Sound_Invalid,
	// The screen could not be read, or the file not written.
	Screenshot_Failed,
}

// The window and its graphics context. raylib supports a single window.
Window :: struct {}

open_window :: proc(width, height: i32, title: cstring, target_fps: i32) -> (window: Window, err: Error) {
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(width, height, title)
	if !rl.IsWindowReady() {
		return {}, .Window_Unavailable
	}
	rl.SetTargetFPS(target_fps)
	return {}, .None
}

// Closes the window; unload every Texture first.
close_window :: proc(_: ^Window) {
	rl.CloseWindow()
}

should_close :: proc(_: ^Window) -> bool {
	return rl.WindowShouldClose()
}

// Seconds taken by the previous Frame.
frame_time :: proc(_: ^Window) -> f32 {
	return rl.GetFrameTime()
}

is_key_down :: proc(_: ^Window, key: Key) -> bool {
	return rl.IsKeyDown(to_raylib_key(key))
}

// Decodes an image file held in memory, such as one compiled into the program
// with `#load`; `file_type` is its extension, such as ".gif".
load_texture :: proc(_: ^Window, file_type: cstring, file: []byte) -> (texture: Texture, err: Error) {
	image := rl.LoadImageFromMemory(file_type, raw_data(file), i32(len(file)))
	if !rl.IsImageValid(image) {
		return {}, .Image_Invalid
	}
	defer rl.UnloadImage(image)
	loaded := rl.LoadTextureFromImage(image)
	if !rl.IsTextureValid(loaded) {
		return {}, .Texture_Invalid
	}
	return from_raylib_texture(loaded), .None
}

// One Frame being drawn, from `begin_frame` to `end_frame`.
Frame :: struct {}

// Starts a Frame, cleared to `background`; `end_frame` shows it.
begin_frame :: proc(_: ^Window, background: Color) -> Frame {
	rl.BeginDrawing()
	rl.ClearBackground(to_raylib_color(background))
	return {}
}

draw_rect :: proc(_: ^Frame, rect: Rect, color: Color) {
	rl.DrawRectangleRec(to_raylib_rect(rect), to_raylib_color(color))
}

// Draws text in raylib's default font; beyond 255 bytes, it is cut.
draw_text :: proc(_: ^Frame, text: string, x, y, size: i32, color: Color) {
	terminated: [256]byte
	n := copy(terminated[:len(terminated) - 1], text)
	terminated[n] = 0
	rl.DrawText(cstring(raw_data(terminated[:])), x, y, size, to_raylib_color(color))
}

// Draws the `source` part of `texture` stretched over `destination`.
draw_texture :: proc(_: ^Frame, texture: Texture, source, destination: Rect, tint: Color) {
	rl.DrawTexturePro(to_raylib_texture(texture), to_raylib_rect(source), to_raylib_rect(destination), {0, 0}, 0, to_raylib_color(tint))
}

// Saves what has been drawn so far in this Frame. The file's extension picks
// the format, such as ".png".
save_screenshot :: proc(_: ^Frame, path: string) -> Error {
	// raylib queues draws in a batch: flush it first, as raylib's own
	// screenshot key does, or the image misses part of this Frame.
	rlgl.DrawRenderBatchActive()
	image := rl.LoadImageFromScreen()
	if !rl.IsImageValid(image) {
		return .Screenshot_Failed
	}
	defer rl.UnloadImage(image)
	terminated: [1024]byte
	if len(path) >= len(terminated) {
		return .Screenshot_Failed
	}
	copy(terminated[:], path)
	if !rl.ExportImage(image, cstring(raw_data(terminated[:]))) {
		return .Screenshot_Failed
	}
	return .None
}

// Ends the Frame, which shows it.
end_frame :: proc(_: ^Frame) {
	rl.EndDrawing()
}

// An image uploaded to the graphics card. Unload it before closing the Window.
// The fields copy raylib's handle: see the top of this file.
Texture :: struct {
	id:                              u32,
	width, height, mipmaps, format: i32,
}

unload_texture :: proc(texture: Texture) {
	rl.UnloadTexture(to_raylib_texture(texture))
}

// Keeps the default audio output open until `close_audio`.
Audio_Device :: struct {}

open_audio :: proc() -> (device: Audio_Device, err: Error) {
	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() {
		return {}, .Audio_Unavailable
	}
	return {}, .None
}

// Closes the audio output; unload every Sound first.
close_audio :: proc(_: ^Audio_Device) {
	rl.CloseAudioDevice()
}

// A short sound built from 16-bit mono PCM samples. raylib copies them.
load_sound :: proc(_: ^Audio_Device, samples: []i16, sample_rate: u32) -> (sound: Sound, err: Error) {
	wave := rl.Wave {
		frameCount = u32(len(samples)),
		sampleRate = sample_rate,
		sampleSize = 16,
		channels   = 1,
		data       = raw_data(samples),
	}
	loaded := rl.LoadSoundFromWave(wave)
	if !rl.IsSoundValid(loaded) {
		return {}, .Sound_Invalid
	}
	return from_raylib_sound(loaded), .None
}

// A sound held by the audio device. Unload it before closing the device. The
// fields copy raylib's handle: see the top of this file.
Sound :: struct {
	buffer, processor:                                   rawptr,
	sample_rate, sample_size, channels, frame_count: u32,
}

play_sound :: proc(sound: Sound) {
	rl.PlaySound(to_raylib_sound(sound))
}

unload_sound :: proc(sound: Sound) {
	rl.UnloadSound(to_raylib_sound(sound))
}

@(private)
to_raylib_color :: proc(color: Color) -> rl.Color {
	return {color.r, color.g, color.b, color.a}
}

@(private)
to_raylib_rect :: proc(rect: Rect) -> rl.Rectangle {
	return {rect.x, rect.y, rect.width, rect.height}
}

@(private)
to_raylib_key :: proc(key: Key) -> rl.KeyboardKey {
	switch key {
	case .Up:    return .UP
	case .Down:  return .DOWN
	case .Left:  return .LEFT
	case .Right: return .RIGHT
	case .Space: return .SPACE
	}
	return .KEY_NULL
}

@(private)
to_raylib_texture :: proc(texture: Texture) -> rl.Texture2D {
	return {texture.id, texture.width, texture.height, texture.mipmaps, rl.PixelFormat(texture.format)}
}

@(private)
from_raylib_texture :: proc(texture: rl.Texture2D) -> Texture {
	return {texture.id, texture.width, texture.height, texture.mipmaps, i32(texture.format)}
}

@(private)
to_raylib_sound :: proc(sound: Sound) -> rl.Sound {
	return {
		stream = {
			buffer = sound.buffer,
			processor = sound.processor,
			sampleRate = sound.sample_rate,
			sampleSize = sound.sample_size,
			channels = sound.channels,
		},
		frameCount = sound.frame_count,
	}
}

@(private)
from_raylib_sound :: proc(sound: rl.Sound) -> Sound {
	return {
		buffer      = sound.buffer,
		processor   = sound.processor,
		sample_rate = sound.sampleRate,
		sample_size = sound.sampleSize,
		channels    = sound.channels,
		frame_count = sound.frameCount,
	}
}

// The copies hold every field: a raylib upgrade that adds one stops the build.
#assert(intrinsics.type_struct_field_count(rl.Texture2D) == 5)
#assert(intrinsics.type_struct_field_count(rl.Sound) == 2)
#assert(intrinsics.type_struct_field_count(rl.AudioStream) == 5)
