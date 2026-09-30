//! The Engine's client part: window, drawing, input and sound, over raylib.
//!
//! raylib stays behind this crate: no public item below names a raylib type,
//! so the Client program never sees one, and it could not `use raylib` anyway
//! without declaring the dependency itself. Like the raylib crate, this API
//! ties resources to their owners through the borrow checker where it can: a
//! [`Frame`] borrows its [`Window`], and a [`Sound`] its [`AudioDevice`].

use std::fmt;
use std::path::Path;

use raylib::prelude::{self as rl, RaylibDraw, RaylibScissorModeExt};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const WHITE: Self = Self::rgb(255, 255, 255);
    pub const BLACK: Self = Self::rgb(0, 0, 0);

    /// An opaque colour.
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Up,
    Down,
    Left,
    Right,
    Space,
}

/// What failed, with raylib's explanation.
#[derive(Debug)]
pub enum Error {
    Image(String),
    Texture(String),
    Audio(String),
    Sound(String),
    Screenshot(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Image(why) => write!(f, "cannot decode image: {why}"),
            Self::Texture(why) => write!(f, "cannot upload texture: {why}"),
            Self::Audio(why) => write!(f, "cannot open the audio output: {why}"),
            Self::Sound(why) => write!(f, "cannot load sound: {why}"),
            Self::Screenshot(why) => write!(f, "cannot save screenshot: {why}"),
        }
    }
}

impl std::error::Error for Error {}

// Conversions to raylib's types stay private functions: a public `From` impl
// would be part of this crate's API.

fn to_raylib_color(color: Color) -> rl::Color {
    rl::Color::new(color.r, color.g, color.b, color.a)
}

fn to_raylib_rect(rect: Rect) -> rl::Rectangle {
    rl::Rectangle::new(rect.x, rect.y, rect.width, rect.height)
}

fn to_raylib_key(key: Key) -> rl::KeyboardKey {
    match key {
        Key::Up => rl::KeyboardKey::KEY_UP,
        Key::Down => rl::KeyboardKey::KEY_DOWN,
        Key::Left => rl::KeyboardKey::KEY_LEFT,
        Key::Right => rl::KeyboardKey::KEY_RIGHT,
        Key::Space => rl::KeyboardKey::KEY_SPACE,
    }
}

/// The window and its graphics context. raylib supports a single window.
pub struct Window {
    handle: rl::RaylibHandle,
    // Proof that we are on the thread that opened the window: raylib's
    // drawing calls take it, and the type cannot be sent to another thread.
    thread: rl::RaylibThread,
}

impl Window {
    /// Opens the window. Panics if it cannot: the raylib crate reports that
    /// failure with a panic, not an error value.
    pub fn open(width: i32, height: i32, title: &str, target_fps: u32) -> Self {
        let (mut handle, thread) = rl::init()
            .size(width, height)
            .title(title)
            .log_level(rl::TraceLogLevel::LOG_WARNING)
            .build();
        handle.set_target_fps(target_fps);
        Self { handle, thread }
    }

    pub fn should_close(&self) -> bool {
        self.handle.window_should_close()
    }

    /// Seconds taken by the previous Frame.
    pub fn frame_time(&self) -> f32 {
        self.handle.get_frame_time()
    }

    pub fn is_key_down(&self, key: Key) -> bool {
        self.handle.is_key_down(to_raylib_key(key))
    }

    /// Decodes an image file held in memory, such as one compiled into the
    /// program with `include_bytes!`; `file_type` is its extension, such as
    /// ".gif".
    pub fn load_texture(&mut self, file_type: &str, file: &[u8]) -> Result<Texture, Error> {
        let image = rl::Image::load_image_from_mem(file_type, file)
            .map_err(|error| Error::Image(error.to_string()))?;
        let texture = self
            .handle
            .load_texture_from_image(&self.thread, &image)
            .map_err(|error| Error::Texture(error.to_string()))?;
        Ok(Texture(texture))
    }

    /// Starts a Frame, cleared to `background`. The Frame is shown when the
    /// returned value is dropped, and until then the window is borrowed: it
    /// cannot start a second Frame or close in the middle of this one.
    pub fn begin_frame(&mut self, background: Color) -> Frame<'_> {
        let mut draw = self.handle.begin_drawing(&self.thread);
        draw.clear_background(to_raylib_color(background));
        Frame {
            draw,
            thread: &self.thread,
        }
    }
}

/// One Frame being drawn; dropping it ends the Frame and shows it.
pub struct Frame<'w> {
    draw: rl::RaylibDrawHandle<'w>,
    thread: &'w rl::RaylibThread,
}

impl Frame<'_> {
    pub fn draw_rect(&mut self, rect: Rect, color: Color) {
        self.draw
            .draw_rectangle_rec(to_raylib_rect(rect), to_raylib_color(color));
    }

    pub fn draw_text(&mut self, text: &str, x: i32, y: i32, size: i32, color: Color) {
        let color = to_raylib_color(color);
        self.draw.draw_text(text, x, y, size, color);
    }

    /// Draws the `source` part of `texture` stretched over `destination`.
    pub fn draw_texture(
        &mut self,
        texture: &Texture,
        source: Rect,
        destination: Rect,
        tint: Color,
    ) {
        self.draw.draw_texture_pro(
            &texture.0,
            to_raylib_rect(source),
            to_raylib_rect(destination),
            rl::Vector2::ZERO,
            0.0,
            to_raylib_color(tint),
        );
    }

    /// Saves what has been drawn so far in this Frame. The file's extension
    /// picks the format, such as ".png".
    pub fn save_screenshot(&mut self, path: &Path) -> Result<(), Error> {
        let file_type = match path.extension().and_then(|extension| extension.to_str()) {
            Some(extension) => format!(".{extension}"),
            None => return Err(Error::Screenshot("the file name has no extension".into())),
        };
        // raylib queues draws in a batch: flush it, or the screen misses part
        // of this Frame. rlDrawRenderBatchActive would need `unsafe`; entering
        // and leaving a scissor mode flushes the batch too, through the safe API.
        let (width, height) = (self.draw.get_screen_width(), self.draw.get_screen_height());
        self.draw.draw_scissor_mode(0, 0, width, height, |_| {});
        let image = self.draw.load_image_from_screen(self.thread);
        let file = image
            .export_image_to_memory(&file_type)
            .map_err(|error| Error::Screenshot(error.to_string()))?;
        std::fs::write(path, &*file).map_err(|error| Error::Screenshot(error.to_string()))
    }
}

/// An image uploaded to the graphics card. The Window must still be open when
/// it is dropped: keep it in a variable declared after the Window.
pub struct Texture(rl::Texture2D);

/// Keeps the default audio output open for as long as it lives.
pub struct AudioDevice(rl::RaylibAudio);

impl AudioDevice {
    /// Opens the default audio output; fails when the machine has none.
    pub fn open() -> Result<Self, Error> {
        rl::RaylibAudio::init_audio_device()
            .map(Self)
            .map_err(|error| Error::Audio(error.to_string()))
    }

    /// A short sound built from 16-bit mono PCM samples. It borrows the
    /// device, so the compiler rejects any use of it after the device closes.
    pub fn load_sound(&self, samples: &[i16], sample_rate: u32) -> Result<Sound<'_>, Error> {
        let wave = self
            .0
            .new_wave_from_memory(".wav", &wav_file(samples, sample_rate))
            .map_err(|error| Error::Sound(error.to_string()))?;
        let sound = self
            .0
            .new_sound_from_wave(&wave)
            .map_err(|error| Error::Sound(error.to_string()))?;
        Ok(Sound(sound))
    }
}

pub struct Sound<'a>(rl::Sound<'a>);

impl Sound<'_> {
    pub fn play(&self) {
        self.0.play();
    }
}

/// A RIFF/WAVE file holding `samples` as 16-bit mono PCM: the raylib crate
/// has no safe way to take raw samples, but it decodes WAV files from memory.
fn wav_file(samples: &[i16], sample_rate: u32) -> Vec<u8> {
    const HEADER_SIZE: usize = 44;
    let data_size = u32::try_from(2 * samples.len()).unwrap_or(u32::MAX);
    let mut file = Vec::with_capacity(HEADER_SIZE + 2 * samples.len());
    file.extend_from_slice(b"RIFF");
    file.extend_from_slice(&data_size.saturating_add(36).to_le_bytes()); // size of what follows
    file.extend_from_slice(b"WAVEfmt ");
    file.extend_from_slice(&16u32.to_le_bytes()); // size of the format chunk
    file.extend_from_slice(&1u16.to_le_bytes()); // integer PCM
    file.extend_from_slice(&1u16.to_le_bytes()); // mono
    file.extend_from_slice(&sample_rate.to_le_bytes());
    file.extend_from_slice(&sample_rate.saturating_mul(2).to_le_bytes()); // bytes per second
    file.extend_from_slice(&2u16.to_le_bytes()); // bytes per sample
    file.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    file.extend_from_slice(b"data");
    file.extend_from_slice(&data_size.to_le_bytes());
    for sample in samples {
        file.extend_from_slice(&sample.to_le_bytes());
    }
    file
}
