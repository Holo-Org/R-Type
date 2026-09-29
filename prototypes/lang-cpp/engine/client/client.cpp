// Third-party headers go in the global module fragment, before `import std`.
module;

#include <raylib.h>
#include <rlgl.h>

module engine.client;

import std;

namespace engine {

namespace {

::Color to_raylib(Color color) {
    return {color.r, color.g, color.b, color.a};
}

::Rectangle to_raylib(Rect rect) {
    return {rect.x, rect.y, rect.width, rect.height};
}

int to_raylib(Key key) {
    switch (key) {
    case Key::up: return KEY_UP;
    case Key::down: return KEY_DOWN;
    case Key::left: return KEY_LEFT;
    case Key::right: return KEY_RIGHT;
    case Key::space: return KEY_SPACE;
    }
    return KEY_NULL;
}

} // namespace

Window::Window(int width, int height, std::string_view title, int target_fps) {
    SetTraceLogLevel(LOG_WARNING);
    InitWindow(width, height, std::string{title}.c_str());
    if (!IsWindowReady()) {
        throw std::runtime_error{"cannot open a window"};
    }
    SetTargetFPS(target_fps);
}

Window::~Window() {
    CloseWindow();
}

bool Window::should_close() const {
    return WindowShouldClose();
}

float Window::frame_time() const {
    return GetFrameTime();
}

void Window::begin_frame(Color background) {
    BeginDrawing();
    ClearBackground(to_raylib(background));
}

void Window::end_frame() {
    EndDrawing();
}

bool Window::save_screenshot(std::string_view path) const {
    // Flush raylib's batched draws first, as its own screenshot key does.
    rlDrawRenderBatchActive();
    ::Image image = LoadImageFromScreen();
    const bool saved = ExportImage(image, std::string{path}.c_str());
    UnloadImage(image);
    return saved;
}

bool is_key_down(Key key) {
    return IsKeyDown(to_raylib(key));
}

bool is_key_pressed(Key key) {
    return IsKeyPressed(to_raylib(key));
}

void draw_rect(Rect rect, Color color) {
    DrawRectangleRec(to_raylib(rect), to_raylib(color));
}

void draw_text(std::string_view text, int x, int y, int size, Color color) {
    DrawText(std::string{text}.c_str(), x, y, size, to_raylib(color));
}

struct Texture::Impl {
    ::Texture2D texture;
    ~Impl() { UnloadTexture(texture); }
};

Texture::Texture(std::string_view file_type, std::span<const unsigned char> file) {
    ::Image image = LoadImageFromMemory(std::string{file_type}.c_str(), file.data(), static_cast<int>(file.size()));
    if (image.data == nullptr) {
        throw std::runtime_error{"cannot decode image"};
    }
    impl_ = std::make_unique<Impl>(LoadTextureFromImage(image));
    UnloadImage(image);
    if (!IsTextureValid(impl_->texture)) {
        throw std::runtime_error{"cannot upload texture"};
    }
}

Texture::~Texture() = default;
Texture::Texture(Texture&&) noexcept = default;
Texture& Texture::operator=(Texture&&) noexcept = default;

void Texture::draw(Rect source, Rect destination, Color tint) const {
    DrawTexturePro(impl_->texture, to_raylib(source), to_raylib(destination), {0, 0}, 0, to_raylib(tint));
}

AudioDevice::AudioDevice() {
    InitAudioDevice();
}

AudioDevice::~AudioDevice() {
    CloseAudioDevice();
}

bool AudioDevice::ready() const {
    return IsAudioDeviceReady();
}

struct Sound::Impl {
    ::Sound sound;
    ~Impl() { UnloadSound(sound); }
};

Sound::Sound(std::span<const std::int16_t> samples, int sample_rate) {
    const ::Wave wave{
        .frameCount = static_cast<unsigned int>(samples.size()),
        .sampleRate = static_cast<unsigned int>(sample_rate),
        .sampleSize = 16,
        .channels = 1,
        // raylib only reads the samples: it copies them into its own buffer.
        .data = const_cast<std::int16_t*>(samples.data()),
    };
    impl_ = std::make_unique<Impl>(LoadSoundFromWave(wave));
}

Sound::~Sound() = default;
Sound::Sound(Sound&&) noexcept = default;
Sound& Sound::operator=(Sound&&) noexcept = default;

void Sound::play() const {
    PlaySound(impl_->sound);
}

} // namespace engine
