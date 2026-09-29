# C++ POC report

Built and measured on 2026-09-29/30, on an Apple M5 (10 cores, 32 GB) under macOS 26.5.2. The slice is the one in `docs/research/language-pocs.md`; how to build and run it is in [README.md](README.md). Facts link to their source or come from runs on this machine; lines marked **Assessment** are judgement.

## Summary

- Everything in the spec runs on macOS: headless Server, raylib Client with four coloured Ships and a three-layer Star-field, generated "pew", 3 s timeout, malformed datagrams counted, and a fuzz test (100,000 datagrams, no crash, no allocation in the decoder, clean under AddressSanitizer and UndefinedBehaviorSanitizer).
- `import std` does **not** work with Apple clang 21. It works with LLVM clang 22.1.8 and libc++ from nixpkgs, but only after lining up three environment variables by hand. GCC 15.3 handles it out of the box, but cannot build raylib on macOS.
- xmake and xrepo were the pleasant part: one line per dependency, raylib built from source in about half a minute from nothing, a lock file, and working Windows cross-builds.
- Modules make the Engine/Game boundary almost free to enforce, and keep raylib and Asio out of every file but two.
- Most of the time went into toolchain defects: a compiler crash in GCC 15.3 and 16.2, a race between two xmake rules, a sanitizer runtime that hangs on macOS 26, and a language server that must match the compiler exactly.
- Windows `.exe` files were cross-built from the Mac with MinGW-w64 GCC; they are not run yet. The native MSVC build is documented but untested.

## Versions used

| Item | Version | Source |
| --- | --- | --- |
| xmake | 3.1.1 (nixpkgs), latest release (2026-08-27) | `xmake --version`, [releases](https://github.com/xmake-io/xmake/releases) |
| xmake-repo | commit `33751c1f`, pinned in `xmake-requires.lock` | lock file |
| raylib | 6.0, built from source by xrepo (CMake 4.3.4 and Ninja 1.13.2, both fetched by xrepo) | [xmake-repo raylib](https://github.com/xmake-io/xmake-repo/blob/master/packages/r/raylib/xmake.lua) |
| Asio | 1.36.0, the newest in xmake-repo; upstream is at 1.38.2 | [xmake-repo asio](https://github.com/xmake-io/xmake-repo/blob/master/packages/a/asio/xmake.lua), [asio tags](https://github.com/chriskohlhoff/asio/tags) |
| Compiler | nixpkgs LLVM clang 22.1.8, libc++ 22.1.8, nixpkgs Apple SDK 14.4 | `clang++ --version` |
| Windows cross compiler | nixpkgs MinGW-w64 GCC 15.3.0 (mingw-w64 14.0.0, `mcf` threads) | `x86_64-w64-mingw32-g++ -v` |
| Also tried | Apple clang 21.0.0 (Command Line Tools, SDK 26.5), nixpkgs LLVM 21.1.8, GCC 15.3.0, GCC 16.2.0 | see "Modules" |

## What was built

| Part | Files | Content |
| --- | --- | --- |
| Engine, headless | `engine/headless/` | `engine.bytes` (little-endian writer and bounds-checked reader), `engine.net` (UDP transport over Asio: network thread, bounded inbox, IPv4 endpoints), `engine.time` (fixed step on the steady clock) |
| Engine, client | `engine/client/` | `engine.client`: window, rectangles, text, textures, keys, audio device, sounds from PCM, screenshots, over raylib |
| Game | `game/` | `game.protocol` (seven messages, encoder, decoder), `game.match` (Players, Ship movement within 1280×720, 3 s silence limit) |
| Server | `server/main.cpp` | Tick loop at 60 Hz on the main thread, network thread in the Engine; dispatch, snapshots to every Player every Tick, counters |
| Client | `client/` | Frame loop, one input per Tick with the last three input states, snapshots, Star-field, Ships from `r-typesheet42.gif` (compiled in), the "pew" (square-wave sweep, synthesized), `--host`, `--port`, `--script`, `--frames`, `--screenshot` |
| Test | `tests/protocol_fuzz.cpp` | 10,000 round trips, then 100,000 datagrams: half random bytes of length 0 to 1500, half mutated valid packets |

The protocol and its validation rules are described at the top of `game/protocol.cppm`. Each datagram carries an 8-byte header (protocol id, version, type, sequence). Every integer is written and read byte by byte. Every read is bounds-checked. Unknown types, out-of-range values (Player index, Ship count, button bits, input order) and trailing bytes are rejected. The only count, the Ship count, is checked against 4 before use, and nothing is sized by the datagram, so the decoder never allocates. The fuzz test checks that by counting calls to a replaced `operator new`.

The two threads of each program hand over through the transport: the network thread appends to a mutex-protected inbox capped at 256 datagrams, and the Tick loop drains it once per Tick. Sends are posted to the network thread through an Asio strand, because Asio documents shared sockets as unsafe except for concurrent synchronous calls ([basic_datagram_socket](https://think-async.com/Asio/asio-1.36.0/doc/asio/reference/basic_datagram_socket.html)), and the strand guarantees that the sends queued before shutdown go out before the socket closes ([io_context::strand](https://think-async.com/Asio/asio-1.36.0/doc/asio/reference/io_context__strand.html)).

### Verified on this Mac

- Server plus four scripted Clients: all four joined, and one of them saved [screenshot.png](screenshot.png).
- `kill -9` on one Client: the Server logged `Tick 754: Player 1 timed out` 3.05 s later, and the two remaining Clients logged `Player 1 left the Match`.
- A Client quitting normally sends a disconnect: `Player 4 left` on the Server, and the others were told.
- Five garbage datagrams sent with `nc`: the Server's counter went to `5 malformed`, and it kept running.
- `protocol_fuzz`: round trips 10,000/10,000; 100,000 datagrams, of which 93,562 rejected and 6,438 accepted (mutations that still form a valid packet); 0 allocations in `decode()`. That run had no seed argument, so it drew a random seed. With `100000 42`, the arguments the other POCs' reports use, it gives 93,597 rejected and 6,403 accepted (re-run on 2026-10-01). The same test under ASan and UBSan (`xmake f -m asan`) reports nothing.
- The Server binary links only `libc++` and `libSystem` and contains no raylib symbol (`otool -L`, `nm`); the Client links AppKit, OpenGL, IOKit, CoreVideo and more.

## Setup from a clean machine

xmake itself: `curl -fsSL https://xmake.io/shget.text | bash` on Linux and macOS, `winget install xmake`, `scoop install xmake` or the installer on Windows, or a distribution package (`brew`, `dnf`, `pacman`, Ubuntu PPA) ([xmake quick start](https://xmake.io/guide/quick-start.html)). This POC used xmake 3.1.1 from nixpkgs. xrepo needs nothing else: it fetched CMake and Ninja itself when they were missing (see the cold build below).

### macOS (tested)

1. Install Nix. Apple clang cannot `import std` (see "Modules"), and Apple's C++ support page lists no modules support at all ([Apple](https://developer.apple.com/xcode/cpp)).
2. `bash scripts/xmake-macos-nix.sh f -y --toolchain=clang`, then `bash scripts/xmake-macos-nix.sh`. The script runs xmake with LLVM 22.1.8 from nixpkgs in an ephemeral `nix shell`.

Homebrew's LLVM with `xmake f --toolchain=llvm --sdk=<prefix>` is what xmake's own error message suggests; it was not tried.

### Linux (not tested)

1. A distribution whose GCC is 15 or later: GCC 15 added the `std` and `std.compat` modules, as experimental support ([GCC 15 changes](https://gcc.gnu.org/gcc-15/changes.html)).
2. raylib's development packages, from the [raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux). On Fedora: `sudo dnf install alsa-lib-devel mesa-libGL-devel libX11-devel libXrandr-devel libXi-devel libXcursor-devel libXinerama-devel libatomic`. On Ubuntu: `sudo apt install libasound2-dev libx11-dev libxrandr-dev libxi-dev libgl1-mesa-dev libglu1-mesa-dev libxcursor-dev libxinerama-dev libwayland-dev libxkbcommon-dev`.
3. `xmake f -y`, then `xmake`.

xrepo's raylib depends on xrepo packages for X11. Those look for system packages first (`libx11` declares `apt::libx11-dev` and `pacman::libx11`), and are built from source otherwise ([xmake-repo libx11](https://github.com/xmake-io/xmake-repo/blob/master/packages/l/libx11/xmake.lua)). Whether Fedora's packages are picked up is not verified.

### Windows (not tested)

1. Visual Studio 2022 17.10 or later, with the "Desktop development with C++" workload. `import std` needs 17.5 or later ([Microsoft](https://learn.microsoft.com/en-us/cpp/cpp/tutorial-import-stl-named-module)). 17.10 is the first STL that accepts a standard header `#include`d before `import std` in the same file, which `engine/headless/net.cpp` does through Asio ([STL changelog](https://github.com/microsoft/STL/wiki/VS-2022-Changelog)).
2. xmake, as above.
3. `xmake f -y`, then `xmake`: xmake picks MSVC by default.

## Measurements

All on the machine above, release mode (`-O3`, stripped), LLVM 22.1.8. Times are wall-clock.

### Build times

| Build | Time |
| --- | --- |
| Clean, from nothing: xrepo clones xmake-repo, downloads Ninja, Asio, CMake and raylib, builds raylib; then the project | 24.6 s + 4.8 s, and 30.4 s + 4.7 s (two runs, fresh directories each time; the package part depends on the network) |
| Clean project, packages already installed | 1.6 s configure + 5.4 s, 5.1 s, 5.1 s build (three runs) |
| Incremental, after editing one Game implementation unit (`game/match.cpp`) | 0.47 s, 0.47 s, 0.50 s: one compile, one archive, three links |
| Incremental, after editing one Game module interface (`game/protocol.cppm`) | 1.60 s, 1.59 s: eleven compile steps, since every importer and the BMIs above it are rebuilt |
| No-op | 0.21 s |
| Clean project for Windows with MinGW GCC 15.3, packages installed | 1.5 s configure + 7.6 s build |

The builds were run with a PATH stripped of the user's own tools, so xrepo had to fetch CMake and Ninja as a clean machine would.

### Binary sizes

| Program | macOS arm64 | Windows x86-64 (MinGW, static C++ runtime) |
| --- | --- | --- |
| `r-type_server` | 204,672 B | 1,400,320 B |
| `r-type_client` | 807,616 B (raylib linked statically) | 3,226,112 B |
| `protocol_fuzz` | 122,608 B | 1,299,968 B |

The macOS programs load `libc++` dynamically from the Nix store, so they only run where that store path exists. The Windows programs only import system DLLs: `KERNEL32`, `WS2_32`, `msvcrt` and `ntdll` for the Server, plus `GDI32`, `USER32`, `SHELL32` and `WINMM` for the Client.

### Lines of code

Code lines, without comments and blank lines ([tokei](https://github.com/XAMPPRocky/tokei) 15.0.0):

| Part | Code | Comments |
| --- | --- | --- |
| Engine, headless | 207 | 38 |
| Engine, client | 182 | 16 |
| Game | 363 | 39 |
| Server program | 139 | 7 |
| Client program | 314 (5 of them C) | 23 |
| Tests | 128 | 11 |
| `xmake.lua` | 76 | 12 |
| Total | 1,409 | 146 |

## How the Engine/Game boundary and the headless Server are enforced

Three mechanisms, the first two free:

1. **Targets.** Each part is an xmake target (`engine-headless`, `engine-client`, `game`, the two programs, the test), and a target sees only the modules and packages of the targets it depends on.
2. **Private packages.** raylib is a private package of `engine-client`, Asio of `engine-headless`. A dependent links them, since xmake passes a static library's link settings on, but cannot `#include` them: the Client program has no path to `raylib.h` either.
3. **Two xmake rules** (19 lines of Lua in `xmake.lua`). `rtype.engine`: an Engine target may only depend on Engine targets. `rtype.headless`: a headless target may not use raylib, and may only depend on headless targets. The Server, the Game, the headless Engine and the fuzz test are headless.

Every violation tried, on a copy of the project, stops the build:

| Violation | Error |
| --- | --- |
| `import game.protocol;` in Engine code | `error: <engine-headless> missing game.protocol dependency for module engine/headless/net.cpp` |
| `import engine.client;` in the Server | `error: <r-type_server> missing engine.client dependency for module server/main.cpp` |
| `#include <raylib.h>` in the Server | `fatal error: 'raylib.h' file not found` (while scanning module dependencies) |
| `#include <raylib.h>` in the Client program | the same: raylib is private to the Engine |
| `add_deps("engine-client")` on the Server | `error: r-type_server must stay headless, but depends on engine-client` |
| `add_packages("raylib")` on the Server | `error: r-type_server must stay headless, but uses raylib` |
| `add_deps("game")` on `engine-client` | `error: Engine target engine-client must not depend on game` |

What it cost:

- The 19 lines of Lua, written once.
- Keeping raylib out of the Engine's interface: the Engine declares its own `Color`, `Rect` and `Key`, converts them (about 25 lines), and holds raylib's textures and sounds behind a pointer to an implementation (`Texture::Impl`, `Sound::Impl`; `UdpTransport::Impl` does the same for Asio). That costs one heap allocation per texture, sound or socket, and a few lines of boilerplate each.
- The Game had to stay free of drawing: the Star-field and the sprite mapping live in the Client program. A Game part with client-only code would need a `game-client` target of its own.

**Assessment**: cheap. The boundary is structural rather than a convention, and a mistake fails at configure or scan time with a readable message.

## Modules

### Per compiler

| Compiler | `import std` | This project | What happened |
| --- | --- | --- | --- |
| Apple clang 21.0.0 (Xcode Command Line Tools) | No | No | No `libc++.modules.json` or `std.cppm` is shipped (`clang -print-library-module-manifest-path` prints `<NOT PRESENT>`). xmake: `warning: libc++.modules.json not found! maybe try to add --sdk=<PATH/TO/LLVM> or install libc++`, then `error: missing std dependency for module greet`. The tools have no `clang-scan-deps` either. |
| nixpkgs LLVM 21.1.8, libc++ 21.1.8 | Yes, with three variables | Yes | See below. Its AddressSanitizer runtime hangs before `main()` on macOS 26. |
| nixpkgs LLVM 22.1.8, libc++ 22.1.8 | Yes, with three variables | **Yes, used** | Same setup as 21; its sanitizers work. |
| nixpkgs GCC 15.3.0 (native, macOS) | Yes, out of the box | No | xrepo cannot build raylib's GLFW Cocoa backend with GCC: `fatal error: Carbon/Carbon.h: No such file or directory`. |
| nixpkgs GCC 16.2.0 (native, macOS) | Yes | Not tried | Tried on a small repro only (the compiler crash below). |
| nixpkgs MinGW-w64 GCC 15.3.0 (cross, to Windows) | Yes | Yes, after two fixes | See "The Windows result". |
| MSVC | Documented since VS 2022 17.5 | Not tested | No Windows machine available. |

Getting nixpkgs' clang to `import std` took three environment variables, now set by `scripts/xmake-macos-nix.sh`:

- `COMPILER_PATH=<libc++>/lib`. xmake finds `std.cppm` through `clang -print-library-module-manifest-path`. The nixpkgs wrapper keeps libc++ in its own store path, where the driver does not look, so it answers `<NOT PRESENT>`. `COMPILER_PATH` (or `-B`) adds that directory to the driver's search.
- `SDKROOT` and `CPLUS_INCLUDE_PATH`. The compile wrapper injects the SDK and the libc++ 22 headers, but xmake runs `clang-scan-deps` on the same command line, and the scanner does not go through the wrapper. Without them, nixpkgs' wrapped scanner picked libc++ 21.1.6 headers from another SDK and failed on `'inttypes.h' file not found`.
- Without any scanner, xmake falls back to its own, which deliberately strips `-std=c++*` before preprocessing (xmake 3.1.1, `rules/c++/modules/clang/scanner.lua`). libc++'s `std.cppm` then fails on `operator""d`: `invalid suffix on literal; C++11 requires a space between literal and identifier`. On clang, a working `clang-scan-deps` is therefore mandatory.

### A compiler crash in GCC

GCC 15.3 (native and MinGW) and GCC 16.2 crash with `internal compiler error: Segmentation fault: 11` when a file uses a defaulted **friend** `operator==` of a struct exported by a module it imports. The member form compiles. A 10-line repro:

```cpp
// point.cppm
export module point;
import std;
export struct Point {
    std::uint16_t x = 0;
    std::uint16_t y = 0;
    friend bool operator==(const Point&, const Point&) = default; // member form: fine
};

// main.cpp
import std;
import point;
int main(int argc, char*[]) { return Point{1, 2} == Point{std::uint16_t(argc), 2} ? 0 : 1; }
```

All three GCCs run on the macOS host, so a Linux GCC may behave differently; not checked, and no matching report came up in a quick search. The POC uses member comparisons everywhere.

### Includes and `import std`

- In a module unit, third-party headers must go in the global module fragment (`module;` then the `#include`s), which is necessarily before `import std;`. Only two files include anything: `engine/headless/net.cpp` (Asio) and `engine/client/client.cpp` (raylib).
- Clang documents `#include` after `import` as not well supported ("Known issues" in [Standard C++ Modules](https://clang.llvm.org/docs/StandardCPlusPlusModules.html)). In a probe, though, clang 22.1.8 accepted `import std;` followed by the Asio and raylib includes, and the program ran. MSVC accepts only the include-first order, and only since VS 2022 17.10 ([STL changelog](https://github.com/microsoft/STL/wiki/VS-2022-Changelog)). The POC keeps includes first everywhere.
- `import std` exports no macros: `stderr`, `stdout`, `SIGINT`, `assert` and `errno` are unavailable without an `#include` ([Microsoft](https://learn.microsoft.com/en-us/cpp/cpp/tutorial-import-stl-named-module)). The programs log through `std::println(std::cerr, ...)`.
- Moving raylib and Asio into implementation units also dodges a known raylib problem on Windows: `windows.h`, which Asio includes there, declares `CloseWindow` and `ShowCursor` and defines `DrawText`, all of which clash with raylib's. The fix raylib's maintainers give is to never include both in one translation unit ([discussion #3945](https://github.com/raysan5/raylib/discussions/3945), [issue #1217](https://github.com/raysan5/raylib/issues/1217)).

### xmake and modules

- It works without ceremony: `.cppm` files with `{public = true}` are visible to dependents, `std` is built once per configuration and reused, and dependency scanning is automatic.
- A target whose files are all `.cpp` and which has no module-bearing dependency does not get modules: `fatal error: module 'std' not found` until `set_policy("build.c++.modules", true)`.
- **A race between the `utils.bin2c` rule and module scanning.** The Client first `#include`d the generated sprite header from a module. On fresh builds, the scanner sometimes ran before the header existed: `'r-typesheet42.gif.h' file not found`, in 2 of 6 fresh builds, and the dev builds never showed it. bin2c orders itself before the module builder, not before the scanner. Adding that order in a rule of our own did not help (5 of 10 failed). Moving the bytes into a C file, which the C++ scanner skips, did: 12 of 12 passed. See `client/ship_sheet.c`.
- `mode.asan` is deprecated in xmake 3.1.1 in favour of the `build.sanitizer.*` policies, so `xmake.lua` defines its own `asan` mode.

### Editor support

- clangd works if it reads xmake's compilation database made for it (`xmake project -k compile_commands --lsp=clangd build`, which clangd finds in `build/` on its own, per the [clangd docs](https://clangd.llvm.org/installation)), after a build, and if it is exactly the compiler's version. clangd 22.1.8 resolved every import of the POC. clangd 21.1.8, from the same machine, refused clang 22's BMIs: `module file '.../std.pcm' uses a newer format that cannot be read`.
- clangd's own module support (`--experimental-modules-support`) does not combine with xmake's database: the database already carries `-fmodule-file=` flags, and clangd then fails with `precompiled file '.../engine.net.pcm' cannot be loaded due to a configuration mismatch`.
- Only `clangd --check` was run; an interactive editor session was not tried.

## What hurt

- **Getting `import std` at all on macOS.** Apple's compiler cannot, nixpkgs' needs three variables that come from reading its wrapper scripts, and each wrong combination fails differently. On a clean Linux with GCC 15, or with MSVC, the documentation suggests this is mostly free; not verified.
- **Compiler and runtime defects, found one after another.** The GCC crash on a defaulted friend comparison. LLVM 21's AddressSanitizer runtime hangs before `main()` on macOS 26 (a dyld change), which only LLVM 22.1.8 fixes (llvm-project #182943, backported in #188913, per [this Doris pull request](https://github.com/apache/doris/pull/68595)); the process spun at 100% CPU for ten minutes before it was sampled. And libc++ 21.1.8 lacks C++23's `std::ranges::shift_right` (`std::shift_right` works).
- **A nondeterministic build failure** (the bin2c race), invisible in incremental builds and found only by timing cold builds.
- **Editor support is fragile**: the language server must match the compiler to the patch release, and needs a build first.
- **Windows specifics with MinGW**: libstdc++ keeps `std::print`'s Windows console support in `libstdc++exp`, which must be linked by hand ([GCC 14 changes](https://gcc.gnu.org/gcc-14/changes.html)); nixpkgs' cross wrapper needs `mcfgthread`'s paths passed in.
- **Safety is by discipline.** The decoder checks the Ship count before `std::span::first(count)`, but nothing makes that check mandatory: forgetting it compiles cleanly, and only the fuzzer under ASan would notice, if it happened to hit the case.
- **Template error walls.** One wrong `std::ranges::find` produced about 25 lines of unsatisfied-constraint notes before the actual problem.
- **Smaller surprises.** xmake-repo's Asio is two releases behind upstream. xmake retried one download with TLS verification disabled after a certificate error; its source says it only does that where a checksum verifies the file afterwards (`modules/net/http/download.lua`), which is the case for package archives. xmake also runs a daily background `git clone` for usage statistics unless `XMAKE_STATS=false` ([environment variables](https://xmake.io/guide/extras/environment-variables.html)).

## What was pleasant

- **xrepo.** One `add_requires` line per dependency. From an empty machine it fetched CMake, Ninja, Asio and raylib and built raylib in 25 to 30 s, with no system install. The lock file pins versions and the repository commit, for every platform built. Cross-compiling raylib for Windows needed no package change at all.
- **The boundary** (see above): mostly structural, and 19 lines of Lua for the rest.
- **Modules as encapsulation.** raylib and Asio appear in two implementation units; everything else imports small, clean interfaces. Rebuilding after an implementation change takes half a second.
- **Modern C++ reads well here**: `std::expected` for decoding, `std::span`, `std::variant` with `std::visit`, designated initializers, defaulted comparisons, `std::format`/`std::println`. The encoder and decoder are 164 code lines (`game/protocol.cpp`), plus 144 for the message types and the byte reader and writer. `-Wall -Wextra` stayed silent on clang 22 and GCC 15.
- **Checking is possible.** Replacing `operator new` in the test proves the decoder does not allocate. With LLVM 22, ASan and UBSan cost one configure flag.
- **Windows from the Mac**, in about 15 minutes including two fixes, giving single-file `.exe`s with no DLL to ship.

## The Windows result

- **Cross-build from macOS: works, not run.** `xmake f -p mingw` with nixpkgs' MinGW-w64 GCC 15.3 (in the binary cache for this Mac, no compile needed) built all three programs as PE32+ x86-64 executables, self-contained (see "Binary sizes"). Three things were needed:
  1. passing `mcfgthread`'s include and library paths to the nixpkgs wrapper (`fatal error: mcfgthread/gthr.h: No such file or directory`, `cannot find -lmcfgthread`);
  2. linking `stdc++exp` (`undefined reference to std::__open_terminal(std::basic_streambuf<char>*)`, from `std::println`);
  3. the GCC crash workaround above.

  `-static` in `xmake.lua` removes the need to ship `libstdc++-6.dll` and friends. The programs could not be run on this Mac: nixpkgs has no Wine for aarch64-darwin. They wait for a test on the Windows machine, with the Server on either side, since the protocol spells out byte order and sizes.
- **Native MSVC build: documented, not tested** (see "Setup"). Risks worth watching on the first try: `/W4` warnings nobody has seen, and Asio's standard headers followed by `import std` in `engine/headless/net.cpp`, which Microsoft supports only in that order and calls a temporary workaround.

## Improvements that need non-stable features

None of these was used. Support is as listed on the [GCC](https://gcc.gnu.org/projects/cxx-status.html) and [Clang](https://clang.llvm.org/cxx_status.html) status pages on 2026-09-30.

- **Static reflection** (C++26, P2996; GCC 16 behind `-freflection`, not in Clang or MSVC). The wire format could be derived from each message's members: one generic encoder and decoder instead of fourteen `write_body`/`read_body` overloads, seven `type_of` overloads and the decoding `switch` in `game/protocol.cpp`, with no way for reader and writer to drift apart. `to_string(DecodeError)` would come from enumerator names. Value limits, such as a Player index below 4, would still need annotations.
- **`#embed`** (C++26, P1967; GCC 15; clang 22.1.8 accepts it in C++ as an extension, with `warning: #embed is a Clang extension`; MSVC not found). `client/ship_sheet.c`, the bin2c rule, the `extern "C"` declarations and the race workaround would become one array in `client/sprites.cppm`.
- **Contracts** (C++26, P2900; GCC 16, not in Clang). Preconditions such as `pre(player < max_players)` on `Match::receive` and `Match::leave`, which today rely on `std::array::at` and `std::optional::value` throwing.
- **`std::inplace_vector`** (C++26, P0843; standard library support not checked). `Snapshot`'s `ship_count` plus `std::array<ShipState, 4>` would become one container that cannot disagree with itself, and `Match::step` could return one instead of a `std::vector`.
- **Standard library hardening** (C++26, P3471). Bounds-checked `operator[]` on `span`, `array` and `vector` as a portable mode; today it takes vendor-specific macros.
- **Erroneous behaviour for uninitialized reads** (C++26, P2795; GCC 16, not in Clang). The decoder zero-initializes everything by hand today.
- **Pattern matching** (proposed, not in C++26) would replace `std::visit` with the `Overloaded` helper in both programs.

## Not verified

- Any build on Linux or with MSVC, and running the `.exe` files.
- A Server and Clients on different machines, or across operating systems.
- Whether the GCC crash also happens with a Linux-hosted GCC.
- Interactive editor use beyond `clangd --check`.
- The sound: the `pew` code path ran (the scripted Clients fire every two seconds) without error, but nobody listened for it.
