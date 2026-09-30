# Language POC report: Zig

The third of the four language POCs (C++, Rust, Zig, Odin) described in `docs/research/language-pocs.md`. Built and measured on 2026-09-30 and 2026-10-01. The work stopped overnight and resumed the next morning, and where the two days' figures differ, both are given. Judgement is marked **Assessment**; everything else was measured here or comes from the cited source. How to build and run it is in [README.md](README.md).

## Summary

- **The whole slice works, and speaks the C++ and Rust POCs' protocol byte for byte.**
  - It is a headless Server and a raylib Client, on an Engine split into the modules `engine_headless` and `engine_client`, built by one `build.zig`.
  - Four scripted Clients play together. A killed Client is dropped 3.03–3.05 s after the kill and the others are told. Garbage datagrams are counted and ignored, and a fifth Client is refused.
  - The Zig Server plays with C++ Clients and with Rust Clients, Zig Clients play on both other Servers, and one Match mixed all three.
  - The three Servers' answers to a hand-made connect are byte-identical.
- **The fuzz test draws the Rust POC's datagrams draw for draw, and its tallies equal the Rust report's exactly.**
  - With `100000 42`, both report 6,243 accepted, 46,610 bad protocol ids, and so on. This is strong evidence that the two decoders classify datagrams alike.
  - 5,100,000 datagrams went through Debug and ReleaseSafe builds, with 0 allocations and no panic.
  - The compiled decoder references no allocation function at all.
- **Downloads dominate the first build, and every later edit rebuilds whole programs.**
  - A cold build took 33 s this morning, of which about 10 s were downloads (87 MB). On a slow connection the evening before, it took 203–411 s.
  - A clean build with the packages downloaded takes 15.5–16.4 s.
  - Any edit to our code recompiles every program that includes the edited module: 5.4 s in ReleaseSafe, 1.5 s in Debug. The Rust POC's figures are 0.43–0.47 s and 0.29–0.33 s.
- **Zig enforces half of ADR 0001 on its own, and `build.zig` can enforce the rest.**
  - Zig refuses a module that `build.zig` did not declare for the importing module, and any file outside the module's directory.
  - It accepts every declared import, even a cycle, and it has no private fields.
  - 32 lines in `build.zig` (run whenever the build is configured) and an 83-line compile-time check of the client Engine's public API caught every violation tried. That includes case 8, which nothing caught in the Rust POC.
- **Windows `.exe` files cross-build with one flag.** It worked on the first try, in 16 s from clean, with nothing to install and no licence to accept. The Server imports only `ntdll.dll` and `KERNEL32.dll`. The files were not run.
- **What hurt:**
  - the downloads: raylib's repository at its tag, a 104 MB package of Xcode headers, and packages only web builds use;
  - whole-program rebuilds;
  - a young toolchain: a standard-library function that does not compile, a built-in fuzzer that does not compile in Debug, ThreadSanitizer builds that crash on this Mac, and deprecations without warnings;
  - macOS binaries tied to the build machine's macOS version.
- **What was pleasant:**
  - the Windows build;
  - one tool, with no CMake and no libclang;
  - the compile-time codec;
  - `try` with error sets that merge;
  - `std.Io`'s cancellable network thread and bounded queue;
  - code that allocates nothing per Tick or per datagram.

## Versions used

| Tool | Version | Where from |
| --- | --- | --- |
| Machine | Apple M5, 10 cores, 32 GB; macOS 26.5.2 (25F84) | |
| Zig | 0.16.0; LLVM 21, and `zig cc` based on Clang 21.1.8 (release notes) | nixpkgs `zig_0_16` |
| ZLS | 0.16.0 | nixpkgs `zls` |
| raylib-zig | branch `devel`, commit `8758f4cd3a5ae0df6941c4715257223d34c5ad3e` (2026-07-18), hash `raylib_zig-6.0.0-KE8RECZ8BQDm-txuospkpZHbJ6DNpacUF7D88RWQ_qAe` | GitHub, pinned in `build.zig.zon` with `zig fetch --save` |
| raylib | 6.0 (tag `6.0`, commit `dbc56a87`), hash `raylib-6.0.0-whq8uCSwLgWWeF3ec3dbG6Rr36SLFL-s2WJ1Q_2E22Bb` | GitHub, through raylib-zig |
| Other packages fetched | raygui `3b285584`, emsdk 4.0.9, zemscripten `70bdafc4` (raylib-zig's) and `3fa4b778` (raylib's), mach's xcode-frameworks `8a1cfb37` | through raylib-zig's and raylib's `build.zig.zon` |
| C compiler and linker | Zig's own; the Xcode Command Line Tools 26.6 provide the SDK the Client's link needs | |
| tokei | 15.0.0 | nixpkgs |
| llvm-objdump, llvm-strip | 21.1.8 | nixpkgs `llvm` |
| otool, nm, strip | Command Line Tools 26.6 | `/usr/bin` |
| Nix, nixpkgs | Lix 2.95.2; nixpkgs 26.11 (the system registry's pinned `nixpkgs`) | |

- **Zig.** 0.16.0 was released on 2026-04-13. Master was at 0.17.0-dev.2338 on 2026-09-29 and was not used ([download index](https://ziglang.org/download/index.json)).
- **raylib-zig.** It has no tagged release for raylib 6.0: its newest tags are v5.5 and v5.6-dev. Its README says "Bindings tested on raylib version 6.0 and Zig 0.16.0" ([raylib-zig](https://github.com/raylib-zig/raylib-zig)).
- **Isolation.** Everything ran inside `nix shell nixpkgs#zig_0_16 nixpkgs#zls nixpkgs#tokei`, with `PATH` cut down to that shell's store paths plus `/usr/bin:/bin:/usr/sbin:/sbin`. Sources were copied to a scratch directory, and both Zig caches and the install prefix were there too. `~/.cache/zig` ended identical to its listing before the work: 4,605 entries, with the same names, sizes and dates.
- **Codeberg.** Codeberg, Zig's home, was down on the evening of 2026-09-30. That delayed one lookup in the compiler's source (how dependencies are fetched) to the next morning.

## What was built

| Part | Module | Contents |
| --- | --- | --- |
| Engine, headless | `engine_headless` | `bytes` (little-endian writer and checked reader, plus the compile-time codec), `net` (UDP over `std.Io.net`: a network thread started with `io.concurrent`, a bounded `std.Io.Queue` inbox of 256 datagrams, a drop counter, host name resolution), `time` (fixed step on the monotonic clock) |
| Engine, client | `engine_client` | `Window`, `Frame`, `Texture`, `AudioDevice`, `Sound`, `Color`, `Rect`, `Key`, `Error`; raylib values kept as bytes; `api_check.zig` |
| Game | `game` | `protocol` (the messages as a tagged union, the encoder and decoder derived from their types), `match` (the Match rules) |
| Server program | `r-type_server` | the 60 Hz Tick loop; logs joins, leaves, timeouts and a counters line every 5 s |
| Client program | `r-type_client` | three-layer Star-field, Ships from `r-typesheet42.gif` compiled in with `@embedFile`, keyboard or `--script`, a synthesized "pew", `--frames` and `--screenshot` |
| Fuzz test | `protocol_fuzz` | 10,000 round trips, then 100,000 random and mutated datagrams by default, generated as the Rust POC does; allocation counting; a panic handler that prints the datagram |

Behaviour follows the other two POCs:
- **Wire format:** the same.
- **Decoder checks, in the same order.**
  - The decoder reads a fixed-size body only once all its bytes are known to be there, so a short datagram is `Truncated` even when it also holds a bad value.
  - The snapshot is read one Ship at a time, as both other decoders do.
- **Everything else:** the same Match rules, command-line options and log lines.
- **One difference:** an error is printed as its Zig name, for example `cannot listen on UDP port 4242: AddressInUse`, where Rust prints the operating system's message.

The 12 unit tests check:
- the byte reader and writer, and the derived encoding;
- the UDP transport and the fixed-step clock;
- the exact bytes of every message, every rejection reason, and the Match rules.

`match` is not a Zig keyword, so the Match lives in `game/match.zig`.

## Verified on this Mac

| Check | Result |
| --- | --- |
| `zig build` | my first draft had 2 compile errors, then clean. The first test build found 2 more (both described under "Comptime for the codec" and "The churn") |
| `zig fmt --check` | passes, with nothing to reformat |
| `zig build test` | 14/14: the 12 tests, plus the two blocks that pull the files into the test build |
| Server and four scripted Clients (the shared demo script) | 4 Players join; the Client with `--frames 420` leaves and the others are told |
| Screenshot | `screenshot.png`: four Ships in the sheet's four colours, the Star-field, "Player 4" and "4/4 Players" |
| `kill -9` on a Client | "Player 1 timed out" 3.03 s after the kill (3.05 s the day before); the others logged "Player 1 left the Match" |
| 5 garbage datagrams from `nc` | counted as 5 malformed and ignored |
| A fifth Client | "r-type_client: the Match is full", exit status 1 |
| Fuzz, `zig build fuzz -- 100000 42`, Debug | 10,000 round trips, 0 mismatches; 100,000 datagrams, 0 allocations, the Rust report's tallies exactly; same output in ReleaseSafe |
| Fuzz, 5,000,000 datagrams, seed 7 | ReleaseSafe 1.14 s (×3), ReleaseFast 1.11 s (×2, plus 1.44 s under load); 0 mismatches, 0 allocations, the same output on both days |
| Decoder in an object file of its own | its only outside references are the stack protector's two symbols, plus `memcpy` in Debug |
| A removed range check, as a test of the panic path | the ReleaseSafe run stopped on the first datagram that needed the check, printed it (41 bytes) and exited with status 134 |
| Interoperability | in both directions with C++ and Rust, plus a mixed Match; Server answers byte-identical (see below) |
| Windows cross-build | three `.exe` files importing only Windows DLLs; not run |

As in the other POCs, the sound was generated and played on each fire without error, but nobody listened to it. Every run used `--script`, so the keyboard was not exercised.

## Setup from a clean machine

**What every platform needs:**
- **Zig 0.16.0**, one archive from [ziglang.org](https://ziglang.org/download/) (52 MB for `aarch64-macos`, 55 MB for `x86_64-linux`, 97 MB for `x86_64-windows`, per the download index).
  - It compiles raylib's C code itself and brings its own C library headers and linker. No CMake, no libclang, no other compiler.
  - It does not even need `git`: with only Zig on `PATH`, `zig fetch` of a `git+https` package worked, so Zig speaks the git protocol itself.
- **On the first build, 87 MB of downloads** (7 packages, see "Build times").

**macOS** (tested):

1. Install the Xcode Command Line Tools: `xcode-select --install`.
   - With them hidden (`PATH` holding only Zig, empty environment), the Server and the fuzz test built and ran, and raylib's C code compiled. But the Client's link failed with `error: unable to find framework 'Foundation'. searched paths: none`, and the same for CoreServices, CoreGraphics, AppKit and IOKit.
   - raylib's `build.zig` downloads mach's xcode-frameworks package "for cross compilation", but sets its paths on raylib's library only, not on the program that links it.
2. Install Zig from ziglang.org, or use `nix shell nixpkgs#zig_0_16`.

**Linux** (not tested): Zig, plus the development packages of the X11 libraries raylib's `build.zig` links (`X11`, `Xrandr`, `Xinerama`, `Xi`, `Xcursor`). For Ubuntu or Fedora, see the lists in the [raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux).

**Windows** (not tested natively): unpack the Zig archive, put it on `PATH`, run `zig build`. Zig's default ABI for Windows is `gnu` (`std.Target.Abi.default`, `lib/std/Target.zig` line 912), which builds with the MinGW-w64 libraries Zig ships: no Visual Studio, no Windows SDK.

**Assessment:** the lightest setup of the three POCs so far.
- C++ needed LLVM 22 from nixpkgs and three variables to `import std`.
- Rust needed CMake, plus libclang for bindgen.
- Zig needs one archive, and on macOS the same Command Line Tools as Rust.

## Measurements

### Build times

**What was timed.** Wall-clock times of `zig build -Doptimize=ReleaseSafe`, which builds both programs and the fuzz test, like the other POCs' default builds.
- They were taken inside the nix shell, on a scratch copy, on the final sources, on 2026-10-01 unless noted.
- That morning the machine had background load from other applications (load average 3–7). The same compile-bound measurements on 2026-09-30, with no load noted, were within 4 % and mostly faster. They are given under the table.
- The Rust and C++ columns come from their reports and were not re-measured.

| Build | Zig (runs) | Rust, from its report | C++, from its report |
| --- | --- | --- | --- |
| Cold: empty global and local caches, no `zig-pkg/` (downloads, then the build runner, compiler-rt, raylib and our three programs) | 33.23, 33.06, 33.19 s; on 2026-09-30 evening, over a slow connection: 411.15, 203.09, 244.38 s | 13.53, 12.24, 12.86 s | 24.6 s + 4.8 s, 30.4 s + 4.7 s (packages, then project) |
| Downloads alone, `zig build --fetch=all` (7 packages, 87.4 MB) | 10.52, 10.09, 10.14, 12.49 s | 0.98 s (`cargo fetch`) | |
| `zig build --fetch` (the 6 non-lazy packages, 70.2 MB) | 8.37, 8.91, 9.39 s; on 2026-09-30: 214.53, 156.97, 197.38 s | | |
| Clean, packages downloaded (local cache emptied: build runner, raylib and our programs rebuilt) | 15.46, 16.29, 16.37 s, of which compiling `build.zig` takes 3.42 s | 11.27, 11.58, 10.80, 10.96 s | 1.6 s configure + 5.4, 5.1, 5.1 s (packages stay built) |
| Our code only: a comment edited in `engine/headless/root.zig`, which all three programs import, so all three recompile entirely while raylib and the build runner come from the cache | 5.37, 5.48, 5.54 s | 0.51, 0.51, 0.52 s (our six crates) | |
| Edit to a Game implementation detail (a spawn position in `game/match.zig`) | 5.41, 5.41, 5.39 s; 3 programs | 0.47, 0.44, 0.44, 0.43 s; 4 crates | 0.47, 0.47, 0.50 s (`game/match.cpp`) |
| Edit to a public Game type (a method, then a constant, then two more methods, added to `ShipState`, used by Server and Client) | 6.46, 5.41, 5.52, 5.47 s; 3 programs | 0.45, 0.46, 0.44, 0.45 s | 1.60, 1.59 s (`game/protocol.cppm`) |
| No-op | 0.229, 0.230, 0.230 s | 0.05 s (×3) | 0.21 s |
| Debug: clean; implementation edit; public edit; no-op | 7.26, 7.28, 7.40 s; 1.52, 1.50, 1.51 s; 1.51, 1.66, 1.68 s; 0.222, 0.223, 0.223 s | 9.05 s; 0.30, 0.29 s; 0.33, 0.32 s; 0.06 s | |
| Windows cross-build, clean, ReleaseSafe, all three programs | 15.93, 16.02, 16.14 s; the first one on this machine, which also builds Windows runtime pieces into the global cache: 23.51, 29.15, 27.99 s | 19.22 s (40 crates) | 1.5 s configure + 7.6 s |

The same series on 2026-09-30, on sources that differed only in the client Engine's compile-time API check:

| Build | Times on 2026-09-30 |
| --- | --- |
| Clean | 16.32, 15.80, 15.83 s |
| Our code only | 5.28, 5.36, 5.34 s |
| Implementation edit | 5.31, 5.32, 5.32 s |
| Public type edit | 5.39, 5.32, 5.35 s |
| No-op | 0.226, 0.225, 0.250 s |
| Debug clean | 7.07–7.14 s |
| Debug edits | 1.42–1.45 s |
| Windows, clean | 16.58–16.76 s |
| Windows, first | 22.64–25.30 s |

One morning Windows run under load took 32.87 s and was redone.

**What the caches hold:**
- **Global cache** (`~/.cache/zig` by default; scratch here):
  - each downloaded package, recompressed as `p/<hash>.tar.gz`;
  - compiler-rt and other runtime libraries;
  - the ZIR of every source file.
- **Local cache** (`.zig-cache/`, next to `build.zig` by default): the build runner compiled from `build.zig`, raylib, and our programs.
- **`zig-pkg/`**: the unpacked packages, next to `build.zig`.

There is no `zig build clean`. "Clean" above means emptying the local cache only: it rebuilds the build runner, raylib and the programs, but keeps the downloads and compiler-rt. It is closest to `cargo clean` in the Rust POC.

**Where the cold build's time goes.**
- The downloads take about 10 s on a fast connection.
- The rest is mostly the clean build: 3.4 s for the build runner, then raylib (7 s) and our three programs (4–6 s each), compiled in parallel.
- Downloads and builds do not overlap: raylib's `build.zig` asks for its lazy `xcode_frameworks` package only when it runs, so Zig fetches that package in a second round, after the first configure.
- Last night, the same 87–91 MB took 3–7 minutes to arrive.

**Why our code costs 5.4 s.**
- **The program is the unit of recompilation.** Without incremental compilation, Zig compiles each program as one unit holding all its Zig code, ours and the parts of the standard library it uses, and LLVM optimises it whole.
- **There is no precompiled standard library.** Rust links a precompiled one.
- **The whole module counts.** An edit to any file of the `game` module recompiled `protocol_fuzz` too, though it never uses the Match.
- **Private or public makes no difference.** An implementation detail and a public type edit cost the same.
- **Undoing an edit does not hit the cache.** Back to a state already built, it took 5.30 s again: the cache keeps one result per compilation and its options, and checks the input files against it.

**Incremental compilation** is experimental in 0.16.0 and "remains disabled by default" ([release notes](https://ziglang.org/download/0.16.0/release-notes.html)), so it is kept out of the table. With `-fincremental`, the Debug rebuild after the spawn edit took 1.51 s, no gain here, and a no-op took 1.54 s. The programs it built ran.

**Debug on Apple Silicon also goes through LLVM.** The release notes call 0.16's aarch64 backend "still a work-in-progress", while the x86 backend "remains the default when compiling in Debug mode". So the Debug times above are not what a teammate on an x86-64 machine would see; that was not measured.

### Binary sizes

ReleaseSafe builds. "Stripped" means `strip` run on a copy, or `llvm-strip` for the `.exe` files. The Rust and C++ columns are the Rust report's own measurements.

| Binary | Zig, as built | Zig, stripped | Rust, as built | Rust, stripped | C++, as built | C++, stripped |
| --- | --- | --- | --- | --- | --- | --- |
| `r-type_server` (macOS) | 475,840 B | 402,328 B | 536,144 B | 414,312 B | 204,672 B | 204,712 B |
| `r-type_client` (macOS) | 1,274,256 B | 1,058,600 B | 1,294,496 B | 1,074,600 B | 807,616 B | 745,208 B |
| `r-type_server.exe` | 860,672 B | 860,672 B | 1,279,791 B | 906,752 B | 1,400,320 B | 1,400,320 B |
| `r-type_client.exe` | 2,841,600 B | 2,841,600 B | 4,702,050 B | 3,290,624 B | 3,226,112 B | 3,226,112 B |

`llvm-strip` removed nothing from the `.exe` files: Zig writes their debug information to separate `.pdb` files (2.5 MB and 7.0 MB). `protocol_fuzz` is 477,280 B on macOS and 857,088 B as an `.exe`.

Other modes, which drop the bounds and overflow checks:

| Binary | ReleaseFast | stripped | ReleaseSmall | stripped |
| --- | --- | --- | --- | --- |
| `r-type_server` (macOS) | 414,400 B | 369,224 B | 166,096 B | 154,344 B |
| `r-type_client` (macOS) | 1,074,816 B | 892,584 B | 710,880 B | 613,384 B |
| `r-type_server.exe` | 781,824 B | | 445,440 B | |
| `r-type_client.exe` | 2,417,152 B | | 1,744,896 B | |

The Rust report's size-optimised variant gave a 336,592 B Server and a 992,208 B Client.

What is linked dynamically:
- **Zig Server (macOS):** `/usr/lib/libSystem.B.dylib` only. `nm` finds 0 symbols matching `InitWindow`, `glfw`, `rlgl` or `gl…`, against 1,406 in the Client.
- **Zig Client (macOS):** Foundation, CoreServices, CoreGraphics, AppKit, IOKit, CoreFoundation, `libobjc` and `libSystem`. The OpenGL framework is not among them. raylib and Zig's runtime are linked statically.
- **Minimum macOS version:** every native build declares this Mac's version, `minos 26.5.2`.
  - `-Dtarget=aarch64-macos.14.0` built a Server declaring 14.0.
  - The Client then failed to link (frameworks not found), with or without `--sysroot` pointing at the SDK.
- **`.exe` files:**
  - The Server imports `ntdll.dll` and `KERNEL32.dll` only: Windows networking in 0.16 uses the AFD driver directly, "without ws2_32.dll dependency" (release notes).
  - The Client imports `KERNEL32`, `ntdll`, `USER32`, `GDI32`, `SHELL32`, `WINMM` and 12 `api-ms-win-crt-*` DLLs of the Universal C Runtime, which "is included as part of the operating system in Windows 10 or later" ([Microsoft](https://learn.microsoft.com/en-us/cpp/windows/universal-crt-deployment)).

### Lines of code

tokei 15.0.0, code lines only. Zig keeps unit tests in the source files, as Rust does. The "without unit tests" column subtracts the test blocks, counted with the same rule as tokei. tokei does not read `.zon` files, so `build.zig.zon` was counted by hand with that rule.

| Part | C++ | Rust | Rust without unit tests | Zig | Zig without unit tests |
| --- | --- | --- | --- | --- | --- |
| Engine, headless | 207 | 313 | 252 (30 of them the random generator) | 351 | 270 (87 of them the compile-time codec) |
| Engine, client | 182 | 198 | 198 | 226 (83 of them the API check) | 226 |
| Game | 363 | 570 | 408 | 369 | 266 |
| Server program | 139 | 135 | 135 | 114 | 114 |
| Client program | 314 | 349 | 349 | 305 | 305 |
| Tests | 128 | 164 (fuzz) + 223 (unit) | | 222 (fuzz) + 184 (unit) | |
| Build description | 76 (`xmake.lua`) | 123 | | 130 (`build.zig` 108, 32 of them the layering check; `build.zig.zon` 22) | |
| Helper scripts | 14 | 18 | | 0 | |

The Zig fuzz test is longer than Rust's because of the allocation counting (about 50 lines) and the panic handler. Zig needed no random generator of its own: `std.Random.SplitMix64` is the algorithm the Rust POC wrote by hand.

### Fuzz tallies, next to C++ and Rust

All three ran with `100000 42`.
- **Zig reproduces the Rust test's datagrams.** It uses the same SplitMix64, the same bounded draws and the same order of draws. Where Rust evaluates the right-hand side of an assignment before the index, so does Zig: per the Rust Reference, "The assigned value operand is evaluated first", and for compound assignment on primitives "the right hand side is evaluated first" ([Rust Reference](https://doc.rust-lang.org/reference/expressions/operator-expr.html)). So its column equals Rust's exactly.
- **C++ draws different datagrams** (it uses `std::mt19937`), so only its proportions compare.
- **The C++ column comes from the C++ and Rust reports**, which both give this run.

| | C++ | Rust | Zig |
| --- | --- | --- | --- |
| Round trips, mismatches | 10,000, 0 | 10,000, 0 | 10,000, 0 |
| Accepted | 6,403 | 6,243 | 6,243 |
| Too long | 10,024 | 9,979 | 9,979 |
| Truncated | 16,744 | 16,719 | 16,719 |
| Bad protocol id | 46,536 | 46,610 | 46,610 |
| Bad version | 3,150 | 3,050 | 3,050 |
| Unknown message type | 2,365 | 2,346 | 2,346 |
| Value out of range | 3,747 | 3,690 | 3,690 |
| Trailing bytes | 11,031 | 11,363 | 11,363 |
| Allocations in `decode()` | 0 | 0 | 0 |
| Panics | not applicable | 0 | none: a panic would have ended the run |

## How the Engine/Game boundary and the headless Server are enforced

**By Zig, with nothing to configure:**
- **Declared imports only.** A file can `@import` a module only if `build.zig` put it in its own module's import table. raylib is in the Client's compilation, through `engine_client`, yet `@import("raylib")` in the Client's code fails.
- **No path outside the module.** A file cannot `@import` a file outside its module's directory, not even one in `zig-pkg/`.
- **A program links what its module graph links.** The Server's graph is its root, `engine_headless` and `game`. `otool -L` lists `libSystem` alone, and `nm` finds no raylib, GLFW or OpenGL symbol.

**Not by Zig:**
- **Any declared import is accepted, including a cycle.** `engine_headless` and `game` importing each other builds: unlike Cargo, Zig has no rule against cycles between modules.
- **An unused import is not even checked.** An `@import("game")` that nothing uses compiles, because Zig only analyses what is referenced.
- **No private fields.** A struct field is always public, and a public declaration can re-export raylib. Private fields were proposed and the issue was "closed as not planned" on 2021-10-13 ([ziglang/zig#9909](https://github.com/ziglang/zig/issues/9909)).

**By `build.zig`, for what Zig accepts.** `checkLayering`, 32 lines, walks the import tables of every module the programs reach, each time the build is configured, and stops at the first import that breaks a rule:
- raylib may only be imported by `engine_client`;
- `engine_client` only by the Client program;
- `game` only by the two programs and the fuzz test.

**By `engine/client/api_check.zig`, for the client Engine's public API.**
- It is a compile-time walk of every public declaration and the types it mentions: fields, parameters, results, pointers and so on.
- It fails the build if a type comes from raylib-zig.
- Zig names a type after the file that declares it, not its module, so the check is given raylib-zig's file names: `raylib.Texture`, `rlgl.rlRenderBatch`.
- It refuses those names wherever they appear, generic arguments included.

**The violations tried**, the same as in the Rust report, each on a scratch copy:

| # | Violation | Caught by | Message |
| --- | --- | --- | --- |
| 1 | Engine code uses the Game: `@import("game").protocol.max_players` in `engine/headless/net.zig` | Zig | `error: no module named 'game' available within module 'engine_headless'`. An `@import("game")` that nothing uses compiles |
| 2a | `engine_headless` declares the Game, a cycle | `build.zig` | `error: ADR 0001: engine/headless/root.zig may not import "game": the Engine knows nothing about the Game`. Without the check, Zig builds it, even with the Engine using the Game |
| 2b | `engine_client` declares the Game and uses it | `build.zig` | `error: ADR 0001: engine/client/root.zig may not import "game": the Engine knows nothing about the Game`. Without the check, it builds |
| 3 | Server code uses the client Engine without declaring it | Zig | `error: no module named 'engine_client' available within module 'root'` |
| 4 | The Server declares `engine_client` and opens a Window | `build.zig` | `error: ADR 0001: server/main.zig may not import "engine_client": only the Client program draws: the Server and the Game stay headless`. Without the check, it builds: `otool -L` then lists 8 libraries (AppKit and Foundation among them), and `nm` finds 388 symbols matching `InitWindow` or `glfw` |
| 5 | Server code uses raylib directly | Zig | `error: no module named 'raylib' available within module 'root'` |
| 6 | Client program code uses raylib directly, around the Engine | Zig | the same, although raylib is in the Client's compilation: imports are per module |
| 7 | The Client program declares raylib, to use it directly | `build.zig` | `error: ADR 0001: client/main.zig may not import "raylib": raylib stays behind the Engine's client part`. Without the check, it builds |
| 7b | The Game declares raylib | `build.zig` | `error: ADR 0001: game/root.zig may not import "raylib": raylib stays behind the Engine's client part`. Without the check, it builds: the Server then holds no raylib code (0 symbols), but loads 7 libraries, AppKit among them, instead of `libSystem` alone |
| 8a | `engine_client` re-exports raylib (`pub const raylib = rl;`), and the Client calls `engine.raylib.setWindowTitle` | API check | `error: root.raylib exposes raylib, from raylib.zig, which this module keeps hidden`. Without the check, it compiles |
| 8b | A public method returns raylib's texture, and the Client calls raylib-zig's own `draw` method on it, with raylib's `.white` | API check | `error: root.Texture.raw exposes fn (*const root.Texture) raylib.Texture, from raylib.zig, which this module keeps hidden` |
| 8c | A public method returns an rlgl type, `rl.gl.rlRenderBatch` | API check, second version | `error: root.Frame.loadBatch exposes fn (*root.Frame, i32, i32) rlgl.rlRenderBatch, from rlgl.zig, which this module keeps hidden`. The first version of the check let this through |
| — | Importing another part by relative path: `@import("../engine/client/root.zig")` in the Server, `@import("../zig-pkg/raylib_zig-…/lib/raylib.zig")` in the Client | Zig | `error: import of file outside module path` |

**Case 8 matters more in Zig than in Rust.** raylib-zig puts raylib's functions on its types as methods. A raylib value reachable from the Engine's API therefore lets the Client call raylib without importing it: 8b drew a texture that way.

**What the Engine pays for it.**
- Because fields are always public, `Texture` and `Sound` keep raylib's values as byte arrays, with private conversions.
- Without the check, case 8 compiles, as in Rust. With it, the build stops.

**The first version of the check was wrong.**
- It recognised raylib's types by a `raylib.` prefix and stopped at types named `std.…`.
- A probe showed that `@typeName` gives `raylib.Texture`, `rlgl.rlRenderBatch`, `root.Color` for the Engine's own `root.zig`, and `mem.Allocator` for `std.mem.Allocator`.
- So it missed rlgl types (case 8c), and its standard-library stop never matched.
- The second version takes raylib-zig's six file names, matches them anywhere in a type's name, and walks only the Engine's own types.

**What it cost:**
- 32 lines of `build.zig` and 83 lines of compile-time Zig (79 in `api_check.zig`, 4 at its call site);
- nothing to install, and nothing extra to run: both checks are part of every `zig build`, and a no-op build still takes 0.23 s;
- raylib-zig's file names, listed in `engine/client/root.zig`, to keep in step with raylib-zig.

**Assessment:** the most complete enforcement of the three POCs, since it is the only one that catches case 8. It also costs the most lines, about 115 against 19 for xmake's rules or `deny.toml`. It is ordinary Zig, which teammates can read and debug. Its weak spot is that it relies on type names, which this POC got wrong at first.

## Zig specifics

### Module imports and the boundary

`build.zig` is where the module graph is declared: `addImport`, or the `imports` field of `createModule`. From there:
- an `@import` of anything not declared fails, and a path outside the module's directory fails;
- the program links exactly what its graph links;
- the gaps (cycles, wrong but declared imports, public fields) are listed above.

### Explicit allocators

**Where they showed up.** `UdpTransport.open(gpa, io, port)` heap-allocates the transport, about 300 KB, mostly the inbox. Juicy Main, the 0.16 form of `main`, hands every program a general-purpose allocator and an arena (the arena serves to read the arguments).

**What they made visible.**
- No allocation happens per Tick or per datagram, because every place that would allocate would have needed an allocator in its signature.
- The transport copies datagrams into a fixed ring of 256 slots, allocated once. The Rust and C++ transports allocate a buffer per received datagram, and C++ also one per send.
- `Match.step` returns the dropped Players as a 4-bit set, where Rust returns a `Vec` and C++ a `std::vector`.
- The Star-field and the "pew" live in fixed arrays.
- Zig's [overview](https://ziglang.org/learn/overview/) states the convention: "Any functions that need to allocate memory accept an allocator parameter".

**Is it a guarantee?** `decode(datagram: []const u8) DecodeError!Packet` takes no allocator, but that is not a guarantee: `std.heap.page_allocator`, `c_allocator` or `smp_allocator` can be reached from anywhere, without a parameter. So the POC measures it, twice.

1. **At run time, the fuzz test counts calls to the C library's allocation functions.**
   - On macOS and Linux, every allocator of Zig's standard library ends up in either the `malloc` family (`c_allocator`) or `mmap` (`page_allocator`, `smp_allocator`, `DebugAllocator`), per `lib/std/heap.zig` and `PageAllocator.zig`.
   - The test defines `malloc`, `calloc`, `realloc`, `posix_memalign`, `aligned_alloc` and `mmap` itself, counts each call made by its own thread, and forwards it with `dlsym(RTLD_NEXT, …)`.
   - Before fuzzing, it checks that the counter sees a `page_allocator` and a `c_allocator` allocation. A blind counter would always read 0.
   - Result: 0 counted calls during `decode()`, over 5,100,000 datagrams.
   - What it does not prove: inputs the fuzzing never produced, and memory handed out again by an allocator that already holds it. A warmed-up `smp_allocator`, an arena or a `FixedBufferAllocator` over a static buffer makes no counted call.
2. **Statically, by compiling the decoder alone into an object file**, with safety failures turned into traps so the panic handler stays out.
   - Its only outside references are `___stack_chk_fail` and `___stack_chk_guard`, plus `memcpy` in Debug.
   - No path from the decoder reaches any function that obtains memory, for any input.
   - It does not cover a decoder taking memory from a static buffer, which would be bounded anyway.

**Panics.** In Debug and ReleaseSafe, a failed check panics and the process ends: a Zig panic cannot be caught as Rust's `catch_unwind` caught them.
- The fuzz test installs a panic handler (`std.debug.FullPanic`) that prints the datagram being decoded, then lets the default handler print the stack trace and abort.
- So "0 panics" means the run completed.
- With a range check removed on purpose, the ReleaseSafe run stopped at the first 41-byte snapshot that needed it, printed it in hex, and exited with status 134.

### Comptime for the codec

**No message has a hand-written encoder or decoder.**
- `ByteWriter.write` and `ByteReader.read` derive both from the types at compile time: integers little-endian, enums as their tag, packed structs as their backing integer, arrays element by element, struct fields in declaration order.
- A message type adds only a `validate` function where values have limits: the Player index, the input ticks newest first.
- Packed-struct padding bits named `_` must be zero, which rejects unknown button bits.
- `decode` dispatches with `switch (kind) { inline else => |tag| … }`: one branch per message type, generated at compile time.
- Only the snapshot, whose length varies, spells out its encoding (19 lines).

**How much code.**
- The Game's codec is 66 lines: encode 16, decode 17, the header 6, value checks 8, the snapshot 19.
- The Rust POC has 122 (`encode`, `decode` and four readers), plus a 5-line `From` impl. The C++ POC's `protocol.cpp` has 152, without `to_string`.
- The Engine pays 87 lines of generic codec once. In total, for seven messages, that is no fewer lines than Rust.
- The saving is per message: a new fixed-size message costs its struct and maybe a `validate`, with no reader or writer.

**Readability of its errors.** Two deliberate mistakes:
- A `f32` field added to `ShipState` gives `error: no wire encoding for f32`, twice (encoder and decoder). The reference trace points to the snapshot's `writeTo`, but not to the field.
- A message type added to the enum but not to the union gives `error: enum field 'pause' missing from union`, at the union, with a note at the enum field. That is exhaustiveness for free.

Two errors from development were less clear:
- A function returning `usize`, called once at run time from a test, had both branches of an `if` analysed. Its `@compileError` then fired as "Record has no fixed wire size" for a type that has one. Returning `comptime_int`, which forces compile-time evaluation, fixed it.
- `seen ++ [_]type{T}` inferred a pointer-to-array type: `error: expected type '*const [2]type', found '[]const type'`.

**Assessment:** the codec is short and the dispatch is exhaustive. The price is that field order is the wire format: reordering a struct's fields changes the protocol silently, and only the exact-bytes unit test would notice.

### Safety checks in Debug and ReleaseSafe

**What is checked.** Bounds, integer overflow, `@intCast` ranges, unwrapping a null optional, `unreachable` and `assert`, and inactive union fields all panic in Debug and ReleaseSafe.

**raylib's C code is checked too.** Zig compiled it with `-fsanitize=undefined -fsanitize-trap=undefined` in ReleaseSafe, as `--verbose-cc` shows: `zig build-exe --help` documents `-fno-sanitize-c` as "Disable C undefined behavior detection in safe builds". Nothing trapped in any run.

**During development, no safety check fired in our code**, over every run and 5.1 million fuzzed datagrams in Debug and ReleaseSafe. They proved their worth on the deliberately broken decoder above. That bug, in ReleaseFast, would be undefined behaviour instead.

**What they cost here.**
- The 5,000,000-datagram fuzz run takes 1.14 s in ReleaseSafe and 1.11 s in ReleaseFast.
- The ReleaseSafe Server is 15 % bigger than the ReleaseFast one: 475,840 against 414,400 B.

**Checks that do not depend on the build mode.** The decoder's own bounds checks are code: `ByteReader` returns `error.Truncated`, so they hold in ReleaseFast too.

### `std.Io` in 0.16

**What 0.16 brought.** It moved all I/O behind an `Io` interface. Its threaded implementation is "feature-complete and well-tested", and "Io.Evented does not yet implement networking" (release notes). UDP is there:
- `IpAddress.bind(io, .{ .mode = .dgram, .protocol = .udp })` returns a `Socket` with `send`, `receive`, `receiveTimeout` and `receiveManyTimeout`;
- `IncomingMessage.flags.trunc` reports an oversized datagram;
- `HostName.lookup` resolves names into an `Io.Queue`.

There was no gap to work around.

**What made the code simpler than Rust's.**
- **The network thread is cancellable.** It is an `io.concurrent` task, and `Future.cancel` interrupts its blocked receive: `Io.Threaded` sends a signal to the thread (`pthread_kill` with `SIGIO`, in `Threaded.zig`). The Rust POC woke every 100 ms to check a flag.
- **The inbox is an `Io.Queue`.** `put(…, min = 0)` and `get(…, min = 0)` never block, which is exactly a bounded, dropping inbox.
- **Timing uses `Io.Clock.awake`**, which is `CLOCK_UPTIME_RAW` on macOS.

**What it cost to learn.** The release notes explain the concepts (Juicy Main, futures, cancellation, the clocks) but say only "All net APIs are migrated to Io" about networking. Everything about UDP came from the doc comments in `std/Io/net.zig`, `std/Io.zig` and `std/Io/Threaded.zig`, the same text as the generated standard-library documentation. There is no tutorial or example for 0.16 networking.

**A sign of its age.** `Ip4Address.fromAny` is declared to return `?Ip6Address`. Calling it fails to compile (`error: expected type '?Io.net.Ip6Address', found 'Io.net.Ip4Address'`), on 0.16.0 and still on master on 2026-10-01. Nothing in the standard library calls it, so lazy analysis never compiled it.

### C interop through raylib-zig

**What raylib-zig is.** Generated, hand-tweaked Zig bindings (`lib/raylib.zig`, 184 KB), plus raylib's own `build.zig`, which compiles raylib's C sources with Zig. No translation happens at build time.

**What it adds over raylib's own module.** raylib's `build.zig` already exposes a module made with `addTranslateC` (`translateCMod("raylib", …)`). A probe used it directly: it builds, and the program runs. It costs a 16 s, 789 MB translation step the first time (the release notes: translate-c is now "compiled lazily from source"), then 83 ms. Compared on the same functions:

| | raylib-zig | raylib's `addTranslateC` module |
| --- | --- | --- |
| Names and types | Zig names and Zig enums: `isKeyDown(key: KeyboardKey)` | C names and integer constants: `IsKeyDown(key: c_int)`, `KEY_UP: c_int = 265` |
| Loading from memory | slices and errors: `loadImageFromMemory(fileType: [:0]const u8, fileData: []const u8) error{LoadImage}!Image` | pointers and sizes: `LoadImageFromMemory(fileType: [*c]const u8, fileData: [*c]const u8, dataSize: c_int) Image` |
| Extras | methods on types; rlgl and raymath modules | none |

**Its weaknesses:**
- **Pointer types that lie.** `AudioStream.processor` is declared `*rAudioProcessor`, a pointer that may not be null. Yet raylib's `LoadSoundFromWave` starts from `Sound sound = { 0 }` and leaves it NULL (raudio.c). The translated module declares it `?*rAudioProcessor = null`, which is correct. The Engine never touches those fields: it keeps the value as bytes.
- **No release for raylib 6.0.** It had to be pinned to a `devel` commit.
- **Packages for web builds on every build.** Its `build.zig.zon` declares emsdk and zemscripten eagerly, and they serve only web builds.

**`@cImport`** "is now deprecated" in 0.16, in favour of the build system's `addTranslateC` (release notes). Neither the POC nor raylib-zig uses it.

**Assessment:** raylib-zig is worth having for its Zig-shaped API. raylib's own translated module is a credible fallback if the binding lags behind a Zig release, at the cost of a C-shaped API.

### The churn

**What 0.16 changed under me.** Every standard-library API I first reached for from memory had moved:
- `std.net` is gone (now `std.Io.net`), and `std.io` is gone (now `std.Io`);
- `std.time.Timer` and `Instant` became `std.Io.Timestamp` and `Clock`;
- `std.Thread.Mutex` and the other synchronisation primitives moved into `std.Io`;
- `std.process.argsAlloc` gave way to `std.process.Init`, and environment variables and arguments are now reachable only from `main`;
- `std.meta.intToEnum` gave way to `std.enums.fromInt`;
- `std.BoundedArray` is gone.

Tutorials written for earlier versions no longer compile.

**Deprecations are silent.** My first draft used three deprecated APIs, and all compiled without a word:
- `@intFromFloat`, replaced by `@trunc` with an integer result;
- `StaticBitSet.initEmpty()`, replaced by `.empty`;
- `std.mem.indexOfScalar`, replaced by `findScalar`.

I found them in the release notes and by searching the standard library for "Deprecated".

**What was still current.** raylib-zig's README instructions (`zig fetch --save git+…#devel`) and its API matched 0.16.

**Project-local packages.**
- 0.16 fetches packages "into a 'zig-pkg' directory relative to the build root" (release notes). The compiler hard-codes that location (`src/main.zig`).
- The only way around it is `--system <dir>`, which disables fetching altogether.
- So it cannot be moved. It is in `.gitignore`, and every build here ran on a scratch copy, so `zig-pkg/` never appeared in the workspace.

### Error unions and `try`, next to Rust's `?` and C++'s `std::expected`

**In the decoder.** `decode` reads `try in.read(Header)` and `try in.read(Body)`.
- The reader's `error{Truncated, BadValue}` coerces into the Game's `DecodeError` by itself, because error sets merge.
- Rust needed a `From` impl for `?`. C++ checked a failure flag and built `std::unexpected` by hand.
- Switches on error sets are exhaustive.

**The price: Zig errors carry no payload.** The Client must log context where the error happens, or map error names to messages in `main`, as it does for "the Match is full". Otherwise it prints names such as `AddressInUse`.

**Assessment:** for a decoder, Zig's errors are the lightest of the three. For user-facing messages, they are the most work.

### The built-in fuzzer

0.16.0 has one: `std.testing.fuzz` with the new `Smith` input generator, run by `zig build test --fuzz`.
- **In Debug, it does not compile on this Mac.** The test runner's fuzz path passes `@errorReturnTrace()`, a `*builtin.StackTrace`, to `std.debug.writeStackTrace`, which now takes a `*const debug.StackTrace` (`lib/compiler/test_runner.zig:566`). A plain `zig build test` runs the same test once without trouble.
- **In ReleaseSafe, it works.** 10.1 million inputs in about 30 s found no failure of the property "any accepted datagram re-encodes to the same bytes", and reached 79 of 9,533 coverage points.
- Whether that covers the decoder well could not be judged without its web interface.

## What hurt

- **The downloads.** A first build downloads 87 MB:
  - raylib's repository at tag 6.0, fetched shallow (`deepen 1` in `src/Package/Fetch/git.zig`), is 51.6 MB even after filtering, since raylib's package includes its examples' resources;
  - mach's xcode-frameworks, 16.3 MB (104 MB unpacked), which raylib's `build.zig` requests on any macOS target, yet which did not make the Client link without the Command Line Tools;
  - emsdk and two versions of zemscripten, used only by web builds but declared non-lazy.

  **Assessment:** on a slow connection, last night, a first build took up to 7 minutes. Every teammate, CI runner and empty cache pays it.
- **Whole-program rebuilds.** Any edit costs 5.4 s in ReleaseSafe and 1.5 s in Debug, ten times Rust's 0.44 s and five times its 0.30 s. Undoing an edit costs the same. Incremental compilation, experimental, gave no gain here. Apple Silicon cannot use Zig's fast Debug backend yet.
- **A young toolchain:**
  - `Ip4Address.fromAny` does not compile, even on master;
  - the built-in fuzzer does not compile in Debug;
  - a program built with `-fsanitize-thread`, even a hello world, crashes at startup on this Mac (exit status 139). The C++ POC saw LLVM 21's AddressSanitizer runtime hang on macOS 26, and Zig 0.16 is based on LLVM 21; whether the two are related was not verified;
  - deprecations give no warning.
- **Documentation:** `std.Io` networking is documented only in the standard library's comments, and pre-0.16 material no longer compiles.
- **macOS distribution.** Native builds require the build machine's macOS version (26.5.2 here). Building the Client for an older macOS failed to link, and was not solved within the time box.
- **No private fields.** That cost the Engine byte-array storage for raylib values and the 83-line API check, whose first version was wrong.
- **ZLS:** a file opened before ZLS has read `build.zig` stays unresolved until reopened.
- **Smaller frictions:**
  - `zig fetch --save` writes `zig-pkg/` next to `build.zig`, so it had to run on a scratch copy;
  - killing `zig build server` leaves the Server it started running;
  - the type names `@typeName` produces depend on file names.

## What was pleasant

- **Windows from the Mac:** one flag, first try, 16 s, nothing to install, no licence. The Server imports two system DLLs.
- **One tool.** Zig built raylib's C code with undefined-behaviour checks in safe builds, linked everything, and fetched git packages without `git`. No CMake, libclang or LLVM install was needed.
- **The compile-time codec:**
  - no per-message encoder or decoder;
  - dispatch generated from the message union;
  - a compile error for a message type the union lacks;
  - exact agreement with Rust on 100,000 fuzzed datagrams.
- **`try` with merging error sets** in the decoder.
- **`std.Io`:**
  - UDP, threads and DNS in the standard library;
  - a network thread stopped by cancelling its receive, with no polling;
  - a bounded queue that never blocks;
  - SplitMix64 in `std.Random`.
- **Allocation in plain sight.** Nothing allocates per Tick or per datagram, and it is visible in the signatures.
- **Small static binaries.** ReleaseSmall gives a 154 KB stripped Server, and every macOS program depends only on the system.
- **`build.zig` is code.** The layering check is 32 lines of ordinary Zig, run on every build, and `zig build test` and `zig fmt` need no configuration.

**Assessment for the team:**
- The language is small, and teammates who know C++ will find manual memory management familiar, with checks they can keep on in release builds.
- What has to be learned is 0.16's new I/O, for which there is little material.
- Zig itself still breaks between releases.

## Interoperability with the C++ and Rust POCs

The Zig implementation follows the layout documented in the C++ `protocol.cppm`. A unit test checks the exact bytes of every message, among them the brief's example: an Accept for Player 2 with sequence 0x01020304 is `52 54 01 02 04 03 02 01 02`.

| Run | Result |
| --- | --- |
| Zig Server, four C++ Clients, the demo script | all 4 join; the leaving and the killed Client are reported to the others; timeout 3.07 s after `kill -9`; 5 malformed; the C++ Client's screenshot shows the 4 Ships |
| Zig Server, four Rust Clients | the same; 3.07 s |
| C++ Server, four Zig Clients | the same; 3.06 s |
| Rust Server, four Zig Clients | the same; 3.05 s |
| One Match on the Zig Server: a C++ Client (the one killed), a Rust Client, two Zig Clients | all 4 join; 3.04 s; every remaining Client is told; the Zig Client's screenshot shows the 4 Ships |
| What each Client sends first, captured with `nc -u -l` for 1.2 s | Zig and Rust: 24 bytes, three connects (sequence 1 to 3), identical. C++: 16 bytes, two connects, identical to Zig's first 16. The capture window caught two or three connects |
| What each Server answers a hand-made connect, 0.5 s captured | Zig, Rust and C++: 549 bytes each, identical (`cmp`): an accept, then 30 snapshots; even the Tick numbers matched |

No mismatch was found.
- **Indirect fuzzing against Rust.** The Zig and Rust decoders were fuzzed against each other indirectly: same datagrams, same tallies. Per-datagram agreement was not checked.
- **Cosmetic differences:**
  - the stars sit elsewhere, since the generators differ;
  - errors print as Zig error names.

## The Windows result

**Cross-build from macOS: works.**
- `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows` built `r-type_server.exe`, `r-type_client.exe` and `protocol_fuzz.exe` (PE32+, x86-64, console) on the first try.
- It used the MinGW-w64 libraries Zig ships, with no workaround and no Microsoft component, so no licence to accept. About 5 minutes of the 30-minute budget were used.
- A clean cross-build takes 15.9–16.1 s. The first one on a machine takes 23.5–29.2 s, while Zig builds Windows runtime pieces into its global cache.
- The `.exe` files import only Windows DLLs (list under "Binary sizes"). The Client needs the Universal C Runtime, part of Windows since Windows 10.
- They were **not run**: no Windows machine was available.

**Native build on Windows: documented, not tested.** Unpack Zig, run `zig build -Doptimize=ReleaseSafe`. The default `gnu` target uses Zig's own MinGW-w64, so no Visual Studio is involved.

## Improvements that need non-stable features

These exist in 0.16.0 but are called unfinished or experimental by its release notes, or exist only on master:
- **Incremental compilation** (`-fincremental`, "remains disabled by default"): it would make rebuilds near-instant where it works. Measured here: no gain on macOS with LLVM. The release notes pair it with the new ELF linker, so Linux only for now.
- **The self-hosted aarch64 backend** ("still a work-in-progress"): it would give Apple Silicon the fast Debug builds x86-64 already has.
- **Evented I/O** (`Io.Evented` "work-in-progress, experimental", with Kqueue and Dispatch proofs of concept; "does not yet implement networking"): it would let the transport run without a thread of its own.
- **The integrated fuzzer** (the roadmap: "competitive with AFL"): coverage-guided fuzzing of the decoder, once it works in Debug.
- **Fixes on master:** the master branch was not examined for this POC, apart from `fromAny`, still broken there on 2026-10-01.

Private struct fields, which would remove the byte-array storage and most of the API check, are not coming: the proposal was closed as not planned.

## Not verified

- **Other platforms:** building on Linux, and building natively on Windows; running the `.exe` files.
- **Use:** hearing the sound; playing with the keyboard (all runs were scripted); playing over a real network (all runs used localhost).
- **The other POCs' figures:** the C++ and Rust figures in the tables come from their reports and were not re-measured.
- **Decoder agreement:** per-datagram agreement between decoders; the C++ decoder was not fuzzed against the Zig one.
- **Builds elsewhere:** Debug build times on an x86-64 machine, where Zig's own backend would compile Debug builds.
- **ThreadSanitizer:** why it crashes at startup on this Mac.
- **macOS packaging:**
  - whether `build.zig` could pass xcode-frameworks' paths to the Client's link, making the Command Line Tools unnecessary;
  - how to build the Client for an older macOS.
- **ZLS:** used through a scripted LSP client only, not in an editor.
- **The web target:** never tried, although emsdk and zemscripten are downloaded for it.
- **Long runs:** behaviour after very long runs (Tick and sequence counters wrapping after 2^32).
