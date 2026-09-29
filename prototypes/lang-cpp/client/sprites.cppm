// The Ships' look: one colour per Player, from the provided sprite sheet.
export module client.sprites;

import std;
import engine.client;
import game.match;

// Defined in ship_sheet.c.
extern "C" {
extern const unsigned char ship_sheet_gif[];
extern const std::size_t ship_sheet_gif_size;
}

namespace {

// The sheet is a grid of 33x17 cells: one row per colour, and five frames per
// row, from banking down to banking up; the middle one flies level.
constexpr float cell_width = 33;
constexpr float cell_height = 17;
constexpr float level_frame = 2;

} // namespace

export namespace client {

// Matches the sheet's rows: cyan, magenta, green, red.
inline constexpr std::array<engine::Color, 4> player_colors{{
    {90, 220, 255},
    {255, 120, 255},
    {120, 255, 120},
    {255, 110, 90},
}};

class ShipSprites {
public:
    ShipSprites() : sheet_{".gif", {ship_sheet_gif, ship_sheet_gif_size}} {}

    void draw(std::uint8_t player, float x, float y) const {
        const engine::Rect frame{level_frame * cell_width, player * cell_height, cell_width, cell_height};
        sheet_.draw(frame, {x, y, game::ship_width, game::ship_height});
    }

private:
    engine::Texture sheet_;
};

} // namespace client
