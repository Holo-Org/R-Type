// Little-endian integer encoding, one byte at a time, so the wire format
// never depends on the host's byte order or struct layout.
export module engine.bytes;

import std;

export namespace engine {

// Writes into a caller-provided buffer. A write that does not fit is dropped
// and marks the writer as failed; check it once, after the last write.
class ByteWriter {
public:
    explicit ByteWriter(std::span<std::byte> buffer) : buffer_{buffer} {}

    void u8(std::uint8_t value) { put(value, 1); }
    void u16(std::uint16_t value) { put(value, 2); }
    void u32(std::uint32_t value) { put(value, 4); }

    [[nodiscard]] std::size_t size() const { return size_; }
    [[nodiscard]] explicit operator bool() const { return ok_; }

private:
    void put(std::uint32_t value, std::size_t count) {
        if (!ok_ || buffer_.size() - size_ < count) {
            ok_ = false;
            return;
        }
        for (std::size_t i = 0; i < count; ++i) {
            buffer_[size_++] = static_cast<std::byte>(value >> (8 * i));
        }
    }

    std::span<std::byte> buffer_;
    std::size_t size_ = 0;
    bool ok_ = true;
};

// Reads from untrusted bytes. Every read is bounds-checked: a read past the
// end returns 0 and marks the reader as failed, so a decoder can read a whole
// message and check once before trusting any of it.
class ByteReader {
public:
    explicit ByteReader(std::span<const std::byte> bytes) : bytes_{bytes} {}

    std::uint8_t u8() { return static_cast<std::uint8_t>(get(1)); }
    std::uint16_t u16() { return static_cast<std::uint16_t>(get(2)); }
    std::uint32_t u32() { return get(4); }

    [[nodiscard]] std::size_t remaining() const { return bytes_.size() - offset_; }
    [[nodiscard]] explicit operator bool() const { return ok_; }

private:
    std::uint32_t get(std::size_t count) {
        if (!ok_ || remaining() < count) {
            ok_ = false;
            return 0;
        }
        std::uint32_t value = 0;
        for (std::size_t i = 0; i < count; ++i) {
            value |= std::to_integer<std::uint32_t>(bytes_[offset_++]) << (8 * i);
        }
        return value;
    }

    std::span<const std::byte> bytes_;
    std::size_t offset_ = 0;
    bool ok_ = true;
};

} // namespace engine
