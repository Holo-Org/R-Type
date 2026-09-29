// The rules of a Match: who plays, how Ships move, when a silent Player is dropped.
export module game.match;

import std;
import engine.net;
import game.protocol;

export namespace game {

inline constexpr int world_width = 1280;
inline constexpr int world_height = 720;
// A 33x17 sprite drawn at twice its size.
inline constexpr int ship_width = 66;
inline constexpr int ship_height = 34;
inline constexpr int ship_speed = 6; // pixels per Tick
inline constexpr int tick_rate = 60; // Ticks per second
inline constexpr std::uint32_t silence_limit = 3 * tick_rate; // Ticks

class Match {
public:
    struct Player {
        engine::Endpoint peer;
        std::uint32_t last_heard = 0; // Server Tick of the Player's last packet
        std::uint32_t last_input = 0; // Client Tick of the newest input applied
        std::uint8_t buttons = 0;
        int x = 0;
        int y = 0;
    };

    // The Player index of `peer`, joining it if it is new; nullopt if the Match is full.
    std::optional<std::uint8_t> join(const engine::Endpoint& peer);
    [[nodiscard]] std::optional<std::uint8_t> find(const engine::Endpoint& peer) const;
    void leave(std::uint8_t player);
    // Records the newest buttons held by a Player; also proves it is alive.
    void receive(std::uint8_t player, const Input& input);
    // Advances one Tick: moves every Ship, then drops and returns the Players
    // who have been silent for longer than silence_limit.
    std::vector<std::uint8_t> step();

    [[nodiscard]] Snapshot snapshot() const;
    [[nodiscard]] std::uint32_t tick() const { return tick_; }
    [[nodiscard]] const std::array<std::optional<Player>, max_players>& players() const { return players_; }

private:
    std::array<std::optional<Player>, max_players> players_;
    std::uint32_t tick_ = 0;
};

} // namespace game
