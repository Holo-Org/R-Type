# Language POCs

Status: all four POCs done, and compared side by side in [language-pocs-comparison.html](language-pocs-comparison.html). Last updated: 2026-10-06.

One POC per language, run one at a time, in this order: C++, Rust, Zig, Odin. The evaluator has not ruled Odin out: he accepts its `vendor:` collection as a package manager only if we manage its versions. The Odin POC therefore has to show how that would work.

## What every POC builds

The same small slice of R-Type in every language, so that the differences come from the language and its tooling, not from the scope.

- **Layout**, following [ADR 0001](../adr/0001-engine-game-boundary.md) (the ADR lives in the main repository):
  - a thin Engine library, with a headless part (UDP transport, byte reader and writer) and a client part (window, drawing, input, sound);
  - the Game on top (messages and rules);
  - two programs, a Server and a Client.

  The Server must not link raylib, and the build must enforce it.
- **Protocol**:
  - connect, accept, input, snapshot and disconnect messages;
  - explicit little-endian encoding, with every read checked;
  - a test that throws 100,000 random datagrams at the decoder, which must neither crash nor allocate without bound.
- **Server**:
  - headless, UDP;
  - a network thread plus a 60 Hz Tick loop;
  - up to 4 Players;
  - a Player silent for 3 s is dropped, and the others are told.
- **Client**:
  - raylib 6.0;
  - a scrolling Star-field, and the four Ships in distinct colours from the provided sprite sheets;
  - arrow keys send inputs, and the screen draws the latest snapshot;
  - a generated firing sound.
- **Netcode vehicle**: inputs up, snapshots down (approach B in the netcode simulator). This is not the netcode decision.
- **Build**: the language's own tooling. Try to produce a Windows `.exe` from the Mac where the toolchain allows it, to test on the Windows machine; otherwise, document the Windows build.
- **Stable features only**: only features available on stable channels, on every target platform. C++20 modules are the one exception. Anything newer that would help (C++26 static reflection, nightly-only Rust features, Zig master-only APIs, …) goes into the report as a documented improvement instead.

## Per language

| | Toolchain | Build and packages | raylib | Networking |
| --- | --- | --- | --- | --- |
| C++ | GCC, Clang or MSVC; C++23 with modules and `import std` | xmake 3.1.1 with xrepo | xrepo `raylib` | standalone Asio (xrepo `asio`) |
| Rust | 1.98 stable | Cargo workspace | `raylib` crate 6.0.0 (builds raylib with CMake) | `std::net` and threads |
| Zig | 0.16.0 | `build.zig` and `build.zig.zon` | raylib-zig (tested with raylib 6.0 and Zig 0.16.0) | `std.Io` |
| Odin | dev-2026-09 | none; the compiler's `vendor:` collection | `vendor:raylib` (6.0) | `core:net` and `core:thread` |

## Report, one per POC

- Setup steps from a clean machine.
- Clean and incremental build times.
- Lines of code per part (Engine, Game, programs), and binary sizes.
- How the Engine/Game boundary is enforced, and what it cost.
- What hurt, and what was pleasant.
- The Windows result.
- Improvements that need non-stable features.

## Progress

| POC | Workspace | Status |
| --- | --- | --- |
| C++ | `poc-lang-cpp` | done, report in `prototypes/lang-cpp/REPORT.md` |
| Rust | `poc-lang-rust` | done, report in `prototypes/lang-rust/REPORT.md` |
| Zig | `poc-lang-zig` | done, report in `prototypes/lang-zig/REPORT.md` |
| Odin | `poc-lang-odin` | done on dev-2026-09, then moved to dev-2026-10; report in `prototypes/lang-odin/REPORT.md`, version management of `vendor:` included |

Each POC is pushed to its own branch, `poc/lang-<language>`, as two commits: the code, then the report.
