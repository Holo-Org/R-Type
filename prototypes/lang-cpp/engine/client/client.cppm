// Window, drawing, input and sound. raylib stays inside the implementation
// unit (client.cpp): code that imports this module never sees raylib.h.
export module engine.client;

import std;

export namespace engine {

struct Color {
    std::uint8_t r = 0;
    std::uint8_t g = 0;
    std::uint8_t b = 0;
    std::uint8_t a = 255;
};

inline constexpr Color white{255, 255, 255};

struct Rect {
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
};

enum class Key { up, down, left, right, space };

// The window and its graphics context. raylib supports a single window.
class Window {
public:
    // Throws std::runtime_error if no window can be opened.
    Window(int width, int height, std::string_view title, int target_fps = 60);
    ~Window();
    Window(const Window&) = delete;
    Window& operator=(const Window&) = delete;

    [[nodiscard]] bool should_close() const;
    // Seconds taken by the previous Frame.
    [[nodiscard]] float frame_time() const;
    void begin_frame(Color background);
    void end_frame();
    // Saves what has been drawn so far in this Frame; call it before end_frame().
    // The extension picks the format, e.g. ".png".
    bool save_screenshot(std::string_view path) const;
};

[[nodiscard]] bool is_key_down(Key key);
[[nodiscard]] bool is_key_pressed(Key key);

void draw_rect(Rect rect, Color color);
void draw_text(std::string_view text, int x, int y, int size, Color color);

class Texture {
public:
    // Decodes an image file held in memory; `file_type` is its extension,
    // such as ".gif". Needs an open Window. Throws std::runtime_error if the
    // image cannot be decoded.
    Texture(std::string_view file_type, std::span<const unsigned char> file);
    ~Texture();
    Texture(Texture&&) noexcept;
    Texture& operator=(Texture&&) noexcept;

    void draw(Rect source, Rect destination, Color tint = white) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Keeps the default audio output open for as long as it lives.
class AudioDevice {
public:
    AudioDevice();
    ~AudioDevice();
    AudioDevice(const AudioDevice&) = delete;
    AudioDevice& operator=(const AudioDevice&) = delete;

    // False when the machine has no usable audio output; sounds then stay silent.
    [[nodiscard]] bool ready() const;
};

// A short sound built from 16-bit mono PCM samples. Needs an AudioDevice.
class Sound {
public:
    Sound(std::span<const std::int16_t> samples, int sample_rate);
    ~Sound();
    Sound(Sound&&) noexcept;
    Sound& operator=(Sound&&) noexcept;

    void play() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace engine
