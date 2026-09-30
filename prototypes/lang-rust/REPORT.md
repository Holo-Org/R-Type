# Language POC report: Rust

The second of the four language POCs (C++, Rust, Zig, Odin) described in `docs/research/language-pocs.md`. Built and measured on 2026-09-30. Judgement is marked **Assessment**; everything else was measured here or comes from the cited source. How to build and run it is in [README.md](README.md).

## Summary

- **The whole slice works, and speaks the C++ POC's protocol byte for byte.** A headless Server and a raylib Client, on an Engine split into `engine-headless` and `engine-client`, in one Cargo workspace. Four scripted Clients play together, a killed Client is dropped after 3.05 s and the others are told, garbage datagrams are counted and ignored, and a fifth Client is refused. Rust Clients play on the C++ Server and C++ Clients on the Rust Server, and captured datagrams are byte-identical.
- **No `unsafe` in our code.** The workspace forbids it. The fuzz test's counting allocator is the one exception, and implementing an allocator cannot be done without it. The decoder did not panic on any input tried: 5,100,000 fuzzed datagrams, 0 panics, 0 allocations.
- **Builds are fast, and most of the cost is raylib's.** A cold build from an empty Cargo home (36 crate downloads, raylib compiled from source with CMake, bindgen) takes 12.2–13.5 s on this Mac. Rebuilding our own six crates takes 0.5 s. An edit in the Game rebuilds four crates in 0.43–0.47 s (release) or 0.29–0.33 s (debug), whether the edit touches a private detail or a public type.
- **Cargo enforces half of ADR 0001 on its own.** Code cannot name a crate its package does not list, and dependency cycles are refused. A wrong but acyclic dependency, such as the Server listing the client Engine, builds without complaint (and links raylib into the Server). A `deny.toml` of 19 configuration lines, checked by cargo-deny, refuses those. On stable Rust, nothing stops the client Engine's public API from exposing a raylib type.
- **Windows `.exe` files cross-build from the Mac**, with nixpkgs' MinGW-w64 GCC and three workarounds, in 19.2 s from clean. They import only Windows' own DLLs. They were not run: no Windows machine, and nixpkgs' Wine is Linux-only.
- **What hurt:** gaps in the `raylib` crate's safe API (three workarounds), bindgen's need for libclang on every machine, 39 third-party crates to compile for one binding, and a macOS deployment-target mismatch between rustc and the `cc` crate. **What was pleasant:** one command builds everything with a pinned compiler, compile times, the decoder's `?`-based error handling, `enum` messages with exhaustive `match`, and the borrow checker catching a real resource-lifetime bug.

## Versions used

| Tool | Version | Where from |
| --- | --- | --- |
| Machine | Apple M5, 10 cores, 32 GB; macOS 26.5.2 (25F84) | |
| rustup | 1.29.1 | nixpkgs, `nix shell nixpkgs#rustup` |
| rustc | 1.98.1 (48a229cea 2026-09-01), LLVM 22.1.8, host `aarch64-apple-darwin` | rustup, pinned by `rust-toolchain.toml` |
| Cargo | 1.98.1 (797e8a9bc 2026-08-05) | rustup |
| Clippy, rustfmt | 0.1.98 (48a229ceae 2026-09-01), 1.9.0-stable | rustup, `minimal` profile plus these two |
| Edition, resolver | 2024, resolver 3 | `Cargo.toml` |
| `raylib`, `raylib-sys` crates | 6.0.0 (bundles raylib 6.0; MSRV 1.88) | crates.io |
| bindgen, `cmake`, `cc`, `clang-sys` crates | 0.72.1, 0.1.58, 1.5.1, 1.9.1 | crates.io, through `raylib-sys` |
| CMake | 4.4.2 | nixpkgs |
| C compiler and linker | Apple clang 21.0.0 (clang-2100.1.1.101), GNU Make 3.81 | Xcode Command Line Tools 26.6, in `/usr/bin` |
| libclang (for bindgen) | the Command Line Tools' `libclang.dylib` | found by `clang-sys` on its own |
| MinGW-w64 | GCC 15.3.0, binutils 2.46, mingw-w64 14.0.0 headers and winpthreads, mcfgthread 2.4.2 | nixpkgs `pkgsCross.mingwW64` |
| cargo-deny | 0.20.2 | nixpkgs |
| tokei | 15.0.0 | nixpkgs |
| Nix, nixpkgs | Lix 2.95.2; nixpkgs 26.11 (the system registry's pinned `nixpkgs`) | |

Rust 1.98.1 was the latest stable release, published on 2026-09-03 ([release notes](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/)). The `raylib` crate 6.0.0 was published on 2026-06-10 ([crates.io](https://crates.io/crates/raylib)).

All builds ran inside `nix shell nixpkgs#rustup nixpkgs#cmake`, with `PATH` cut down to that shell's store paths plus `/usr/bin:/bin:/usr/sbin:/sbin`, as in the C++ POC, and with `RUSTUP_HOME`, `CARGO_HOME` and `CARGO_TARGET_DIR` in a scratch directory. Nothing from the user's profile (which has its own `cargo`, `rustc`, `cmake` and `ninja`) was on `PATH`.

## What was built

| Part | Crate | Contents |
| --- | --- | --- |
| Engine, headless | `engine-headless` | `bytes` (little-endian writer and checked reader), `net` (UDP transport: a network thread, a bounded `sync_channel` of 256 datagrams to the Tick loop, drop counter), `time` (fixed step on the monotonic clock), `random` (SplitMix64, since `std` has no random numbers) |
| Engine, client | `engine-client` | `Window`, `Frame`, `Texture`, `AudioDevice`, `Sound`, `Color`, `Rect`, `Key`, `Error`; raylib stays private |
| Game | `game` | `protocol` (the messages as an `enum`, `encode`, `decode`), `rules` (the Match: joining, movement, the 3 s silence limit, snapshots) |
| Server program | `r-type-server` → `r-type_server` | the 60 Hz Tick loop; logs joins, leaves, timeouts and a counters line every 5 s |
| Client program | `r-type-client` → `r-type_client` | Star-field (three layers), Ships from `r-typesheet42.gif` compiled in with `include_bytes!`, keyboard or `--script` input, a synthesized "pew", `--frames` and `--screenshot` |
| Fuzz test | `protocol-fuzz` | 10,000 round trips, then 100,000 random and mutated datagrams (by default), a counting `#[global_allocator]`, panics caught and counted |

Behaviour follows the C++ POC's: same wire format, same checks in the same order in the decoder (a short datagram is `Truncated` even when it also holds a bad value, so both decoders tally rejections alike), same Match rules, same command-line options, same log lines. Unit tests (11) check the byte reader and writer, the random generator against the reference C implementation, the exact bytes of every message, every rejection reason, and the Match rules.

The Match is in `game::rules`: `match` is a Rust keyword, so neither the module nor a variable can be called that (variables are `match_`).

## Verified on this Mac

| Check | Result |
| --- | --- |
| `cargo build --workspace --all-targets` | first try, no warning |
| `cargo clippy --workspace --all-targets -- -D warnings` | passes; it first flagged 2 idioms (`manual_is_multiple_of`, `chunks_exact_to_as_chunks`), both fixed |
| `cargo fmt --all --check` | passes, after 12 places that rustfmt flagged were reformatted by hand |
| `cargo test` | 11 unit tests pass, and the fuzz test |
| Server and four scripted Clients (the C++ POC's script, same timings) | 4 Players join, the Client with `--frames 420` leaves and the others are told |
| Screenshot | `screenshot.png`: four Ships in the sheet's four colours, the Star-field, "Player 4" and "4/4 Players" |
| `kill -9` on a Client | the Server logged "Player 1 timed out" 3.05 s after the kill; the two remaining Clients logged "Player 1 left the Match" |
| 5 garbage datagrams from `nc` | counted as 5 malformed, ignored, nothing else affected |
| A fifth Client | "r-type_client: the Match is full", exit status 1 |
| Fuzz, `cargo test -p protocol-fuzz -- 100000 42` (debug build, overflow checks on) | 10,000 round trips, 0 mismatches; 100,000 datagrams, 0 panics, 0 allocations in `decode()` |
| Fuzz, 5,000,000 datagrams, seed 7, release | 0 panics, 0 allocations, 0.95 s |
| Interoperability with the C++ POC | both directions work; captured datagrams byte-identical (see below) |
| Windows cross-build | two `.exe` files, importing only Windows DLLs; not run |

The sound was generated, decoded by raylib without error and played on each Space press, but nobody listened to it. The keyboard path was not exercised: every run used `--script`.

## Setup from a clean machine

What every platform needs:
- rustup, which reads `rust-toolchain.toml` and installs Rust 1.98.1 with Clippy and rustfmt on the first `cargo` command;
- a C compiler and linker, and CMake;
- libclang for bindgen, which "requires Clang 9.0 or greater" ([bindgen requirements](https://rust-lang.github.io/rust-bindgen/requirements.html));
- on Linux, raylib's development packages.

Cargo then downloads 36 crates (66 MB with the index cache) and builds raylib from the sources bundled in `raylib-sys`.

**macOS** (the only platform tested):

1. The Xcode Command Line Tools, for the C compiler and linker: `xcode-select --install` ([The Rust Book, Installation](https://doc.rust-lang.org/book/ch01-01-installation.html)). They also hold `libclang.dylib`, in a directory `clang-sys` searches by default (`/Library/Developer/CommandLineTools/usr/lib`, from `clang-sys` 1.9.1's `build/common.rs`), so bindgen needs no setting.
2. rustup: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` ([rust-lang.org](https://www.rust-lang.org/tools/install)), or `nix shell nixpkgs#rustup`.
3. CMake: `brew install cmake` ([raylib-rs README](https://github.com/raylib-rs/raylib-rs)), the [cmake.org](https://cmake.org/download/) installer, or `nix shell nixpkgs#cmake`.

**Linux** (not tested):

1. rustup, as above; GCC or Clang, for example `build-essential` on Ubuntu ([The Rust Book](https://doc.rust-lang.org/book/ch01-01-installation.html)); CMake.
2. libclang: `apt install libclang-dev`, `dnf install clang-devel` or `pacman -S clang` ([bindgen requirements](https://rust-lang.github.io/rust-bindgen/requirements.html)).
3. raylib's packages:
   - The [raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux), for Ubuntu/Debian: `libasound2-dev libx11-dev libxrandr-dev libxi-dev libgl1-mesa-dev libglu1-mesa-dev libxcursor-dev libxinerama-dev libwayland-dev libxkbcommon-dev`.
   - The same wiki, for Fedora: `alsa-lib-devel mesa-libGL-devel libX11-devel libXrandr-devel libXi-devel libXcursor-devel libXinerama-devel libatomic`.
   - The same wiki, for Arch: `alsa-lib mesa libx11 libxrandr libxi libxcursor libxinerama`.
   - The [raylib-rs README](https://github.com/raylib-rs/raylib-rs), for Debian/Ubuntu: `cmake libasound2-dev libudev-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev`. It also documents a `wayland` Cargo feature for Wayland; the crate builds GLFW's X11 backend by default.

**Windows, native MSVC toolchain** (not tested):

1. Visual Studio 2022 or its Build Tools with the "Desktop development with C++" workload, or at least "MSVC v143 - VS 2022 C++ x64/x86 build tools" and "Windows 11 SDK (10.0.22621.0)". rustup's guide also gives a `winget` command, and recommends the English language pack ([rustup, MSVC prerequisites](https://rust-lang.github.io/rustup/installation/windows-msvc.html)).
2. rustup, with `rustup-init.exe` for `x86_64-pc-windows-msvc` ([rustup, other installation methods](https://rust-lang.github.io/rustup/installation/other.html)).
3. CMake, from [cmake.org](https://cmake.org/download/) or `winget install Kitware.CMake`: the `cmake` crate runs `cmake` from `PATH`.
4. LLVM for libclang: `winget install LLVM.LLVM`, then set `LIBCLANG_PATH` to LLVM's `bin` directory ([bindgen requirements](https://rust-lang.github.io/rust-bindgen/requirements.html)).

**Assessment:** the Rust setup is lighter than the C++ one on macOS: the stock Command Line Tools suffice, where the C++ POC needed LLVM 22 from nixpkgs to `import std`. It is about the same on Linux, and one package heavier on Windows, where libclang is an extra install that only bindgen needs.

## Measurements

### Build times

Wall-clock times of `cargo build --release --workspace --bins --test protocol_fuzz` (both programs and the fuzz test, like the C++ POC's default build). They were measured inside the nix shell, so that nix's own start-up is not counted, on a copy of the sources in the scratch directory. The C++ column comes from the C++ POC's own xmake build logs, left in its scratch directory; it was not re-measured, and the C++ report has the authoritative figures.

| Build | Rust (runs) | C++, from its logs |
| --- | --- | --- |
| Cold: empty Cargo home and target dir (crate downloads, raylib built with CMake, bindgen, 41 crates compiled) | 13.53, 12.24, 12.86 s | configure step not timed in the logs |
| Crate downloads alone (`cargo fetch`, empty Cargo home) | 0.98 s | |
| Clean, dependencies downloaded (`cargo clean`; raylib rebuilt too, since Cargo keeps compiled dependencies in the target dir) | 11.27, 11.58, 10.80, 10.96 s | |
| Our six crates only, dependencies already compiled (comparable to xmake's clean build, whose packages stay built outside the build dir) | 0.51, 0.51, 0.52 s | 3.92–5.45 s over 17 logged full builds |
| Incremental, after editing a Game implementation detail (a spawn position in `game/src/rules.rs`) | 0.47, 0.44, 0.44, 0.43 s; 4 crates | |
| Incremental, after editing a public Game type (a derive added to `ShipState`, used by Server and Client) | 0.45, 0.46, 0.44, 0.45 s; 4 crates | 1.44 s (an edit to `protocol.cppm`) |
| No-op | 0.05 s (×3) | |
| Debug profile: clean (dependencies downloaded), implementation edit, public edit, no-op | 9.05 s; 0.30, 0.29 s; 0.33, 0.32 s; 0.06 s | |
| Windows cross-build, clean, release, both programs | 19.22 s (40 crates) | 7.31–7.46 s (MinGW, project only) |

Where the cold build's time goes, from Cargo's `--timings` report (clean build, 11.2 s):
- The `raylib-sys` build script (CMake configure and build of raylib, the `cc` builds, bindgen) runs for 6.1 s.
- It sits on the critical path after its build-time dependencies (`syn` 1.3 s, bindgen 1.2 s, `clang-sys` 1.0 s, and so on).
- Our crates take 0.5 s or less each.

Both incremental edits rebuild the same four crates: `game`, then the Server, the Client and the fuzz test, which depend on it. A crate is Rust's unit of compilation, so an edit in any of its files recompiles all of it. Cargo then recompiles every crate that depends on it, even when the edit changed nothing they use.

### Binary sizes

Release builds; "stripped" means `strip` run on a copy (`x86_64-w64-mingw32-strip` for `.exe` files). The C++ figures were measured here, on the C++ POC's existing builds.

| Binary | Rust, as Cargo builds it | Rust, stripped | C++, as built | C++, stripped |
| --- | --- | --- | --- | --- |
| `r-type_server` (macOS) | 536,144 B | 414,312 B | 204,672 B | 204,712 B |
| `r-type_client` (macOS) | 1,294,496 B | 1,074,600 B | 807,616 B | 745,208 B |
| `r-type_server.exe` | 1,279,791 B | 906,752 B | 1,400,320 B | 1,400,320 B |
| `r-type_client.exe` | 4,702,050 B | 3,290,624 B | 3,226,112 B | 3,226,112 B |

What is linked dynamically:
- **Rust Server:** only `/usr/lib/libSystem.B.dylib`.
- **Rust Client:** the system frameworks raylib uses (OpenGL, Cocoa, AppKit, IOKit, CoreFoundation, CoreVideo, CoreGraphics, CoreServices, Foundation) and `libobjc`. The Rust standard library and raylib are linked statically.
- **C++ programs:** libc++, from `/nix/store/0sajpvq9j3dz8px09lmrqkfddvr6b2rk-libcxx-22.1.8/lib/libc++.1.0.dylib`, which accounts for part of their smaller size.
- **`.exe` files:** only Windows DLLs. Both import `KERNEL32`, `ntdll`, `msvcrt`, `WS2_32`, `USERENV`, `bcryptprimitives` and `api-ms-win-core-synch-l1-2-0`; the Client adds `USER32`, `GDI32`, `SHELL32` and `WINMM`.

A size-optimised variant, built with command-line overrides only (`lto = true`, `codegen-units = 1`, `strip = true`, `panic = "abort"`), gives a 336,592 B Server and a 992,208 B Client.

### Lines of code

tokei 15.0.0, code lines only (no comments, no blank lines), run on both POCs. Rust keeps unit tests next to the code, in `#[cfg(test)]` modules; the third column leaves them out, to compare with C++, whose only test is the fuzz program.

| Part | C++ | Rust | Rust without unit tests |
| --- | --- | --- | --- |
| Engine, headless | 207 | 313 | 252, of which 30 are the random generator that C++ gets from `std` |
| Engine, client | 182 | 198 | 198 |
| Game | 363 | 570 | 408 |
| Server program | 139 | 135 | 135 |
| Client program | 314 | 349 | 349 |
| Tests | 128 | 164 (fuzz) + 223 (unit tests) | |
| Build description | 76 (`xmake.lua`) | 123 (7 `Cargo.toml`, `deny.toml`, `rust-toolchain.toml`) | |
| Helper scripts | 14 (macOS xmake helper) | 18 (Windows cross-build) | |

Lock files (`xmake-requires.lock`, `Cargo.lock`) are generated and not counted. `Cargo.lock` pins 45 packages: our 6 and 39 from crates.io, all brought in by `raylib`.

### Fuzz tallies, next to C++

Both programs run with `100000 42`. They use different random generators (`std::mt19937` and SplitMix64), so the datagrams differ and only the proportions compare.

| | C++ | Rust |
| --- | --- | --- |
| Round trips, mismatches | 10,000, 0 | 10,000, 0 |
| Accepted | 6,403 | 6,243 |
| Too long | 10,024 | 9,979 |
| Truncated | 16,744 | 16,719 |
| Bad protocol id | 46,536 | 46,610 |
| Bad version | 3,150 | 3,050 |
| Unknown message type | 2,365 | 2,346 |
| Value out of range | 3,747 | 3,690 |
| Trailing bytes | 11,031 | 11,363 |
| Allocations in `decode()` | 0 | 0 |
| Panics | not applicable | 0 |

## How the Engine/Game boundary and the headless Server are enforced

**By Cargo and rustc, with nothing to configure:**
- A crate can only name the crates listed in its own `[dependencies]`. raylib is in the Client program's dependency graph (through `engine-client`), yet `raylib::` in the Client's code does not compile.
- Dependency cycles are refused, so `engine-headless` can never depend on `game`, which depends on it.
- A program links only what its dependency graph holds. The Server's graph is `engine-headless` and `game`, so it cannot link raylib:

```text
$ cargo tree -p r-type-server -e all
r-type-server v0.1.0
├── engine-headless feature "default"
│   └── engine-headless v0.1.0
└── game feature "default"
    └── game v0.1.0
        └── engine-headless feature "default" (*)
```

`cargo tree -i raylib -e all --workspace` shows raylib's only path to a program: `engine-client`, then `r-type-client`. `otool -L r-type_server` lists `libSystem.B.dylib` alone. `nm` finds 0 symbols matching raylib, GLFW or OpenGL names in the Server, against 1,234 in the Client.

**By cargo-deny, for what Cargo accepts.** Cargo has no way to say "this dependency is wrong though acyclic". `deny.toml` uses cargo-deny's `bans` with `wrappers`, which "allows specific crates to have a direct dependency on the banned crate but denies all transitive dependencies on it" ([cargo-deny docs](https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html)). The rules:
- raylib may only be a dependency of `engine-client`, and `raylib-sys` only of `raylib`;
- `engine-client` may only be a dependency of the Client program;
- `game` may only be a dependency of the two programs and the fuzz test.

`cargo deny check bans` prints `bans ok` on the POC.

**The violations tried**, the same kinds as in the C++ POC, each on a scratch copy of the sources and reverted afterwards:

| # | Violation | Caught by | Message |
| --- | --- | --- | --- |
| 1 | Engine code uses the Game: `game::protocol::Message` in `engine-headless` | rustc | `error[E0433]: cannot find module or crate game in this scope` … `use of unresolved module or unlinked crate game`, with the hint "use `cargo add game` to add it to your `Cargo.toml`" |
| 2a | `engine-headless` lists `game` | Cargo | `error: cyclic package dependency: package engine-headless v0.1.0 (…) depends on itself. Cycle: …` |
| 2b | `engine-client` lists `game` and uses it | cargo-deny (Cargo builds it) | `error[banned]: crate 'game = 0.1.0' is explicitly banned`, reason "the Engine knows nothing about the Game (ADR 0001)"; `warning[unmatched-wrapper]: direct parent 'engine-client = 0.1.0' of banned crate 'game = 0.1.0' was not marked as a wrapper` |
| 3 | Server code uses the client Engine: `engine_client::Window` | rustc | `error[E0433]: cannot find module or crate engine_client in this scope` |
| 4 | The Server lists `engine-client` and opens a `Window` | cargo-deny | `error[banned]: crate 'engine-client = 0.1.0' is explicitly banned`, reason "only the Client program draws: the Server and the Game stay headless (ADR 0001)". Without cargo-deny, Cargo builds the Server with raylib inside: `otool -L` then lists OpenGL, Cocoa and 9 more libraries, and `nm` finds 202 symbols matching `InitWindow` or `glfw` |
| 5 | Server code uses raylib directly: `raylib::init()` | rustc | `error[E0433]: cannot find module or crate raylib in this scope` |
| 6 | Client program code uses raylib directly, around the Engine | rustc | the same, even though raylib is in the Client's dependency graph |
| 7 | The Client program lists raylib, to use it directly | cargo-deny (Cargo builds it) | `error[banned]: crate 'raylib = 6.0.0' is explicitly banned`, reason "raylib stays behind the Engine's client part (ADR 0001)", parent `r-type-client` not a wrapper |
| 7b | The Game lists raylib (the Server's graph then holds it) | cargo-deny | the same error, with parent `game` |
| 8 | `engine-client` exposes `&RaylibHandle` in a public method, and the Client calls raylib's `get_screen_width()` through it | nothing | compiles, and passes Clippy and cargo-deny |

Case 8 has no C++ counterpart. In the C++ POC, `raylib.h` is included only by the implementation unit `client.cpp`, so the interface `client.cppm` cannot mention a raylib type. In Rust, one file is both interface and implementation, and a public signature may name a dependency's type. The `exported_private_dependencies` lint would flag it, but only with Cargo's unstable `public-dependency` feature (see the last sections). Until then, keeping raylib types out of `engine-client`'s public API is a review rule.

**What it cost:**
- 19 lines of `deny.toml` configuration;
- an extra tool to install and run, `cargo deny check bans`, which belongs in CI or the `jj-ci` gate;
- nothing in the code.

**Assessment:** cheaper than xmake's Lua rules for the dependency rules, and the error messages are clearer; weaker than C++ modules for keeping raylib's types out of the Engine's interface.

The `game::protocol` and `engine_headless::bytes` modules also deny four Clippy lints (`indexing_slicing`, `unwrap_used`, `expect_used`, `panic`), so a panicking `bytes[i]` or `unwrap()` cannot creep into the decoder. That is not a proof that it cannot panic: slice methods such as `copy_from_slice` can. The fuzz test covers the rest.

## Rust specifics

### Where the borrow checker and ownership shaped the design

- **The Server's socket lives in its own struct.** `tell_everyone` iterates over the Match's Players and sends to each. With a `send(&mut self, …)` method on the Server, that loop does not compile: `error[E0502]: cannot borrow *self as mutable because it is also borrowed as immutable`. The socket and its sequence number therefore moved into a `Network` struct, held in a separate field. The loop now borrows `self.match_` for reading and `self.network` for writing, which the compiler accepts because they are distinct fields.
- **The transport hands over owned batches.** `UdpTransport::receive()` returns a `Vec<Datagram>`, like the C++ `receive()`, rather than an iterator borrowing the transport. The Server can then mutate itself while it handles each datagram.
- **A `Frame` borrows its `Window`.** `Window::begin_frame(&mut self)` returns a `Frame<'_>` that ends the Frame when dropped, as the `raylib` crate's `RaylibDrawHandle` does. While a Frame exists, the window cannot start another one or be closed. The C++ `begin_frame()`/`end_frame()` pair has no such check.
- **A `Sound` borrows its `AudioDevice`.** The `raylib` crate ties every audio resource to the device with a lifetime, and the Engine keeps that. A Sound used after its device is dropped is rejected with `error[E0597]: audio does not live long enough`. The crate's `Texture2D` has no such lifetime, so "drop textures before the window" is only a comment in the Engine and an ordering of variables in the Client.
- **The network thread owns what it uses.** It receives its own socket handle (`try_clone`), a `SyncSender` and two `Arc`-counted atomics, moved into its closure; `Drop` stops and joins it. The compiler checks that everything moved into the thread may cross threads (`Send`). raylib's thread token, `RaylibThread`, is not `Send`, so the window cannot leave the main thread ([`raylib` crate, `core/mod.rs`](https://github.com/raylib-rs/raylib-rs)).

### FFI and the `raylib` crate

Our code calls no C function directly: the `raylib` crate wraps them, and the workspace sets `unsafe_code = "forbid"`. The only `unsafe` is the fuzz test's `unsafe impl GlobalAlloc`, which the task's counting allocator requires. Its package relaxes the lint to `deny`, and the one item carries `#[allow(unsafe_code)]` and `SAFETY` comments.

The crate's safe API fell short three times, and each gap got a safe workaround:

1. **No way to flush raylib's draw batch** before reading the screen, which the C++ Engine does with `rlDrawRenderBatchActive()`. Calling that through `raylib::ffi` needs `unsafe`. The Engine enters and leaves an empty scissor mode instead, which flushes the batch in raylib 6.0: `BeginScissorMode` and `EndScissorMode` both call `rlDrawRenderBatchActive`, in `rcore.c`.
2. **No safe way to build a sound from raw samples:** a `Wave` can only come from a file, or from an encoded file held in memory. The Engine writes the samples into an in-memory WAV file (44-byte header) and has raylib decode it.
3. **`Image::export_image` returns nothing**, dropping raylib's success flag. The Engine encodes the PNG in memory with `export_image_to_memory` and writes it with `std::fs::write`, which reports errors.

Other properties of the crate, from its source:
- `raylib::init().build()` panics when no window can be opened, so `Window::open` panics too instead of returning an error.
- `draw_text` panics on a string holding a NUL byte.
- `raylib-sys` always runs bindgen at build time, unless given pre-generated bindings (`nobindgen` with `RAYLIB_BINDGEN_LOCATION`); hence the libclang requirement.
- It builds raylib with the `cmake` crate: in Debug for debug builds of the game, in Release for release builds.

### Compile times

Our code is 1,729 lines of Rust code, tests included, and compiles in 0.5 s from scratch in release. What costs is raylib:
- its build script alone runs for 6.1 s;
- its build-time dependencies (bindgen, two versions of `syn`, `regex`, `clang-sys`, …) account for most of the rest of an 11 s clean build.

That cost is paid once per machine, profile and target, since compiled dependencies stay in the target directory. **Assessment:** day to day, builds are not a concern at this size. The crate is the unit of recompilation, so as the Game grows, splitting it into crates will matter more than splitting files.

### Safety for free, and what still needed discipline

What the compiler checked with no effort from us:
- **Bounds:** an out-of-range index panics instead of reading memory.
- **Data races:** only `Send` values cross into the network thread, and no mutex was needed.
- **Exhaustive handling:** every `Message` variant is handled wherever a `match` has no wildcard (the Client's receive loop, the encoder), so adding a message type breaks the build where it must be handled.
- **Resource lifetimes,** where the `raylib` crate encodes them (`Frame`, `Sound`).
- **No null and no ignored errors:** `Option` instead of null, and errors as values (`Result`, with `?` in the decoder).
- **Integer overflow,** in debug builds, which the fuzz test runs under.

What still needed discipline:
- **Not panicking on hostile input.** Indexing and `unwrap` are bugs there rather than undefined behaviour, but still a denial of service. Module-level Clippy lints and the fuzz test back this up.
- **Drop order** of textures and the window.
- **Keeping raylib out of the Engine's public API** (case 8).
- **Wrapping arithmetic,** made explicit for counters that may overflow (`wrapping_add` on Ticks and sequence numbers).
- **Truncating `as` casts** (`index as u8`, `x as u16`), each commented with why it fits.

## What hurt

- **Gaps in the `raylib` crate's safe API:** the three workarounds above, a constructor that panics, and a texture type not tied to its window. **Assessment:** each is small, but a raylib user in Rust will end up either writing such workarounds or reaching for `unsafe`. The crate's API also differs from raylib's C API, so raylib's own examples do not translate line by line.
- **bindgen at build time.** Every developer machine and CI runner needs libclang: an LLVM install and `LIBCLANG_PATH` on Windows. Cross-compiling needed the MinGW headers passed to it by hand.
- **Build-time weight.** One binding brings 39 third-party crates, all compiled from source on the first build.
- **A deployment-target mismatch on macOS.**
  - The Rust binaries declare macOS 11.0 as their minimum (`otool -l`: `minos 11.0`), but the `cc` crate compiled raylib's C code with `-mmacosx-version-min=26.5`.
  - Without `MACOSX_DEPLOYMENT_TARGET`, `cc` 1.5.1 "defaults to the current Xcode SDK's `DefaultDeploymentTarget`" rather than rustc's (`cc` source, `apple_deployment_target`). No warning was shown.
  - This is harmless when building and running on the same Mac, but a Client built here and given to an older Mac could fail.
  - Setting `MACOSX_DEPLOYMENT_TARGET` for the whole build fixes it, for example in `.cargo/config.toml`'s `[env]`.
- **Gaps in `std`:**
  - No random numbers: 30 lines of SplitMix64 in the Engine, or the `rand` crate.
  - No way to interrupt a thread blocked on a UDP receive. The network thread wakes every 100 ms to check whether it should stop; the C++ POC closes the socket from Asio's thread instead.
- **Windows GNU needed one more workaround than C++.** Rust's standard library for `x86_64-pc-windows-gnu` links winpthreads (`-l:libpthread.a`), which nixpkgs' mcfgthread-based MinGW GCC does not ship. The first link failed with `cannot find -l:libpthread.a`; nixpkgs has it as a separate package.
- **Small frictions:**
  - `match` is a keyword, so the domain's word for a play-through cannot name a module or a variable.
  - A `harness = false` test receives `cargo test`'s name filters as arguments, so the fuzz test then fails with its usage line.
  - `cargo clean -p` cleans only the debug profile unless given `--release`.

## What was pleasant

- **One command builds everything,** including raylib from source, with the compiler version pinned in the repository. No helper script is needed on macOS (the C++ POC needed LLVM 22 from nixpkgs to `import std`), and the toolchain installs itself on the first `cargo` command.
- **Compile times:** 0.5 s for our code from scratch, under half a second for incremental builds, against 3.9–5.5 s and 1.4 s in the C++ POC's logs.
- **The decoder.**
  - `ByteReader` returns `Result<u8, Truncated>`, a `From` conversion turns that into a `DecodeError`, and `?` does the rest.
  - It reads like the wire format, cannot index out of bounds and allocates nothing.
  - It survived 5.1 million fuzzed datagrams.
- **`enum` messages and exhaustive `match`,** instead of `std::variant`, `std::visit` and an `Overloaded` helper. The Server dispatches on `(message, sender)` in one `match`.
- **The borrow checker as a design reviewer:** it caught a real resource-lifetime bug (a Sound outliving its audio device) and pushed the Server into a clearer structure.
- **The standard library's networking:** `UdpSocket` is safe to share between threads, `SocketAddrV4` is a comparable, printable peer key, and `to_socket_addrs` resolves host names. No third-party networking library was needed.
- **Tooling out of the box:**
  - `cargo test`, with unit tests beside the code;
  - `cargo tree` and `--timings`;
  - Clippy, which suggested newer idioms (`is_multiple_of`, `as_chunks`);
  - rustfmt, with no configuration;
  - `cargo deny`.
- **Static binaries by default.** The macOS programs depend on the system only, where the C++ ones need libc++ from a Nix store path. The Rust side of the Windows cross-build was one `rustup target add`.

**Assessment for the team:** the language is the part that has to be learned (ownership, lifetimes, error handling with `Result`), not the build. Teammates who know C++ will recognise RAII and move semantics; what is new is that the compiler checks them.

## Interoperability with the C++ POC

The Rust implementation follows the layout documented in the C++ `protocol.cppm`, and a unit test checks the exact bytes of every message against it. For example, an Accept for Player 2 with sequence 0x01020304 is `52 54 01 02 04 03 02 01 02`.

| Run | Result |
| --- | --- |
| C++ Server, four Rust Clients, the C++ POC's demo script | all 4 join; the leaving and the killed Client are reported to the others; timeout reported 3.06 s after `kill -9`; 0 malformed datagrams apart from the 5 garbage ones; the Rust Client's screenshot shows the 4 Ships |
| Rust Server, four C++ Clients, the same script | the same; timeout reported 3.03 s after the kill; the C++ Client's screenshot shows the 4 Ships |
| What each Client sends first, captured with `nc -u -l` | Rust and C++: the same 16 bytes, two connects (`52 54 01 01 01 00 00 00`, then sequence 2) |
| What each Server answers to a hand-made connect, 0.5 s captured | Rust and C++: the same 549 bytes (`cmp`), an accept then 30 snapshots; in this capture even the Tick numbers matched |

No mismatch was found. The differences are cosmetic:
- the Star-field's stars sit elsewhere (different random generators);
- the Rust Client's `--script` takes only non-negative numbers, where the C++ one also parses negative ones;
- the Rust Client says so when it plays without sound.

The two decoders were not fuzzed against each other.

## The Windows result

**Cross-build from macOS: works.** `bash scripts/build-windows-exe.sh` builds `r-type_server.exe` and `r-type_client.exe` (PE32+, x86-64, console) with the `x86_64-pc-windows-gnu` target and nixpkgs' MinGW-w64 GCC 15.3.0, in 19.2 s from clean. It took two attempts and a few minutes, well inside the 30-minute budget. No Microsoft component, and so no license to accept, was involved.

What was needed, all in the script:

1. `rustup target add x86_64-pc-windows-gnu`, and `x86_64-w64-mingw32-gcc` as the linker.
2. The mcfgthread paths, which the GCC wrapper only knows inside a nix build; the same workaround as the C++ POC.
3. winpthreads (`-L` to nixpkgs' `pkgsCross.mingwW64.windows.pthreads`), for Rust's standard library.
4. The MinGW headers for bindgen, which parses raylib's headers with the host's libclang for the Windows target (`BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu`).

The `cmake` and `cc` crates needed nothing. When the target differs from the host, `cmake` 0.1.58 sets `CMAKE_SYSTEM_NAME=Windows` and `CMAKE_RC_COMPILER` itself, and `cc` finds `x86_64-w64-mingw32-gcc` by its name.

The `.exe` files import only Windows DLLs (list under "Binary sizes"). They were **not run**: no Windows machine was available, and nixpkgs' Wine only supports Linux, so it cannot run them on this Mac.

**Native build on Windows (MSVC): documented, not tested.** The steps are under "Setup from a clean machine" and in the README: Visual Studio 2022 C++ build tools, `rustup-init.exe`, CMake, LLVM with `LIBCLANG_PATH`, then `cargo build --release`.

## Improvements that need non-stable features

Each of these exists only on nightly Rust or behind an unstable Cargo flag today, so the POC does not use them.

- **Private dependencies** (Cargo's `public-dependency`, with rustc's `exported_private_dependencies` lint): would catch case 8, a raylib type in `engine-client`'s public API ([Cargo unstable features](https://doc.rust-lang.org/nightly/cargo/reference/unstable.html)).
- **Sanitizers** (`-Zsanitizer=address` or `thread`, both supported on `aarch64-apple-darwin`): AddressSanitizer for raylib's C code and the FFI boundary, ThreadSanitizer for the network thread and the Tick loop ([unstable book](https://doc.rust-lang.org/nightly/unstable-book/compiler-flags/sanitizer.html)). The C++ POC ran ASan and UBSan.
- **cargo-fuzz** (libFuzzer, coverage-guided), which "requires the nightly compiler" ([rust-fuzz book](https://rust-fuzz.github.io/book/cargo-fuzz/setup.html)): it would find inputs that random and mutated datagrams miss.
- **Miri,** nightly only: it would check the counting allocator's `unsafe` and run the decoder's tests under an interpreter that detects undefined behaviour. It cannot run raylib: it has "no access to most platform-specific APIs or FFI" ([Miri](https://github.com/rust-lang/miri)).
- **`build-std`** and the `immediate-abort` panic strategy: smaller binaries than the 337 KB and 992 KB size-optimised builds.
- **`codegen-backend`** (Cranelift): faster debug builds.
- **`checksum-freshness`:** rebuild decisions based on file contents rather than modification times, useful after version-control operations that touch files without changing them.
- **`std::array::try_from_fn`** (feature `array_try_from_fn`): would build the input history's `[InputState; 3]` with `?` directly.

## Not verified

- Building on Linux, and building natively on Windows with MSVC: steps written from the official documentation, never run.
- Running the `.exe` files: no Windows machine, and no Wine for Apple Silicon macOS in nixpkgs.
- Hearing the sound; playing with the keyboard (all runs were scripted); playing over a real network (all runs used localhost).
- The C++ build times in the tables: taken from the C++ POC's build logs, not re-measured; the C++ report has the authoritative figures.
- Fuzzing the two decoders against each other: they were compared through live runs, byte captures, the layout test and reading the C++ source.
- The effect of the macOS deployment-target mismatch on an older Mac.
- Behaviour after very long runs (Tick and sequence counters wrapping after 2^32).
- Editor support: rust-analyzer was not tried.
