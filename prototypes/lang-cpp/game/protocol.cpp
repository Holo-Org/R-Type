module game.protocol;

import std;
import engine.bytes;

namespace game {

namespace {

// Each message body is written and read by a pair of overloads, side by side.
// read_body returns false when a value is out of range; running out of bytes
// is recorded by the reader and checked by the caller.

constexpr MessageType type_of(const Connect&) { return MessageType::connect; }
constexpr MessageType type_of(const Accept&) { return MessageType::accept; }
constexpr MessageType type_of(const Reject&) { return MessageType::reject; }
constexpr MessageType type_of(const Input&) { return MessageType::input; }
constexpr MessageType type_of(const Snapshot&) { return MessageType::snapshot; }
constexpr MessageType type_of(const Disconnect&) { return MessageType::disconnect; }
constexpr MessageType type_of(const PlayerLeft&) { return MessageType::player_left; }

void write_body(engine::ByteWriter&, const Connect&) {}

bool read_body(engine::ByteReader&, Connect&) {
    return true;
}

void write_body(engine::ByteWriter& out, const Accept& accept) {
    out.u8(accept.player);
}

bool read_body(engine::ByteReader& in, Accept& accept) {
    accept.player = in.u8();
    return accept.player < max_players;
}

void write_body(engine::ByteWriter& out, const Reject& reject) {
    out.u8(std::to_underlying(reject.reason));
}

bool read_body(engine::ByteReader& in, Reject& reject) {
    const auto reason = in.u8();
    reject.reason = RejectReason{reason};
    return reject.reason == RejectReason::match_full;
}

void write_body(engine::ByteWriter& out, const Input& input) {
    for (const auto& state : input.recent) {
        out.u32(state.tick);
        out.u8(state.buttons);
    }
}

bool read_body(engine::ByteReader& in, Input& input) {
    bool valid = true;
    for (auto& state : input.recent) {
        state.tick = in.u32();
        state.buttons = in.u8();
        valid = valid && (state.buttons & ~button::all) == 0;
    }
    return valid && std::ranges::is_sorted(input.recent, std::ranges::greater{}, &InputState::tick);
}

void write_body(engine::ByteWriter& out, const Snapshot& snapshot) {
    const auto count = std::min<std::size_t>(snapshot.ship_count, snapshot.ships.size());
    out.u32(snapshot.tick);
    out.u8(static_cast<std::uint8_t>(count));
    for (const auto& ship : std::span{snapshot.ships}.first(count)) {
        out.u8(ship.player);
        out.u16(ship.x);
        out.u16(ship.y);
    }
}

bool read_body(engine::ByteReader& in, Snapshot& snapshot) {
    snapshot.tick = in.u32();
    snapshot.ship_count = in.u8();
    // Checked before use: an attacker-chosen count never sizes or indexes anything.
    if (snapshot.ship_count > max_players) {
        return false;
    }
    unsigned seen = 0;
    for (auto& ship : std::span{snapshot.ships}.first(snapshot.ship_count)) {
        ship.player = in.u8();
        ship.x = in.u16();
        ship.y = in.u16();
        if (ship.player >= max_players || (seen & (1u << ship.player)) != 0) {
            return false;
        }
        seen |= 1u << ship.player;
    }
    return true;
}

void write_body(engine::ByteWriter&, const Disconnect&) {}

bool read_body(engine::ByteReader&, Disconnect&) {
    return true;
}

void write_body(engine::ByteWriter& out, const PlayerLeft& left) {
    out.u8(left.player);
}

bool read_body(engine::ByteReader& in, PlayerLeft& left) {
    left.player = in.u8();
    return left.player < max_players;
}

template <class Body>
std::expected<Message, DecodeError> read_message(engine::ByteReader& in) {
    Body body{};
    const bool valid = read_body(in, body);
    if (!in) {
        return std::unexpected{DecodeError::truncated};
    }
    if (!valid) {
        return std::unexpected{DecodeError::bad_value};
    }
    if (in.remaining() != 0) {
        return std::unexpected{DecodeError::trailing_bytes};
    }
    return body;
}

std::expected<Message, DecodeError> read_message(MessageType type, engine::ByteReader& in) {
    switch (type) {
    case MessageType::connect: return read_message<Connect>(in);
    case MessageType::accept: return read_message<Accept>(in);
    case MessageType::reject: return read_message<Reject>(in);
    case MessageType::input: return read_message<Input>(in);
    case MessageType::snapshot: return read_message<Snapshot>(in);
    case MessageType::disconnect: return read_message<Disconnect>(in);
    case MessageType::player_left: return read_message<PlayerLeft>(in);
    }
    return std::unexpected{DecodeError::unknown_type};
}

} // namespace

std::string_view to_string(DecodeError error) {
    switch (error) {
    case DecodeError::too_long: return "too long";
    case DecodeError::truncated: return "truncated";
    case DecodeError::bad_protocol: return "bad protocol id";
    case DecodeError::bad_version: return "bad version";
    case DecodeError::unknown_type: return "unknown message type";
    case DecodeError::bad_value: return "value out of range";
    case DecodeError::trailing_bytes: return "trailing bytes";
    }
    return "unknown error";
}

Encoded encode(const Packet& packet) {
    Encoded encoded;
    engine::ByteWriter out{encoded.buffer_};
    out.u16(protocol_id);
    out.u8(protocol_version);
    out.u8(std::to_underlying(std::visit([](const auto& body) { return type_of(body); }, packet.message)));
    out.u32(packet.sequence);
    std::visit([&out](const auto& body) { write_body(out, body); }, packet.message);
    // The largest message is a few dozen bytes, so this is a programming error.
    if (!out) {
        throw std::logic_error{"packet does not fit in a datagram"};
    }
    encoded.size_ = out.size();
    return encoded;
}

std::expected<Packet, DecodeError> decode(std::span<const std::byte> datagram) {
    if (datagram.size() > max_datagram_size) {
        return std::unexpected{DecodeError::too_long};
    }
    engine::ByteReader in{datagram};
    const auto id = in.u16();
    const auto version = in.u8();
    const auto type = in.u8();
    const auto sequence = in.u32();
    if (!in) {
        return std::unexpected{DecodeError::truncated};
    }
    if (id != protocol_id) {
        return std::unexpected{DecodeError::bad_protocol};
    }
    if (version != protocol_version) {
        return std::unexpected{DecodeError::bad_version};
    }
    // Any byte is a valid value of MessageType's underlying type; unknown
    // ones fall through the switch.
    auto message = read_message(MessageType{type}, in);
    if (!message) {
        return std::unexpected{message.error()};
    }
    return Packet{sequence, std::move(*message)};
}

} // namespace game
