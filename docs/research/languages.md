# Language options for R-Type

Last verified: 2026-09-28.

On 2026-09-28 the evaluator opened the project to languages other than C++ (his examples: Rust and Zig), provided he approves the choice first. Odin is our own addition: it fits the project, but the evaluator has not approved it. This note compares the four candidates against what this project actually demands. Every fact links to its source. Lines marked **Assessment** are judgement, not fact; the POCs are there to confirm or refute them.

## Versions checked

| Item | Latest | Released | Source |
| --- | --- | --- | --- |
| Rust | 1.98.1 | 2026-09-03 | [rust-lang/rust releases](https://github.com/rust-lang/rust/releases) |
| Zig | 0.16.0 (master is 0.17.0-dev) | 2026-04-13 | [ziglang.org download index](https://ziglang.org/download/index.json) |
| Odin | dev-2026-09 (monthly dev releases) | 2026-09-01 | [odin-lang/Odin releases](https://github.com/odin-lang/Odin/releases) |
| SFML | 3.1.0 | 2026-04-16 | [SFML releases](https://github.com/SFML/SFML/releases) |
| SDL | 3.4.16 | 2026-09-02 | [SDL releases](https://github.com/libsdl-org/SDL/releases) |
| raylib | 6.0 | 2026-04-23 | [raylib releases](https://github.com/raysan5/raylib/releases) |
| EnTT | 4.0.0 | 2026-07-23 | [EnTT releases](https://github.com/skypjack/entt/releases) |
| flecs | 4.1.6 | 2026-06-29 | [flecs releases](https://github.com/SanderMertens/flecs/releases) |

## What the project demands, and how each language copes

### 1. Build and dependencies

The subject requires a build system generator and a package manager (Conan, vcpkg or CPM), a build that doesn't touch the system beyond compilers and low-level libraries, no dependency sources copied into the repo, and CI that doesn't re-fetch everything on each commit. This is Part 0, graded at both defenses.

- **C++**: the subject names CMake plus Conan, vcpkg or CPM, which means two tools to wire together, plus CI caching. The evaluator has since told us that a build system with its own package manager counts, and that staying on CMake is the hard path (his reply, 2026-09-28). Two build systems fit that description:
  - **xmake** 3.1.1 (2026-08-27): its package repository has raylib, Asio, SFML, SDL3 and Catch2 ([xmake-repo](https://github.com/xmake-io/xmake-repo/tree/master/packages)).
  - **build2** 0.18.1: its package repository has standalone Asio (`libasio`) but no raylib, and its SFML package was last updated in 2022 ([cppget.org](https://cppget.org), [build2-packaging](https://github.com/build2-packaging)).
- **Rust**: Cargo is the build tool, package manager, lockfile, workspace manager, test runner and doc generator in one. Crates that wrap C or C++ libraries still build them with CMake, though:
  - the `raylib` crate needs CMake, GLFW headers and curl ([raylib-rs README](https://github.com/raylib-rs/raylib-rs));
  - the `sfml` crate needs CMake and a C++ toolchain ([rust-sfml README](https://github.com/jeremyletang/rust-sfml));
  - the `sdl3` crate has `build-from-source`, `static-link` and `use-vcpkg` features ([crates.io](https://crates.io/crates/sdl3));
  - `macroquad` is pure Rust and only needs a few system dev packages on Linux ([macroquad README](https://github.com/not-fl3/macroquad)).
- **Zig**: `build.zig` plus `build.zig.zon`, with dependencies fetched by URL and pinned by content hash; there is no central registry. 0.16 added local package overrides and project-local fetching ([0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html)). The Zig build system compiles C libraries itself: [castholm/SDL](https://github.com/castholm/SDL) builds SDL3 from source without CMake.
- **Odin**: no package manager, by design. Its author argues package managers are a net negative and recommends vendoring dependencies by hand ([gingerBill, 2025-09-08](https://www.gingerbill.org/article/2025/09/08/package-managers-are-evil/)). Instead, the compiler ships a `vendor:` collection ([odin-lang/Odin vendor/](https://github.com/odin-lang/Odin/tree/master/vendor)):
  - raylib with prebuilt libraries for Linux, macOS and Windows;
  - SDL3, with Windows binaries only;
  - ENet, GGPO, miniaudio, box2d, stb, Lua, and more.

  **Assessment**: this clashes with "MUST use a package manager" and with "copying dependency sources is not proper", unless the evaluator counts the vendor collection as part of the SDK.

### 2. Windows and cross-play

Cross-play itself doesn't depend on the language. It depends on a protocol that spells out byte order and field sizes. Building and testing on Windows does depend on it.

- **Zig**: builds Windows executables from Linux or macOS with no extra SDK. It ships mingw-w64 among its bundled libcs ([Zig overview](https://ziglang.org/learn/overview/)).
- **Rust**: Windows is a first-class platform. The MSVC toolchain needs the Visual Studio C++ build tools and a Windows SDK on the Windows machine ([rustup docs](https://rust-lang.github.io/rustup/installation/windows-msvc.html)). `cargo-xwin` (0.23.1, 2026-08-13) builds MSVC-target binaries from Linux or macOS ([crates.io](https://crates.io/crates/cargo-xwin)).
- **Odin**: Windows is a first-class platform, and the vendored raylib ships Windows binaries. I could not confirm a supported way to link Windows executables from Linux or macOS ([install docs](https://odin-lang.org/docs/install/), [issue #4821](https://github.com/odin-lang/Odin/issues/4821)), so plan on building on Windows: your machine, or a CI runner.
- **C++**: MSVC on Windows, GCC or Clang on Linux, every dependency built per platform by the package manager, and compiler divergences to smooth over.

**Assessment**: Windows is cheapest in Zig and Rust, workable in Odin (build on Windows), and most expensive in C++.

### 3. Client: window, sprites, input, audio

- **C++**: SFML 3.1, SDL 3.4 and raylib 6.0, used directly.
- **Rust**, from [crates.io](https://crates.io):
  - `macroquad` 0.4.16 (pure Rust);
  - bindings: `raylib` 6.0.0, `sdl3` 0.20.0, `sfml` 0.25.1;
  - `ggez` 0.10.0;
  - audio crates `kira` 0.12.5 and `rodio` 0.22.2.
- **Zig**:
  - [raylib-zig](https://github.com/raylib-zig/raylib-zig) is tested with raylib 6.0 and Zig 0.16.0;
  - [castholm/SDL](https://github.com/castholm/SDL) requires Zig 0.16.0 or newer.

  Bindings track Zig versions closely, so upgrading Zig can mean waiting for them.
- **Odin**: the vendored raylib 6.0 and SDL3, plus sdl2, glfw and miniaudio, need no install ([vendor/](https://github.com/odin-lang/Odin/tree/master/vendor)).

raylib exists in all four, which makes it the natural common denominator for a like-for-like language POC.

The evaluator accepts bindings to C libraries, and macroquad, which he sees as close to raylib. He rejects ggez, which has game-engine structure.

### 4. A multithreaded UDP server facing hostile input

The subject wants a multithreaded, robust server, and malformed packets must never crash anything, exhaust memory or compromise security.

- **Rust**: `std::net::UdpSocket`, threads and channels in the standard library. Safe code cannot overrun a buffer, and the compiler rejects data races. `mio` 1.2.3 and `tokio` 1.53.1 are there if async is wanted. For game networking, `renet` 2.0.0 is current, while `laminar` has had no release since 2021 ([crates.io](https://crates.io)).
- **C++**: Asio is mature. Safety relies on discipline, sanitizers and fuzzing.
- **Zig**: 0.16 rebuilt all I/O behind a new `Io` interface and moved the sync primitives into it. It also plans more removals from `std.posix` and `std.os.windows`, and its evented networking is unfinished ([0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html)). Bounds and overflow checks are on in Debug and ReleaseSafe builds.
- **Odin**: `core:net` has socket backends for Linux, POSIX, Windows and FreeBSD ([core/net](https://github.com/odin-lang/Odin/tree/master/core/net)). Bounds checking is on by default.

### 5. Binary protocol encoding

- **Rust**: `serde` 1.0.229 (accepted by the evaluator) with `postcard` 1.1.3 or `bitcode` 0.6.9, or hand-written encoding. Avoid `bincode`: it is unmaintained after a harassment incident, and its 3.0.0 release contains nothing but a compile error ([bincode 3.0.0 README](https://crates.io/crates/bincode/3.0.0)).
- **Zig**: compile-time reflection lets a single generic function encode any message struct with explicit endianness.
- **Odin**: endian-specific integer types (`u16le`, `u32be`, …) and `core:reflect`, or hand-written encoding.
- **C++**: hand-written encoding, or libraries such as bitsery and zpp_bits.

### 6. Engine architecture

The evaluator has ruled that if we build an ECS, it must be our own: EnTT, flecs, hecs and bevy_ecs are out. The libraries below are listed for reference only.

- **C++**: EnTT 4.0.0 and flecs 4.1.6 exist; we write our own.
- **Rust**: `hecs` 0.11.1, `bevy_ecs` 0.19.1 and `flecs_ecs` 0.2.2 exist ([crates.io](https://crates.io)); we write our own. **Assessment**: Rust punishes object graphs that share mutable references, which pushes you towards an ECS anyway, and that is the design the subject recommends.
- **Zig and Odin**: a home-made ECS is the usual path. Odin's `#soa` layouts and built-in vector maths suit data-oriented designs.

### 7. Tooling, tests, documentation

- **Rust**: rustfmt, clippy, `cargo test`, rustdoc and rust-analyzer all come with the toolchain.
- **Zig**: `zig fmt`, `zig test` and ZLS.
- **Odin**: `odin test`, `odin doc` and OLS.
- **C++**: clang-format, clang-tidy, a test framework (Catch2, GoogleTest) and Doxygen, each to be chosen and wired.

### 8. C++ only: modules and reflection

C++20 modules, checked on 2026-09-29:

- **CMake 4.4**: named modules work with the Ninja and Visual Studio generators (GCC 14+, Clang 16+, MSVC 14.34+), but `import std` is still experimental behind a flag, and header units are not supported ([cmake-cxxmodules](https://cmake.org/cmake/help/latest/manual/cmake-cxxmodules.7.html)).
- **xmake**: named modules with GCC, Clang and MSVC, header units since 2.7.1, and `import std` ([xmake modules examples](https://xmake.io/examples/cpp/cxx-modules.html)).
- **build2**: named modules and `import std` with GCC, Clang and MSVC; header units with GCC only ([build2 0.17.0 notes](https://build2.org/release/0.17.0.xhtml), [modules with GCC](https://build2.org/blog/build2-cxx20-modules-gcc.xhtml)).

C++26 static reflection (P2996) shipped in GCC 16.1 in April 2026, behind `-std=c++26 -freflection` ([isocpp.org](https://isocpp.org/blog/2026/04/gcc-16.1)). Clang only has an experimental fork ([bloomberg/clang-p2996](https://github.com/bloomberg/clang-p2996)), and I found no MSVC release with it. Using reflection therefore means GCC 16 on every platform, which on Windows means MinGW.

### 9. Grading and ecosystem risk

- **C++**: none. The subject was written for it.
- **Every other language**:
  - it needs the evaluator's approval;
  - its package manager counts if the build system integrates it (evaluator, 2026-09-28), which covers Cargo and Zig's `build.zig.zon`;
  - differences in difficulty are not compensated in grading, unless benchmarks or the comparative study show the choice is the more relevant one for the project;
  - the evaluators' fluency in the language is unknown.
- **Zig**: pre-1.0, with standard-library breakage on every release (0.16's I/O rework is the latest example). The project also moved from GitHub to Codeberg ([ziglang/zig on GitHub](https://github.com/ziglang/zig)).
- **Odin**: pre-1.0, with monthly dev releases and no package manager. It was not on the evaluator's list. He has since said that its `vendor:` collection counts as a package manager only if we manage its versions (the packages in it maintained and updated).

### 10. Learning cost

Still unknown: it depends on what the three of you already know.

## Where each language starts to hurt (assessment, to be tested by the POCs)

- **C++**:
  - the plumbing: CMake, a package manager, CI caching and Windows builds;
  - memory safety in the packet decoder;
  - compile times with heavy template libraries.
- **Rust**:
  - the first weeks, while the borrow checker fights shared game state;
  - C-backed crates still need CMake;
  - compile times.
- **Zig**:
  - churn: each release breaks the standard library, bindings are pinned to compiler versions, and documentation is thin;
  - the networking APIs were just rewritten.
- **Odin**:
  - anything beyond `vendor:` has to be vendored by hand;
  - a small community and ecosystem;
  - the package manager requirement.

## Where each language is ahead (assessment)

- **C++**:
  - no approval risk;
  - the richest set of libraries;
  - the evaluators' home ground.
- **Rust**:
  - Cargo;
  - memory and thread safety exactly where the subject worries (untrusted packets, a multithreaded server);
  - easy Windows builds;
  - tooling out of the box.
- **Zig**:
  - Windows executables from any machine;
  - C libraries compiled without CMake;
  - reflection-based serialization;
  - explicit allocators, useful for bounding memory use.
- **Odin**:
  - the quickest start for a game: raylib, ENet and miniaudio come with the compiler;
  - a small, simple language;
  - vector maths built in.

## Questions for the evaluator

Answered (his reply, 2026-09-28):

- **Package manager**: a build system with an integrated package manager counts. That covers xmake, build2, Cargo and Zig.
- **Grading**: differences in difficulty between languages are not compensated. A choice has to be justified by benchmarks or the comparative study.

Answered (his second reply, received by 2026-09-30):

- **Choosing a language other than C++**: language-dependent constraints are part of the comparative study. For Rust (or any language other than C++), we must hand him a study, and he must validate it before development starts.
- **Odin**: its `vendor:` collection counts as a package manager that vendors, and "the difference is minimal". If we use only vendor libraries, he validates the package manager requirement only if we manage versions, meaning the packages in it are maintained and updated.
- **Grading**: he adapts the constraints to each language.
- **Documentation**: ADRs and comparative studies are enough.
- **Client libraries**: bindings to a C library such as raylib or SDL are fine. macroquad is accepted, since it resembles raylib; ggez is not, since it has game-engine structure.
- **ECS**: if we build one, it must be our own. EnTT, flecs, hecs and bevy_ecs "do all the work", flecs above all.
- **Serialization**: serde is fine.
