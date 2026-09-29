// r-type_client: shows the Match and sends the Player's inputs every Tick.
//
// The Engine's network thread receives the Server's datagrams; the main
// thread drains them every Frame, sends one input per Tick whatever the frame
// rate, and draws the newest snapshot.
import std;
import client.sound;
import client.sprites;
import client.starfield;
import engine.client;
import engine.net;
import engine.time;
import game.match;
import game.protocol;

namespace {

template <class... Handlers>
struct Overloaded : Handlers... {
    using Handlers::operator()...;
};

template <class... Args>
void log(std::format_string<Args...> format, Args&&... args) {
    std::println(std::cerr, format, std::forward<Args>(args)...);
}

struct Options {
    std::string host = "127.0.0.1";
    std::uint16_t port = 4242;
    std::optional<int> script;             // play unattended, following pattern N
    std::optional<int> frames;             // quit after N Frames
    std::optional<std::string> screenshot; // save the last Frame there
};

constexpr std::string_view usage =
    "usage: r-type_client [--host <host>] [--port <port>] [--script <n>] [--frames <n> [--screenshot <file.png>]]";

template <class Number>
bool parse_number(std::string_view text, Number& number) {
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), number);
    return error == std::errc{} && end == text.data() + text.size();
}

std::optional<Options> parse_options(std::span<char* const> args) {
    Options options;
    for (std::size_t i = 1; i + 1 < args.size(); i += 2) {
        const std::string_view name = args[i];
        const std::string_view value = args[i + 1];
        int number = 0;
        bool valid = true;
        if (name == "--host") {
            options.host = value;
        } else if (name == "--port") {
            valid = parse_number(value, options.port);
        } else if (name == "--script") {
            valid = parse_number(value, number);
            options.script = number;
        } else if (name == "--frames") {
            valid = parse_number(value, number) && number > 0;
            options.frames = number;
        } else if (name == "--screenshot") {
            options.screenshot = value;
        } else {
            valid = false;
        }
        if (!valid) {
            return std::nullopt;
        }
    }
    const bool dangling_option = args.size() % 2 == 0;
    if (dangling_option || (options.screenshot && !options.frames)) {
        return std::nullopt;
    }
    return options;
}

std::uint8_t keyboard_buttons() {
    std::uint8_t buttons = 0;
    if (engine::is_key_down(engine::Key::up)) buttons |= game::button::up;
    if (engine::is_key_down(engine::Key::down)) buttons |= game::button::down;
    if (engine::is_key_down(engine::Key::left)) buttons |= game::button::left;
    if (engine::is_key_down(engine::Key::right)) buttons |= game::button::right;
    if (engine::is_key_down(engine::Key::space)) buttons |= game::button::fire;
    return buttons;
}

// Unattended play: every pattern flies a square, starting on a different
// side, and fires every two seconds.
std::uint8_t scripted_buttons(int pattern, std::uint32_t tick) {
    constexpr std::array legs{game::button::right, game::button::down, game::button::left, game::button::up};
    constexpr std::uint32_t leg_ticks = 45;
    std::uint8_t buttons = legs[(tick / leg_ticks + static_cast<std::uint32_t>(pattern)) % legs.size()];
    if (tick % (2 * game::tick_rate) == 0) {
        buttons |= game::button::fire;
    }
    return buttons;
}

// Players are numbered from 1 on screen and in logs; the protocol counts from 0.
void draw_hud(std::optional<std::uint8_t> me, const game::Snapshot& snapshot, const engine::Endpoint& server) {
    if (me) {
        engine::draw_text(std::format("Player {}", *me + 1), 16, 12, 20, client::player_colors.at(*me));
    } else {
        engine::draw_text(std::format("Connecting to {}...", engine::to_string(server)), 16, 12, 20, engine::white);
    }
    const auto players = std::format("{}/{} Players", snapshot.ship_count, game::max_players);
    engine::draw_text(players, game::world_width - 150, 12, 20, engine::white);
}

int run(const Options& options) {
    const auto server = engine::resolve(options.host, options.port);
    if (!server) {
        log("r-type_client: cannot resolve {}", options.host);
        return 1;
    }

    engine::UdpTransport transport;
    engine::Window window{game::world_width, game::world_height, "R-Type"};
    engine::AudioDevice audio;
    const engine::Sound pew{client::synthesize_pew(), client::sample_rate};
    const client::ShipSprites ships;
    client::Starfield starfield{game::world_width, game::world_height};

    std::uint32_t sequence = 0;
    const auto send = [&](const game::Message& message) {
        transport.send(*server, game::encode({.sequence = ++sequence, .message = message}).bytes());
    };

    std::optional<std::uint8_t> me; // our Player index, once accepted
    std::uint32_t server_sequence = 0;
    game::Snapshot latest;
    game::Input input;
    std::uint32_t tick = 0;
    engine::FixedStep ticks{std::chrono::nanoseconds{std::chrono::seconds{1}} / game::tick_rate};
    log("r-type_client: connecting to {}", engine::to_string(*server));

    for (int frame = 1; !window.should_close(); ++frame) {
        for (const auto& datagram : transport.receive()) {
            if (datagram.from != *server) {
                continue;
            }
            const auto packet = game::decode(datagram.bytes);
            if (!packet || packet->sequence <= server_sequence) {
                continue; // malformed, or overtaken by a newer datagram
            }
            server_sequence = packet->sequence;
            bool rejected = false;
            std::visit(Overloaded{
                           [&](const game::Accept& accept) {
                               if (me != accept.player) {
                                   log("Joined the Match as Player {}", accept.player + 1);
                               }
                               me = accept.player;
                           },
                           [&](const game::Reject&) { rejected = true; },
                           [&](const game::Snapshot& snapshot) { latest = snapshot; },
                           [&](const game::PlayerLeft& left) {
                               log("Player {} left the Match", left.player + 1);
                               if (left.player == me) {
                                   me.reset(); // dropped by the Server: connect again
                               }
                           },
                           [](const auto&) {}, // messages only Clients send
                       },
                       packet->message);
            if (rejected) {
                log("r-type_client: the Match is full");
                return 1;
            }
        }

        for (int due = ticks.poll(); due > 0; --due) {
            ++tick;
            const auto buttons = options.script ? scripted_buttons(*options.script, tick) : keyboard_buttons();
            const auto previous = input.recent.front().buttons;
            std::shift_right(input.recent.begin(), input.recent.end(), 1);
            input.recent.front() = {tick, buttons};
            if ((buttons & ~previous & game::button::fire) != 0) {
                pew.play();
            }
            if (me) {
                send(input);
            } else if (tick % (game::tick_rate / 2) == 1) {
                send(game::Connect{}); // twice a second, until the Server answers
            }
        }

        starfield.scroll(window.frame_time());
        window.begin_frame({0, 0, 0});
        starfield.draw();
        for (const auto& ship : std::span{latest.ships}.first(latest.ship_count)) {
            ships.draw(ship.player, ship.x, ship.y);
        }
        draw_hud(me, latest, *server);
        const bool last_frame = options.frames && frame >= *options.frames;
        if (last_frame && options.screenshot) {
            if (window.save_screenshot(*options.screenshot)) {
                log("r-type_client: saved {}", *options.screenshot);
            } else {
                log("r-type_client: could not save {}", *options.screenshot);
            }
        }
        window.end_frame();
        if (last_frame) {
            break;
        }
    }

    if (me) {
        send(game::Disconnect{});
    }
    return 0;
}

} // namespace

int main(int argc, char* argv[]) {
    const auto options = parse_options({argv, static_cast<std::size_t>(argc)});
    if (!options) {
        log("{}", usage);
        return 2;
    }
    try {
        return run(*options);
    } catch (const std::exception& error) {
        log("r-type_client: {}", error.what());
        return 1;
    }
}
