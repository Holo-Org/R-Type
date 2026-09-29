// The messages exchanged by the Server and the Clients, and their wire format.
//
// Every datagram is one packet: an 8-byte header, then the message body.
// All integers are little-endian.
//
//   header       u16 protocol id ("RT"), u8 version, u8 message type, u32 sequence
//   connect      (empty)                                          Client -> Server
//   accept       u8 Player index                                  Server -> Client
//   reject       u8 reason                                        Server -> Client
//   input        3 x (u32 Client Tick, u8 buttons), newest first  Client -> Server
//   snapshot     u32 Server Tick, u8 Ship count (0-4),
//                count x (u8 Player index, u16 x, u16 y)          Server -> Client
//   disconnect   (empty)                                          Client -> Server
//   player_left  u8 Player index                                  Server -> Client
//
// The sequence counts the datagrams sent by each peer; receivers use it to
// ignore datagrams that arrive out of order.
export module game.protocol;

import std;
import engine.net;

export namespace game {

inline constexpr std::uint16_t protocol_id = 'R' | ('T' << 8);
inline constexpr std::uint8_t protocol_version = 1;
inline constexpr std::size_t max_datagram_size = engine::UdpTransport::max_datagram_size;
inline constexpr std::size_t max_players = 4;
inline constexpr std::size_t input_history = 3;

enum class MessageType : std::uint8_t {
    connect = 1,
    accept,
    reject,
    input,
    snapshot,
    disconnect,
    player_left,
};

namespace button {
inline constexpr std::uint8_t up = 1 << 0;
inline constexpr std::uint8_t down = 1 << 1;
inline constexpr std::uint8_t left = 1 << 2;
inline constexpr std::uint8_t right = 1 << 3;
inline constexpr std::uint8_t fire = 1 << 4;
inline constexpr std::uint8_t all = up | down | left | right | fire;
} // namespace button

// Comparisons are defaulted members, not friends: GCC 15.3 and 16.2 crash on
// an imported defaulted friend operator==.

// The buttons a Player held during one Client Tick.
struct InputState {
    std::uint32_t tick = 0;
    std::uint8_t buttons = 0;

    bool operator==(const InputState&) const = default;
};

struct ShipState {
    std::uint8_t player = 0;
    std::uint16_t x = 0;
    std::uint16_t y = 0;

    bool operator==(const ShipState&) const = default;
};

enum class RejectReason : std::uint8_t { match_full = 1 };

struct Connect {
    bool operator==(const Connect&) const = default;
};

struct Accept {
    std::uint8_t player = 0;
    bool operator==(const Accept&) const = default;
};

struct Reject {
    RejectReason reason = RejectReason::match_full;
    bool operator==(const Reject&) const = default;
};

// The last input_history input states, newest first, so that one lost
// datagram loses no input.
struct Input {
    std::array<InputState, input_history> recent{};
    bool operator==(const Input&) const = default;
};

struct Snapshot {
    std::uint32_t tick = 0;
    std::uint8_t ship_count = 0;
    std::array<ShipState, max_players> ships{};

    bool operator==(const Snapshot&) const = default;
};

struct Disconnect {
    bool operator==(const Disconnect&) const = default;
};

struct PlayerLeft {
    std::uint8_t player = 0;
    bool operator==(const PlayerLeft&) const = default;
};

using Message = std::variant<Connect, Accept, Reject, Input, Snapshot, Disconnect, PlayerLeft>;

struct Packet {
    std::uint32_t sequence = 0;
    Message message;

    bool operator==(const Packet&) const = default;
};

enum class DecodeError : std::uint8_t {
    too_long,
    truncated,
    bad_protocol,
    bad_version,
    unknown_type,
    bad_value,
    trailing_bytes,
};

inline constexpr std::size_t decode_error_count = static_cast<std::size_t>(DecodeError::trailing_bytes) + 1;

std::string_view to_string(DecodeError error);

// An encoded packet, held in place: encoding never allocates.
class Encoded {
public:
    [[nodiscard]] std::span<const std::byte> bytes() const { return std::span{buffer_}.first(size_); }

private:
    friend Encoded encode(const Packet& packet);
    std::array<std::byte, max_datagram_size> buffer_{};
    std::size_t size_ = 0;
};

Encoded encode(const Packet& packet);

// Decodes one datagram. Never allocates, and rejects anything that is not
// exactly one well-formed packet.
std::expected<Packet, DecodeError> decode(std::span<const std::byte> datagram);

} // namespace game
