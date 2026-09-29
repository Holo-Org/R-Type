// Throws random and mutated datagrams at the protocol decoder, which must
// never crash, never allocate, and reject anything but well-formed packets.
// Built in asan mode (xmake f -m asan), AddressSanitizer and
// UndefinedBehaviorSanitizer watch every access it makes.
//
// usage: protocol_fuzz [datagrams [seed]]
import std;
import game.protocol;

namespace {

// Counts every heap allocation in the program; see operator new below.
std::size_t allocations = 0;

using Bytes = std::vector<std::byte>;

game::Message random_message(std::mt19937& random) {
    const auto player = [&] { return static_cast<std::uint8_t>(random() % game::max_players); };
    switch (random() % 7) {
    case 0: return game::Connect{};
    case 1: return game::Accept{player()};
    case 2: return game::Reject{game::RejectReason::match_full};
    case 3: {
        game::Input input;
        std::uint32_t tick = random();
        for (auto& state : input.recent) {
            state = {tick, static_cast<std::uint8_t>(random() & game::button::all)};
            tick -= std::min<std::uint32_t>(tick, random() % 3);
        }
        return input;
    }
    case 4: {
        game::Snapshot snapshot{.tick = static_cast<std::uint32_t>(random())};
        snapshot.ship_count = static_cast<std::uint8_t>(random() % (game::max_players + 1));
        std::array<std::uint8_t, game::max_players> players{0, 1, 2, 3};
        std::ranges::shuffle(players, random);
        for (std::size_t i = 0; i < snapshot.ship_count; ++i) {
            snapshot.ships[i] = {players[i], static_cast<std::uint16_t>(random()), static_cast<std::uint16_t>(random())};
        }
        return snapshot;
    }
    case 5: return game::Disconnect{};
    default: return game::PlayerLeft{player()};
    }
}

// One to three mutations: flip a bit, overwrite a byte, truncate, or append.
void mutate(Bytes& bytes, std::mt19937& random) {
    for (auto count = 1 + random() % 3; count > 0; --count) {
        switch (random() % 4) {
        case 0:
            if (!bytes.empty()) {
                bytes[random() % bytes.size()] ^= std::byte{1} << (random() % 8);
            }
            break;
        case 1:
            if (!bytes.empty()) {
                bytes[random() % bytes.size()] = static_cast<std::byte>(random());
            }
            break;
        case 2: bytes.resize(random() % (bytes.size() + 1)); break;
        default:
            for (auto extra = 1 + random() % 8; extra > 0; --extra) {
                bytes.push_back(static_cast<std::byte>(random()));
            }
        }
    }
}

std::optional<std::uint64_t> parse_number(std::string_view text) {
    std::uint64_t number = 0;
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), number);
    if (error != std::errc{} || end != text.data() + text.size()) {
        return std::nullopt;
    }
    return number;
}

} // namespace

// Replaces the global allocation functions, to count calls.
void* operator new(std::size_t size) {
    ++allocations;
    if (void* memory = std::malloc(size == 0 ? 1 : size)) {
        return memory;
    }
    throw std::bad_alloc{};
}

void operator delete(void* memory) noexcept {
    std::free(memory);
}

void operator delete(void* memory, std::size_t) noexcept {
    std::free(memory);
}

int main(int argc, char* argv[]) {
    const std::span args{argv, static_cast<std::size_t>(argc)};
    const auto count = args.size() > 1 ? parse_number(args[1]) : 100'000;
    const auto seed = args.size() > 2 ? parse_number(args[2]) : std::random_device{}();
    if (!count || !seed || args.size() > 3) {
        std::println(std::cerr, "usage: protocol_fuzz [datagrams [seed]]");
        return 2;
    }
    std::mt19937 random{static_cast<std::uint32_t>(*seed)};
    std::println("protocol_fuzz: seed {}", *seed);

    // Whatever encode() writes, decode() must read back unchanged.
    constexpr int round_trips = 10'000;
    int mismatches = 0;
    for (int i = 0; i < round_trips; ++i) {
        const game::Packet packet{static_cast<std::uint32_t>(random()), random_message(random)};
        const auto decoded = game::decode(game::encode(packet).bytes());
        if (!decoded || *decoded != packet) {
            ++mismatches;
        }
    }
    std::println("round trip: {} packets, {} mismatches", round_trips, mismatches);

    // Half pure noise of any length up to 1500 bytes, half mutated valid packets.
    std::array<std::size_t, game::decode_error_count> rejected{};
    std::size_t accepted = 0;
    std::size_t decoder_allocations = 0;
    Bytes datagram;
    datagram.reserve(2048);
    for (std::uint64_t i = 0; i < *count; ++i) {
        if (i % 2 == 0) {
            datagram.resize(random() % 1501);
            std::ranges::generate(datagram, [&] { return static_cast<std::byte>(random()); });
        } else {
            const auto encoded = game::encode({static_cast<std::uint32_t>(random()), random_message(random)});
            datagram.assign(encoded.bytes().begin(), encoded.bytes().end());
            mutate(datagram, random);
        }
        const auto before = allocations;
        const auto packet = game::decode(datagram);
        decoder_allocations += allocations - before;
        if (packet) {
            ++accepted;
        } else {
            ++rejected[std::to_underlying(packet.error())];
        }
    }

    const auto total_rejected = std::ranges::fold_left(rejected, std::size_t{0}, std::plus{});
    std::println("fuzz: {} datagrams, {} rejected, {} accepted, {} allocations in decode()",
                 *count, total_rejected, accepted, decoder_allocations);
    for (std::size_t error = 0; error < rejected.size(); ++error) {
        std::println("  {:>7} {}", rejected[error], game::to_string(game::DecodeError{static_cast<std::uint8_t>(error)}));
    }
    return mismatches == 0 && decoder_allocations == 0 ? 0 : 1;
}
