// r-type_server: runs one Match for up to four Players.
// Players are numbered from 1 in logs; the protocol counts from 0.
//
// Two threads: the Engine's network thread receives datagrams into the
// transport's inbox, and the main thread runs the 60 Hz Tick loop, which
// drains the inbox, advances the Match and sends every Player a snapshot.
import std;
import engine.net;
import engine.time;
import game.match;
import game.protocol;

namespace {

template <class... Handlers>
struct Overloaded : Handlers... {
    using Handlers::operator()...;
};

// std::cerr flushes every line, so logs show up at once even when redirected.
template <class... Args>
void log(std::format_string<Args...> format, Args&&... args) {
    std::println(std::cerr, format, std::forward<Args>(args)...);
}

struct Options {
    std::uint16_t port = 4242;
};

std::optional<Options> parse_options(std::span<char* const> args) {
    Options options;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const std::string_view arg = args[i];
        if (arg == "--port" && i + 1 < args.size()) {
            const std::string_view value = args[++i];
            const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), options.port);
            if (error != std::errc{} || end != value.data() + value.size()) {
                return std::nullopt;
            }
        } else {
            return std::nullopt;
        }
    }
    return options;
}

class Server {
public:
    explicit Server(std::uint16_t port) : transport_{port} {}

    [[nodiscard]] std::uint16_t port() const { return transport_.local_port(); }

    void tick() {
        for (const auto& datagram : transport_.receive()) {
            handle(datagram);
        }
        for (const auto player : match_.step()) {
            log("Tick {}: Player {} timed out", match_.tick(), player + 1);
            tell_everyone(game::PlayerLeft{player});
        }
        tell_everyone(match_.snapshot());
        if (match_.tick() % (5 * game::tick_rate) == 0) {
            report();
        }
    }

private:
    void handle(const engine::Datagram& datagram) {
        ++received_;
        const auto packet = game::decode(datagram.bytes);
        if (!packet) {
            ++malformed_;
            return;
        }
        const auto player = match_.find(datagram.from);
        std::visit(Overloaded{
                       [&](const game::Connect&) { connect(datagram.from); },
                       [&](const game::Input& input) {
                           if (player) {
                               match_.receive(*player, input);
                           } else {
                               ++ignored_;
                           }
                       },
                       [&](const game::Disconnect&) {
                           if (player) {
                               leave(*player);
                           } else {
                               ++ignored_;
                           }
                       },
                       [&](const auto&) { ++ignored_; }, // messages only the Server sends
                   },
                   packet->message);
    }

    void connect(const engine::Endpoint& peer) {
        const bool known = match_.find(peer).has_value();
        const auto player = match_.join(peer);
        if (!player) {
            send(peer, game::Reject{game::RejectReason::match_full});
            return;
        }
        if (!known) {
            log("Tick {}: Player {} joined from {}", match_.tick(), *player + 1, engine::to_string(peer));
        }
        send(peer, game::Accept{*player});
    }

    void leave(std::uint8_t player) {
        match_.leave(player);
        log("Tick {}: Player {} left", match_.tick(), player + 1);
        tell_everyone(game::PlayerLeft{player});
    }

    void send(const engine::Endpoint& to, const game::Message& message) {
        transport_.send(to, game::encode({.sequence = ++sequence_, .message = message}).bytes());
    }

    void tell_everyone(const game::Message& message) {
        for (const auto& player : match_.players()) {
            if (player) {
                send(player->peer, message);
            }
        }
    }

    void report() const {
        const auto players = std::ranges::count_if(match_.players(), [](const auto& player) { return player.has_value(); });
        log("Tick {}: {} Players, {} datagrams received, {} malformed, {} ignored, {} dropped by the transport",
            match_.tick(), players, received_, malformed_, ignored_, transport_.dropped());
    }

    engine::UdpTransport transport_;
    game::Match match_;
    std::uint32_t sequence_ = 0;
    std::size_t received_ = 0;
    std::size_t malformed_ = 0;
    std::size_t ignored_ = 0;
};

} // namespace

int main(int argc, char* argv[]) {
    const auto options = parse_options({argv, static_cast<std::size_t>(argc)});
    if (!options) {
        log("usage: r-type_server [--port <port>]");
        return 2;
    }
    try {
        Server server{options->port};
        log("r-type_server: listening on UDP port {}, {} Ticks per second", server.port(), game::tick_rate);
        engine::FixedStep ticks{std::chrono::nanoseconds{std::chrono::seconds{1}} / game::tick_rate};
        for (;;) {
            for (int due = ticks.wait(); due > 0; --due) {
                server.tick();
            }
        }
    } catch (const std::exception& error) {
        log("r-type_server: {}", error.what());
        return 1;
    }
}
