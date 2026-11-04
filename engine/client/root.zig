//! The Engine's client part: window, drawing, input and sound, over raylib
//! (through the raylib-zig bindings).
//!
//! raylib stays behind this module. The Client cannot `@import("raylib")`,
//! since build.zig gives only this module that import, and no public
//! declaration below names a raylib type. Zig has no private fields, though:
//! a field holding a raylib value would hand it, and the raylib functions
//! raylib-zig attaches to its types as methods, to any user of the Engine.
//! Textures and sounds therefore keep raylib's values as plain bytes, and
//! `api_check.zig` fails the build if a raylib type shows up in the public API.

const std = @import("std");
const rl = @import("raylib");

comptime {
    // The files that make up raylib-zig's module "raylib".
    const raylib_files = [_][]const u8{ "raylib", "raylib-ext", "rlgl", "rlgl-ext", "raymath", "raymath-ext" };
    @import("api_check.zig").refuseTypesFrom(&raylib_files, @This());
}

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const white: Color = .rgb(255, 255, 255);
    pub const black: Color = .rgb(0, 0, 0);

    /// An opaque colour.
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// A key, named after where it sits on a US (QWERTY) keyboard, whatever the
/// layout: on an AZERTY keyboard, `.w` is the key marked Z. Escape is left
/// out, since it closes the Window.
pub const Key = enum {
    // zig fmt: off
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    zero, one, two, three, four, five, six, seven, eight, nine,
    up, down, left, right,
    space, enter, tab, backspace,
    left_shift, right_shift, left_control, right_control, left_alt, right_alt,
    comma, period, slash, semicolon, apostrophe, minus, equal,
    // zig fmt: on
};

/// A gamepad button, named after where it sits rather than after its label:
/// `.face_down` is Xbox's A and PlayStation's cross. The left stick counts as
/// four more buttons, held while it is pushed more than half-way.
pub const GamepadButton = enum {
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    face_up,
    face_down,
    face_left,
    face_right,
    left_bumper,
    right_bumper,
    left_trigger,
    right_trigger,
    select,
    start,
    left_stick_press,
    right_stick_press,
    left_stick_up,
    left_stick_down,
    left_stick_left,
    left_stick_right,
};

/// Something a player holds to ask for an Action: a key, or a button on any
/// connected gamepad.
pub const Control = union(enum) {
    key: Key,
    gamepad: GamepadButton,
};

/// For each value of a program's `Action` enum, the Controls that ask for
/// it, any one of them being enough. A settings file can hold it.
pub fn Bindings(comptime Action: type) type {
    return std.enums.EnumFieldStruct(Action, []const Control, null);
}

/// How far a stick must be pushed to count as a held button.
const stick_threshold = 0.5;
/// raylib follows at most this many gamepads.
const max_gamepads = 4;

pub const Error = error{
    /// No window or graphics context could be opened.
    WindowUnavailable,
    /// An image file could not be decoded.
    ImageInvalid,
    /// An image could not be uploaded to the graphics card.
    TextureInvalid,
    /// The machine has no usable audio output.
    AudioUnavailable,
    /// raylib could not build a sound from the samples.
    SoundInvalid,
    /// The screen could not be read, or the file not written.
    ScreenshotFailed,
};

fn toRaylibColor(color: Color) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn toRaylibRect(rect: Rect) rl.Rectangle {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn toRaylibKey(key: Key) rl.KeyboardKey {
    // The Engine's names are raylib's: a renamed key fails to compile here.
    return switch (key) {
        inline else => |k| @field(rl.KeyboardKey, @tagName(k)),
    };
}

fn isGamepadButtonDown(gamepad: i32, button: GamepadButton) bool {
    const pressed: rl.GamepadButton = switch (button) {
        .dpad_up => .left_face_up,
        .dpad_down => .left_face_down,
        .dpad_left => .left_face_left,
        .dpad_right => .left_face_right,
        .face_up => .right_face_up,
        .face_down => .right_face_down,
        .face_left => .right_face_left,
        .face_right => .right_face_right,
        .left_bumper => .left_trigger_1,
        .right_bumper => .right_trigger_1,
        .left_trigger => .left_trigger_2,
        .right_trigger => .right_trigger_2,
        .select => .middle_left,
        .start => .middle_right,
        .left_stick_press => .left_thumb,
        .right_stick_press => .right_thumb,
        // The y axis points down.
        .left_stick_up => return rl.getGamepadAxisMovement(gamepad, .left_y) < -stick_threshold,
        .left_stick_down => return rl.getGamepadAxisMovement(gamepad, .left_y) > stick_threshold,
        .left_stick_left => return rl.getGamepadAxisMovement(gamepad, .left_x) < -stick_threshold,
        .left_stick_right => return rl.getGamepadAxisMovement(gamepad, .left_x) > stick_threshold,
    };
    return rl.isGamepadButtonDown(gamepad, pressed);
}

/// The window and its graphics context. raylib supports a single window.
pub const Window = struct {
    pub fn open(width: i32, height: i32, title: [:0]const u8, target_fps: i32) Error!Window {
        rl.setTraceLogLevel(.warning);
        rl.initWindow(width, height, title);
        if (!rl.isWindowReady()) return error.WindowUnavailable;
        rl.setTargetFPS(target_fps);
        return .{};
    }

    /// Closes the window; unload every Texture first.
    pub fn close(_: *Window) void {
        rl.closeWindow();
    }

    pub fn shouldClose(_: *const Window) bool {
        return rl.windowShouldClose();
    }

    /// Seconds taken by the previous Frame.
    pub fn frameTime(_: *const Window) f32 {
        return rl.getFrameTime();
    }

    /// Whether `control` is held: a key, or a button on any connected gamepad.
    pub fn isDown(_: *const Window, control: Control) bool {
        switch (control) {
            .key => |key| return rl.isKeyDown(toRaylibKey(key)),
            .gamepad => |button| {
                for (0..max_gamepads) |gamepad| {
                    const index: i32 = @intCast(gamepad);
                    if (rl.isGamepadAvailable(index) and isGamepadButtonDown(index, button)) return true;
                }
                return false;
            },
        }
    }

    /// The Actions held during this Frame: those with at least one Control
    /// held in `bindings`.
    pub fn actionsHeld(window: *const Window, comptime Action: type, bindings: Bindings(Action)) std.EnumSet(Action) {
        var held: std.EnumSet(Action) = .empty;
        inline for (comptime std.enums.values(Action)) |action| {
            for (@field(bindings, @tagName(action))) |control| {
                if (window.isDown(control)) {
                    held.insert(action);
                    break;
                }
            }
        }
        return held;
    }

    /// Decodes an image file held in memory, such as one compiled into the
    /// program with `@embedFile`; `file_type` is its extension, such as ".gif".
    pub fn loadTexture(_: *Window, file_type: [:0]const u8, file: []const u8) Error!Texture {
        const image = rl.loadImageFromMemory(file_type, file) catch return error.ImageInvalid;
        defer rl.unloadImage(image);
        const texture = rl.loadTextureFromImage(image) catch return error.TextureInvalid;
        return .{ .raylib_texture = std.mem.toBytes(texture) };
    }

    /// Starts a Frame, cleared to `background`; `Frame.end` shows it.
    pub fn beginFrame(_: *Window, background: Color) Frame {
        rl.beginDrawing();
        rl.clearBackground(toRaylibColor(background));
        return .{};
    }
};

/// One Frame being drawn, from `Window.beginFrame` to `end`.
pub const Frame = struct {
    pub fn drawRect(_: *Frame, rect: Rect, color: Color) void {
        rl.drawRectangleRec(toRaylibRect(rect), toRaylibColor(color));
    }

    /// Draws text in raylib's default font; beyond 255 bytes, it is cut.
    pub fn drawText(_: *Frame, text: []const u8, x: i32, y: i32, size: i32, color: Color) void {
        var buffer: [256]u8 = undefined;
        rl.drawText(terminate(&buffer, text), x, y, size, toRaylibColor(color));
    }

    /// How wide `drawText` draws `text` at `size`, in pixels.
    pub fn measureText(_: *const Frame, text: []const u8, size: i32) i32 {
        var buffer: [256]u8 = undefined;
        return rl.measureText(terminate(&buffer, text), size);
    }

    /// `text`, cut to fit `buffer`, with the zero raylib looks for at its end.
    fn terminate(buffer: *[256]u8, text: []const u8) [:0]const u8 {
        const len = @min(text.len, buffer.len - 1);
        @memcpy(buffer[0..len], text[0..len]);
        buffer[len] = 0;
        return buffer[0..len :0];
    }

    /// Draws the `source` part of `texture` stretched over `destination`.
    pub fn drawTexture(_: *Frame, texture: *const Texture, source: Rect, destination: Rect, tint: Color) void {
        const origin: rl.Vector2 = .{ .x = 0, .y = 0 };
        rl.drawTexturePro(texture.raylib(), toRaylibRect(source), toRaylibRect(destination), origin, 0, toRaylibColor(tint));
    }

    /// Saves what has been drawn so far in this Frame. The file's extension
    /// picks the format, such as ".png".
    pub fn saveScreenshot(_: *Frame, path: [:0]const u8) Error!void {
        // raylib queues draws in a batch: flush it first, as raylib's own
        // screenshot key does, or the image misses part of this Frame.
        rl.gl.rlDrawRenderBatchActive();
        const image = rl.loadImageFromScreen() catch return error.ScreenshotFailed;
        defer rl.unloadImage(image);
        if (!rl.exportImage(image, path)) return error.ScreenshotFailed;
    }

    /// Ends the Frame, which shows it.
    pub fn end(_: *Frame) void {
        rl.endDrawing();
    }
};

/// An image uploaded to the graphics card. Unload it before closing the Window.
pub const Texture = struct {
    /// raylib's value, as bytes: see the top of this file.
    raylib_texture: [@sizeOf(rl.Texture2D)]u8 align(@alignOf(rl.Texture2D)),

    pub fn unload(texture: *const Texture) void {
        rl.unloadTexture(texture.raylib());
    }

    fn raylib(texture: *const Texture) rl.Texture2D {
        return std.mem.bytesToValue(rl.Texture2D, &texture.raylib_texture);
    }
};

/// Keeps the default audio output open until `close`.
pub const AudioDevice = struct {
    pub fn open() Error!AudioDevice {
        rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return error.AudioUnavailable;
        return .{};
    }

    /// Closes the audio output; unload every Sound first.
    pub fn close(_: *AudioDevice) void {
        rl.closeAudioDevice();
    }

    /// A short sound built from 16-bit mono PCM samples.
    pub fn loadSound(_: *AudioDevice, samples: []const i16, sample_rate: u32) Error!Sound {
        const wave: rl.Wave = .{
            .frameCount = @intCast(samples.len),
            .sampleRate = sample_rate,
            .sampleSize = 16,
            .channels = 1,
            // raylib only reads the samples: it copies them into its own buffer.
            .data = @ptrCast(@constCast(samples.ptr)),
        };
        const sound = rl.loadSoundFromWave(wave);
        if (!rl.isSoundValid(sound)) return error.SoundInvalid;
        return .{ .raylib_sound = std.mem.toBytes(sound) };
    }
};

/// A sound held by the audio device. Unload it before closing the device.
pub const Sound = struct {
    /// raylib's value, as bytes: see the top of this file.
    raylib_sound: [@sizeOf(rl.Sound)]u8 align(@alignOf(rl.Sound)),

    pub fn play(sound: *const Sound) void {
        rl.playSound(sound.raylib());
    }

    pub fn unload(sound: *const Sound) void {
        rl.unloadSound(sound.raylib());
    }

    fn raylib(sound: *const Sound) rl.Sound {
        return std.mem.bytesToValue(rl.Sound, &sound.raylib_sound);
    }
};
