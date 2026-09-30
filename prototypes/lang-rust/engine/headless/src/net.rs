//! UDP transport: a socket served by its own network thread, which hands the
//! datagrams it receives to the Tick loop through a bounded channel.

use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, ToSocketAddrs, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// An IPv4 address and a UDP port: a plain value that can key a peer table,
/// and prints as `127.0.0.1:4242`.
pub type Endpoint = SocketAddrV4;

/// Larger datagrams are dropped unread; this stays below common MTUs.
pub const MAX_DATAGRAM_SIZE: usize = 1200;
/// Datagrams left waiting for the Tick loop; any more are dropped.
pub const INBOX_CAPACITY: usize = 256;
/// How long the network thread waits for a datagram before checking whether
/// it should stop: std offers no way to interrupt a blocked receive.
const STOP_CHECK_INTERVAL: Duration = Duration::from_millis(100);

/// Resolves a host name or dotted address to its first IPv4 endpoint.
pub fn resolve(host: &str, port: u16) -> Option<Endpoint> {
    (host, port)
        .to_socket_addrs()
        .ok()?
        .find_map(|address| match address {
            SocketAddr::V4(address) => Some(address),
            SocketAddr::V6(_) => None,
        })
}

/// One datagram, as it arrived.
#[derive(Clone, Debug)]
pub struct Datagram {
    pub from: Endpoint,
    pub bytes: Vec<u8>,
}

/// A UDP socket served by its own network thread. The thread fills a bounded
/// inbox, which [`UdpTransport::receive`] drains; [`UdpTransport::send`] sends
/// from the calling thread.
#[derive(Debug)]
pub struct UdpTransport {
    socket: UdpSocket,
    inbox: Receiver<Datagram>,
    dropped: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl UdpTransport {
    /// Binds to `port` on every IPv4 interface; 0 picks a free port.
    pub fn bind(port: u16) -> io::Result<Self> {
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port))?;
        // A second handle to the same socket, owned by the network thread.
        let receiving = socket.try_clone()?;
        receiving.set_read_timeout(Some(STOP_CHECK_INTERVAL))?;
        let (inbox_sender, inbox) = mpsc::sync_channel(INBOX_CAPACITY);
        let dropped = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = thread::Builder::new().name("network".into()).spawn({
            // The thread gets its own reference-counted handles: `move` hands
            // these clones over, and the originals stay here.
            let dropped = Arc::clone(&dropped);
            let stop = Arc::clone(&stop);
            move || receive_until_stopped(&receiving, &inbox_sender, &dropped, &stop)
        })?;
        Ok(Self {
            socket,
            inbox,
            dropped,
            stop,
            thread: Some(thread),
        })
    }

    /// Sends one datagram. UDP gives no delivery guarantee, so a failed send
    /// is just a lost datagram. std's socket may be used from any thread, so
    /// unlike an Asio socket it needs no detour through the network thread.
    pub fn send(&self, to: Endpoint, bytes: &[u8]) {
        let _ = self.socket.send_to(bytes, to);
    }

    /// Takes the datagrams received since the last call, oldest first.
    pub fn receive(&self) -> Vec<Datagram> {
        self.inbox.try_iter().take(INBOX_CAPACITY).collect()
    }

    /// Datagrams dropped so far: too large, inbox full, or a receive error.
    pub fn dropped(&self) -> usize {
        self.dropped.load(Ordering::Relaxed)
    }

    pub fn local_port(&self) -> io::Result<u16> {
        self.socket.local_addr().map(|address| address.port())
    }
}

impl Drop for UdpTransport {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            // Returns within STOP_CHECK_INTERVAL. The thread cannot panic
            // short of a bug, and a destructor has nobody to report one to.
            let _ = thread.join();
        }
    }
}

fn receive_until_stopped(
    socket: &UdpSocket,
    inbox: &SyncSender<Datagram>,
    dropped: &AtomicUsize,
    stop: &AtomicBool,
) {
    // One spare byte: a datagram that fills it was too large.
    let mut buffer = [0; MAX_DATAGRAM_SIZE + 1];
    while !stop.load(Ordering::Relaxed) {
        match socket.recv_from(&mut buffer) {
            Ok((size, SocketAddr::V4(from))) if size <= MAX_DATAGRAM_SIZE => {
                let bytes = buffer[..size].to_vec();
                match inbox.try_send(Datagram { from, bytes }) {
                    Ok(()) => {}
                    Err(TrySendError::Full(_)) => {
                        dropped.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Disconnected(_)) => return,
                }
            }
            // No datagram yet: loop around to check `stop`.
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            // Too large, not IPv4, or a transient error, such as Windows
            // reporting an ICMP "port unreachable" from an earlier send: count
            // it and keep receiving.
            _ => {
                dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}
