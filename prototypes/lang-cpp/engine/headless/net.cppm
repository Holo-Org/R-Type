// UDP transport. Asio stays inside the implementation unit (net.cpp): code
// that imports this module never sees an Asio header.
export module engine.net;

import std;

export namespace engine {

// An IPv4 address and a UDP port: a plain value that can key a peer table.
struct Endpoint {
    std::array<std::uint8_t, 4> address{};
    std::uint16_t port = 0;

    // A member, not a friend: GCC 15.3 and 16.2 crash on an imported defaulted friend operator==.
    bool operator==(const Endpoint&) const = default;
};

std::string to_string(const Endpoint& endpoint);

// Resolves a host name or dotted address to its first IPv4 endpoint.
std::optional<Endpoint> resolve(std::string_view host, std::uint16_t port);

struct Datagram {
    Endpoint from;
    std::vector<std::byte> bytes;
};

// A UDP socket served by its own network thread. The thread fills a bounded
// inbox; any thread may drain it with receive() and send with send().
class UdpTransport {
public:
    // Larger datagrams are dropped unread; this stays below common MTUs.
    static constexpr std::size_t max_datagram_size = 1200;
    // Datagrams left waiting in the inbox; any more are dropped.
    static constexpr std::size_t inbox_capacity = 256;

    // Binds to `port` on every IPv4 interface; 0 picks a free port.
    // Throws std::system_error if the port cannot be bound.
    explicit UdpTransport(std::uint16_t port = 0);
    ~UdpTransport();
    UdpTransport(const UdpTransport&) = delete;
    UdpTransport& operator=(const UdpTransport&) = delete;

    // Queues a datagram for the network thread; UDP gives no delivery guarantee.
    void send(const Endpoint& to, std::span<const std::byte> bytes);
    // Takes every datagram received since the last call.
    [[nodiscard]] std::vector<Datagram> receive();
    // Datagrams dropped so far: too large, inbox full, or a receive error.
    [[nodiscard]] std::size_t dropped() const;
    [[nodiscard]] std::uint16_t local_port() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace engine
