// The Star-field: three layers of procedurally placed stars scrolling left.
// Nearer layers have bigger, brighter and faster stars, which gives depth.
export module client.starfield;

import std;
import engine.client;

export namespace client {

class Starfield {
public:
    Starfield(float width, float height, std::uint32_t seed = 2026) : width_{width} {
        std::mt19937 random{seed};
        std::uniform_real_distribution<float> across{0, width};
        std::uniform_real_distribution<float> down{0, height};
        for (auto& layer : layers_) {
            layer.stars.resize(layer.count);
            for (auto& star : layer.stars) {
                star = {across(random), down(random)};
            }
        }
    }

    void scroll(float seconds) {
        for (auto& layer : layers_) {
            for (auto& star : layer.stars) {
                star.x -= layer.speed * seconds;
                if (star.x < 0) {
                    star.x += width_;
                }
            }
        }
    }

    void draw() const {
        for (const auto& layer : layers_) {
            for (const auto& star : layer.stars) {
                engine::draw_rect({star.x, star.y, layer.size, layer.size}, layer.color);
            }
        }
    }

private:
    struct Star {
        float x;
        float y;
    };

    struct Layer {
        std::size_t count;
        float speed; // pixels per second
        float size;  // pixels
        engine::Color color;
        std::vector<Star> stars{};
    };

    float width_;
    std::array<Layer, 3> layers_{{
        {.count = 120, .speed = 25, .size = 1, .color = {90, 90, 120}},
        {.count = 60, .speed = 70, .size = 2, .color = {160, 160, 200}},
        {.count = 25, .speed = 160, .size = 3, .color = {255, 255, 255}},
    }};
};

} // namespace client
