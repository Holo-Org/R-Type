// Third-party headers go in the global module fragment, before `import std`.
module;

#include <asio/io_context.hpp>
#include <asio/io_context_strand.hpp>
#include <asio/ip/udp.hpp>
#include <asio/post.hpp>

module engine.net;

import std;

namespace engine {

namespace {

asio::ip::udp::endpoint to_asio(const Endpoint& endpoint) {
    return {asio::ip::address_v4{endpoint.address}, endpoint.port};
}

Endpoint from_asio(const asio::ip::udp::endpoint& endpoint) {
    return {endpoint.address().to_v4().to_bytes(), endpoint.port()};
}

} // namespace

std::string to_string(const Endpoint& endpoint) {
    const auto& a = endpoint.address;
    return std::format("{}.{}.{}.{}:{}", a[0], a[1], a[2], a[3], endpoint.port);
}

std::optional<Endpoint> resolve(std::string_view host, std::uint16_t port) {
    asio::io_context io;
    asio::ip::udp::resolver resolver{io};
    std::error_code error;
    const auto results = resolver.resolve(asio::ip::udp::v4(), std::string{host}, std::to_string(port), error);
    if (error || results.empty()) {
        return std::nullopt;
    }
    return from_asio(results.begin()->endpoint());
}

struct UdpTransport::Impl {
    asio::io_context io;
    // Work posted through a strand runs in the order it was posted.
    asio::io_context::strand outgoing{io};
    asio::ip::udp::socket socket;
    std::uint16_t port;
    asio::ip::udp::endpoint sender;
    // One spare byte: a datagram that fills it was too large.
    std::array<std::byte, max_datagram_size + 1> buffer{};

    mutable std::mutex mutex;
    std::vector<Datagram> inbox;
    std::atomic<std::size_t> dropped = 0;

    // Declared last, so it is joined before anything it uses is destroyed.
    std::jthread thread;

    explicit Impl(std::uint16_t requested_port)
        : socket{io, {asio::ip::udp::v4(), requested_port}}, port{socket.local_endpoint().port()} {
        receive_next();
        thread = std::jthread{[this] { io.run(); }};
    }

    // Closing the socket on the network thread, after the sends queued before
    // it, cancels the pending receive, which lets io.run() return.
    ~Impl() {
        asio::post(outgoing, [this] {
            std::error_code ignored;
            socket.close(ignored);
        });
    }

    void receive_next() {
        socket.async_receive_from(asio::buffer(buffer), sender, [this](const std::error_code& error, std::size_t size) {
            if (error == asio::error::operation_aborted || !socket.is_open()) {
                return;
            }
            // Errors here are transient for UDP, such as Windows reporting an
            // ICMP "port unreachable" from an earlier send: keep receiving.
            if (!error && size <= max_datagram_size) {
                deliver(size);
            } else {
                ++dropped;
            }
            receive_next();
        });
    }

    void deliver(std::size_t size) {
        std::scoped_lock lock{mutex};
        if (inbox.size() >= inbox_capacity) {
            ++dropped;
            return;
        }
        const auto bytes = std::span{buffer}.first(size);
        inbox.push_back({from_asio(sender), {bytes.begin(), bytes.end()}});
    }
};

UdpTransport::UdpTransport(std::uint16_t port) : impl_{std::make_unique<Impl>(port)} {}

UdpTransport::~UdpTransport() = default;

void UdpTransport::send(const Endpoint& to, std::span<const std::byte> bytes) {
    // An Asio socket must not be used from two threads at once, so the send
    // runs on the network thread.
    asio::post(impl_->outgoing, [impl = impl_.get(), to = to_asio(to), data = std::vector(bytes.begin(), bytes.end())] {
        std::error_code ignored; // a failed send is a lost datagram, which UDP allows
        impl->socket.send_to(asio::buffer(data), to, 0, ignored);
    });
}

std::vector<Datagram> UdpTransport::receive() {
    std::vector<Datagram> received;
    std::scoped_lock lock{impl_->mutex};
    received.swap(impl_->inbox);
    return received;
}

std::size_t UdpTransport::dropped() const {
    return impl_->dropped;
}

std::uint16_t UdpTransport::local_port() const {
    return impl_->port;
}

} // namespace engine
