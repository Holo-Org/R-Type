//! Little-endian integer encoding, so the wire format never depends on the
//! host's byte order or struct layout.
//!
//! Nothing here can panic, whatever the input: slices are only reached through
//! methods that return `Option`, and the lints below reject any `bytes[i]` or
//! `unwrap()` that would slip in.
#![deny(
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic
)]

/// Writes into a caller-provided buffer. A write that does not fit is dropped
/// and marks the writer as failed; check [`ByteWriter::is_ok`] once, after the
/// last write.
#[derive(Debug)]
pub struct ByteWriter<'a> {
    buffer: &'a mut [u8],
    written: usize,
    ok: bool,
}

impl<'a> ByteWriter<'a> {
    pub fn new(buffer: &'a mut [u8]) -> Self {
        Self {
            buffer,
            written: 0,
            ok: true,
        }
    }

    pub fn u8(&mut self, value: u8) {
        self.put(value.to_le_bytes());
    }

    pub fn u16(&mut self, value: u16) {
        self.put(value.to_le_bytes());
    }

    pub fn u32(&mut self, value: u32) {
        self.put(value.to_le_bytes());
    }

    /// Bytes written so far.
    pub fn written(&self) -> usize {
        self.written
    }

    /// False once a write did not fit.
    pub fn is_ok(&self) -> bool {
        self.ok
    }

    fn put<const N: usize>(&mut self, bytes: [u8; N]) {
        let free = self
            .buffer
            .get_mut(self.written..)
            .and_then(|rest| rest.first_chunk_mut::<N>());
        match free {
            Some(slot) if self.ok => {
                *slot = bytes;
                self.written += N;
            }
            _ => self.ok = false,
        }
    }
}

/// A read went past the end of the bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Truncated;

/// Reads integers from untrusted bytes. Every read is bounds-checked: one that
/// would go past the end fails with [`Truncated`] and consumes nothing, so a
/// decoder can use `?` on each read.
#[derive(Clone, Debug)]
pub struct ByteReader<'a> {
    bytes: &'a [u8],
}

impl<'a> ByteReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes }
    }

    pub fn u8(&mut self) -> Result<u8, Truncated> {
        self.take().map(u8::from_le_bytes)
    }

    pub fn u16(&mut self) -> Result<u16, Truncated> {
        self.take().map(u16::from_le_bytes)
    }

    pub fn u32(&mut self) -> Result<u32, Truncated> {
        self.take().map(u32::from_le_bytes)
    }

    /// Bytes not read yet.
    pub fn remaining(&self) -> usize {
        self.bytes.len()
    }

    // The array length N comes from the caller: `u16::from_le_bytes` takes a
    // [u8; 2], so `self.take()` there reads two bytes.
    fn take<const N: usize>(&mut self) -> Result<[u8; N], Truncated> {
        let (head, rest) = self.bytes.split_first_chunk::<N>().ok_or(Truncated)?;
        self.bytes = rest;
        Ok(*head)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integers_are_little_endian() {
        let mut buffer = [0; 7];
        let mut out = ByteWriter::new(&mut buffer);
        out.u8(0x01);
        out.u16(0x0302);
        out.u32(0x0706_0504);
        assert!(out.is_ok());
        assert_eq!(out.written(), 7);
        assert_eq!(buffer, [1, 2, 3, 4, 5, 6, 7]);

        let mut input = ByteReader::new(&buffer);
        assert_eq!(input.u8(), Ok(0x01));
        assert_eq!(input.u16(), Ok(0x0302));
        assert_eq!(input.u32(), Ok(0x0706_0504));
        assert_eq!(input.remaining(), 0);
    }

    #[test]
    fn overflowing_writes_and_reads_fail_without_panicking() {
        let mut buffer = [0; 3];
        let mut out = ByteWriter::new(&mut buffer);
        out.u16(0xFFFF);
        out.u16(0xFFFF);
        assert!(!out.is_ok());
        assert_eq!(out.written(), 2);

        let mut input = ByteReader::new(&[1, 2, 3]);
        assert_eq!(input.u32(), Err(Truncated));
        assert_eq!(input.remaining(), 3, "a failed read consumes nothing");
        assert_eq!(input.u16(), Ok(0x0201));
    }
}
