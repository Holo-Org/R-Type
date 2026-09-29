module game.match;

import std;

namespace game {

std::optional<std::uint8_t> Match::join(const engine::Endpoint& peer) {
    if (const auto existing = find(peer)) {
        return existing; // a repeated connect, after a lost accept
    }
    const auto free = std::ranges::find_if(players_, [](const auto& player) { return !player.has_value(); });
    if (free == players_.end()) {
        return std::nullopt;
    }
    const auto index = static_cast<std::uint8_t>(free - players_.begin());
    *free = Player{.peer = peer, .last_heard = tick_, .x = 64, .y = 90 + 160 * index};
    return index;
}

std::optional<std::uint8_t> Match::find(const engine::Endpoint& peer) const {
    for (std::uint8_t i = 0; i < players_.size(); ++i) {
        if (players_[i] && players_[i]->peer == peer) {
            return i;
        }
    }
    return std::nullopt;
}

void Match::leave(std::uint8_t player) {
    players_.at(player).reset();
}

void Match::receive(std::uint8_t player, const Input& input) {
    auto& state = players_.at(player).value();
    state.last_heard = tick_;
    // Datagrams can arrive out of order: never go back to older buttons.
    const auto& newest = input.recent.front();
    if (newest.tick > state.last_input) {
        state.last_input = newest.tick;
        state.buttons = newest.buttons;
    }
}

std::vector<std::uint8_t> Match::step() {
    ++tick_;
    std::vector<std::uint8_t> dropped;
    for (std::uint8_t i = 0; i < players_.size(); ++i) {
        auto& player = players_[i];
        if (!player) {
            continue;
        }
        if (tick_ - player->last_heard > silence_limit) {
            player.reset();
            dropped.push_back(i);
            continue;
        }
        const auto held = [&](std::uint8_t button) { return (player->buttons & button) != 0 ? 1 : 0; };
        const int dx = held(button::right) - held(button::left);
        const int dy = held(button::down) - held(button::up);
        player->x = std::clamp(player->x + dx * ship_speed, 0, world_width - ship_width);
        player->y = std::clamp(player->y + dy * ship_speed, 0, world_height - ship_height);
    }
    return dropped;
}

Snapshot Match::snapshot() const {
    Snapshot snapshot{.tick = tick_};
    for (std::uint8_t i = 0; i < players_.size(); ++i) {
        if (const auto& player = players_[i]) {
            snapshot.ships[snapshot.ship_count++] = {
                .player = i,
                .x = static_cast<std::uint16_t>(player->x),
                .y = static_cast<std::uint16_t>(player->y),
            };
        }
    }
    return snapshot;
}

} // namespace game
