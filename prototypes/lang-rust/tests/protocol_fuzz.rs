//! Throws random and mutated datagrams at the protocol decoder, which must
//! never panic, never allocate, and reject anything but well-formed packets.
//! In the default (debug) profile, integer overflow checks are on as well.
//!
//! usage: protocol_fuzz [datagrams [seed]]
//!   cargo test -p protocol-fuzz -- 100000 42

use std::alloc::{GlobalAlloc, Layout, System};
use std::panic;
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};

use engine_headless::random::Random;
use game::protocol::{
    self, Buttons, DecodeError, Input, InputState, MAX_PLAYERS, Message, Packet, RejectReason,
    ShipState, Snapshot,
};

/// Counts every heap allocation in the program, and leaves the work to the
/// system allocator.
struct CountingAllocator;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

// A global allocator is `unsafe` to implement: the compiler cannot check that
// it hands out valid memory. The one `unsafe` of this POC, allowed here only.
//
// SAFETY: every method forwards its arguments unchanged to the system
// allocator, which upholds the GlobalAlloc contract; counting touches no memory
// that is handed out.
#[allow(unsafe_code)]
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: the caller upholds alloc's contract, which System shares.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: as for alloc.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, block: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: `block` came from this allocator, that is from System.
        unsafe { System.realloc(block, layout, new_size) }
    }

    unsafe fn dealloc(&self, block: *mut u8, layout: Layout) {
        // SAFETY: `block` came from this allocator, that is from System.
        unsafe { System.dealloc(block, layout) }
    }
}

#[global_allocator]
static COUNTING_ALLOCATOR: CountingAllocator = CountingAllocator;

fn random_player(random: &mut Random) -> u8 {
    random.below(MAX_PLAYERS as u32) as u8
}

fn shuffle<T>(items: &mut [T], random: &mut Random) {
    for i in (1..items.len()).rev() {
        items.swap(i, random.below(i as u32 + 1) as usize);
    }
}

fn random_message(random: &mut Random) -> Message {
    match random.below(7) {
        0 => Message::Connect,
        1 => Message::Accept {
            player: random_player(random),
        },
        2 => Message::Reject {
            reason: RejectReason::MatchFull,
        },
        3 => {
            let mut input = Input::default();
            let mut tick = random.next_u32();
            for state in &mut input.recent {
                let buttons = Buttons::from_bits_truncate(random.next_u32() as u8);
                *state = InputState { tick, buttons };
                tick -= tick.min(random.below(3));
            }
            Message::Input(input)
        }
        4 => {
            let tick = random.next_u32();
            let count = random.below(MAX_PLAYERS as u32 + 1) as usize;
            let mut players = [0, 1, 2, 3];
            shuffle(&mut players, random);
            let ships = players.into_iter().take(count).map(|player| ShipState {
                player,
                x: random.next_u32() as u16,
                y: random.next_u32() as u16,
            });
            Message::Snapshot(Snapshot::new(tick, ships))
        }
        5 => Message::Disconnect,
        _ => Message::PlayerLeft {
            player: random_player(random),
        },
    }
}

fn random_packet(random: &mut Random) -> Packet {
    Packet {
        sequence: random.next_u32(),
        message: random_message(random),
    }
}

/// One to three mutations: flip a bit, overwrite a byte, truncate, or append.
fn mutate(bytes: &mut Vec<u8>, random: &mut Random) {
    for _ in 0..1 + random.below(3) {
        let len = bytes.len() as u32;
        match random.below(4) {
            0 if len > 0 => bytes[random.below(len) as usize] ^= 1 << random.below(8),
            1 if len > 0 => bytes[random.below(len) as usize] = random.next_u32() as u8,
            0 | 1 => {}
            2 => bytes.truncate(random.below(len + 1) as usize),
            _ => {
                for _ in 0..1 + random.below(8) {
                    bytes.push(random.next_u32() as u8);
                }
            }
        }
    }
}

/// The number of datagrams and the seed; only numbers are accepted, so a
/// `cargo test <filter>` meant for other tests fails loudly here.
fn parse_args(args: &[String]) -> Option<(u64, u64)> {
    let count = match args.first() {
        Some(count) => count.parse().ok()?,
        None => 100_000,
    };
    let seed = match args.get(1) {
        Some(seed) => seed.parse().ok()?,
        None => Random::fresh_seed(),
    };
    (args.len() <= 2).then_some((count, seed))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((count, seed)) = parse_args(&args) else {
        eprintln!("usage: protocol_fuzz [datagrams [seed]]");
        return ExitCode::from(2);
    };
    let mut random = Random::new(seed);
    println!("protocol_fuzz: seed {seed}");

    // Whatever encode() writes, decode() must read back unchanged.
    const ROUND_TRIPS: u32 = 10_000;
    let mut mismatches = 0;
    for _ in 0..ROUND_TRIPS {
        let packet = random_packet(&mut random);
        if protocol::decode(protocol::encode(&packet).as_bytes()) != Ok(packet) {
            mismatches += 1;
        }
    }
    println!("round trip: {ROUND_TRIPS} packets, {mismatches} mismatches");

    // Half pure noise of any length up to 1500 bytes, half mutated valid packets.
    let mut rejected = [0_usize; DecodeError::ALL.len()];
    let mut accepted = 0;
    let mut panics = 0;
    let mut decoder_allocations = 0;
    let mut datagram = Vec::with_capacity(2048);
    for i in 0..count {
        datagram.clear();
        if i.is_multiple_of(2) {
            let len = random.below(1501);
            datagram.extend((0..len).map(|_| random.next_u32() as u8));
        } else {
            let packet = random_packet(&mut random);
            datagram.extend_from_slice(protocol::encode(&packet).as_bytes());
            mutate(&mut datagram, &mut random);
        }
        let before = ALLOCATIONS.load(Ordering::Relaxed);
        // A panic would unwind to here and be counted, instead of ending the run.
        let outcome = panic::catch_unwind(|| protocol::decode(&datagram));
        decoder_allocations += ALLOCATIONS.load(Ordering::Relaxed) - before;
        match outcome {
            Ok(Ok(_)) => accepted += 1,
            Ok(Err(error)) => rejected[error as usize] += 1,
            Err(_) => panics += 1,
        }
    }

    let total_rejected: usize = rejected.iter().sum();
    println!(
        "fuzz: {count} datagrams, {total_rejected} rejected, {accepted} accepted, \
         {panics} panics, {decoder_allocations} allocations in decode()"
    );
    for (error, times) in DecodeError::ALL.iter().zip(rejected) {
        println!("  {times:>7} {error}");
    }
    if mismatches == 0 && panics == 0 && decoder_allocations == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
