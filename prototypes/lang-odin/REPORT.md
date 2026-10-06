# Language POC report: Odin

The fourth and last of the language POCs (C++, Rust, Zig, Odin) described in `docs/research/language-pocs.md`. Built and measured on 2026-10-05, in three sittings: 14:59–16:06, 16:16–17:16 and 22:21–22:41 CEST. The session limit stopped the work twice. On 2026-10-06, once dev-2026-10 was released, the POC moved to it and was rechecked; see "Rechecked on dev-2026-10". Every other figure comes from dev-2026-09.

The following were all redone between 22:23 and 22:35, on the final sources:
- the build times and compile-model timings;
- binary sizes and line counts;
- fuzz runs and boundary cases;
- lock-check, codec and bounds experiments;
- static checks and unit tests.

The demo, interoperability runs and wire captures date from 16:48–16:54. They also ran the final Odin sources: only `scripts/build.sh` changed after them, in two places that do not touch the programs.

Judgement is marked **Assessment**. Everything else was measured here or comes from the cited source. How to build and run it is in [README.md](README.md).

## Summary

- **The whole slice works, and speaks the other three POCs' protocol byte for byte.**
  - It is a headless Server and a raylib Client, on an Engine split into the packages `engine/headless` and `engine/client`. `scripts/build.sh` builds them, since Odin has no build system.
  - Four scripted Clients play together. A killed Client is dropped 3.03 s after the kill and the others are told. Garbage datagrams are counted and ignored, and a fifth Client is refused.
  - The Odin Server plays with C++, Rust and Zig Clients, and Odin Clients play on all three other Servers. One Match mixed all four. Captured datagrams are identical (`cmp`).
- **Moved to dev-2026-10 on 2026-10-06, with one line changed.**
  - Only the release pinned in `odin.lock` moved: `vendor/raylib` is the same in both releases, and the code builds unchanged.
  - The unit tests pass, and the fuzz tallies and the Server's bytes are identical.
  - Builds are about 4 % faster in release and 6 % in debug, and sizes move by 0.1 % at most.
- **The fuzz test draws the Rust and Zig POCs' datagrams draw for draw, and its tallies equal theirs exactly.**
  - With `100000 42`: 6,243 accepted, 46,610 bad protocol ids, and so on, identical in all four build modes.
  - Another 15,000,000 datagrams (seed 7) went through both the bounds-checked and the unchecked release builds. 0 allocations were counted, through Odin's context or from the C library, and nothing crashed.
- **There is no build cache, so every build compiles everything.**
  - A release build of the three programs plus the layering check takes 4.07–4.55 s. That holds whether nothing changed, a private detail changed or a public type changed. A debug build takes 1.50–1.69 s.
  - For an edit, the earlier reports give 0.43–0.47 s for Rust, 5.4 s for Zig and 0.47–1.60 s for C++.
  - Nothing is downloaded or built besides our code: raylib comes prebuilt with the compiler.
- **`vendor:` can be version-managed, but only as a whole, together with the compiler.**
  - `odin.lock` pins the release (tag and commit) and the SHA-256 of raylib's prebuilt libraries. `scripts/build.sh` checks both before every build, in 0.025 s. The Engine asserts raylib's version at compile time.
  - All four mismatches tried were caught.
  - raylib's version is the compiler's. raylib 6.0 reached an Odin release 74 days after its own.
  - Elsewhere in `vendor:`: on macOS and Linux, `vendor:ENet` links whatever ENet the system has. miniaudio 0.11.25 is still missing seven months after its release.
- **Odin enforces almost none of ADR 0001 by itself. A 247-line checker written in Odin enforces all of it.**
  - Odin refuses the Engine importing the Game only because that closes an import cycle. Every other violation tried builds.
  - `scripts/check_layering` is built on the standard library's own Odin parser. It caught all 16 violations tried, including a public Engine declaration that exposes a raylib type (case 8, which nothing caught in the Rust POC). It costs about 0.6 s per build.
  - Odin links a library only if reachable code calls it. A Server that imports the client Engine without calling raylib still links `libSystem` alone.
- **No Windows `.exe` from the Mac.**
  - dev-2026-09 writes an object file and exits with status 0 without linking. dev-2026-10's experimental cross-linking stops at once without a Windows SDK, and getting one means accepting Microsoft's licence.
  - The Server linked by hand with LLD and MinGW-w64. The Client cannot link that way: `vendor:raylib`'s Windows library needs MSVC's runtime.
  - The native build needs Visual Studio's MSVC and Windows SDK. Nothing was run on Windows.
- **What hurt:**
  - no build cache;
  - a boundary checker to write;
  - Windows;
  - no usable AddressSanitizer on this Mac, and ThreadSanitizer only with Apple's clang;
  - small semantic surprises: range bounds re-evaluated every iteration, empty UDP datagrams never sent, `%7d` padding with zeros;
  - packaging: nixpkgs strips raylib, and the release's version string differs from other builds'.
- **What was pleasant:**
  - one archive, and nothing else to download;
  - `#packed` structs of `u16le` and `u32le` fields as the wire format;
  - `bit_set`, exhaustive `switch`es, fixed-capacity dynamic arrays and `or_return`;
  - the implicit context for swapping allocators;
  - a parser in the standard library;
  - built-in tests;
  - small binaries.

## Versions used

| Tool | Version | Where from |
| --- | --- | --- |
| Machine | Apple M5, 10 cores, 32 GB; macOS 26.5.2 (25F84) | |
| Odin compiler | dev-2026-09 (tag `dev-2026-09`, commit `a2fb372b7`, released 2026-09-01), built by nixpkgs with LLVM 21.1.8 | nixpkgs `odin` |
| Odin collections (`base`, `core`, `vendor`) | the same tag, checked out from GitHub; the Git LFS objects of `vendor/raylib/macos/libraylib.a` and `windows/raylib.lib` fetched and their SHA-256 checked against the LFS pointers | `ODIN_ROOT` pointed at the checkout |
| Recheck on 2026-10-06 | dev-2026-10 (tag `dev-2026-10`, commit `84bc3fc21`, released 2026-10-06), built from the tag by nixpkgs' `odin` package with its source replaced (LLVM 21.1.8); `ODIN_ROOT` on a checkout of the same tag | `nix build` of an override of nixpkgs' `odin` |
| raylib | 6.0 (`vendor:raylib`, `VERSION :: "6.0"`), prebuilt static library with miniaudio 0.11.24 inside | the Odin tag |
| OLS | dev-2026-08 | nixpkgs `ols` |
| Apple clang | 21.0.0 (clang-2100.1.1.101), Command Line Tools 26.6 | `/usr/bin`, for `xcrun` and two link tests |
| Windows experiment | LLD and LLVM tools 21.1.8; MinGW-w64 14.0.0; `libgcc.a` of MinGW GCC 15.3.0 | nixpkgs `llvmPackages_21`, `pkgsCross.mingwW64` |
| git-lfs, tokei | 3.7.1, 15.0.0 | nixpkgs |
| Other POCs, rebuilt for interoperability | C++ with its own helper script (nixpkgs LLVM 22.1.8), Rust 1.98.1, Zig 0.16.0 | their workspaces' sources |
| Nix, nixpkgs | Lix 2.95.2; nixpkgs 26.11 (the system registry's pinned `nixpkgs`) | |

- **Why the compiler came from nixpkgs and the collections from upstream.**
  - nixpkgs builds dev-2026-09 from the same tag, but deletes `vendor/raylib`'s prebuilt libraries and patches `raylib.odin` and `raygui.odin` to link `system:raylib` (`package.nix`, `system-raylib.patch`).
  - It leaves `vendor/raylib/rlgl/rlgl.odin` pointing at the deleted libraries.
  - nixpkgs had no dev-2026-10 package yet on 2026-10-06. The recheck therefore built nixpkgs' `odin` with the new tag's source: its patches applied unchanged, and the build took 45 s.
- **How the official archives are built.** Odin's nightly job builds them, with LLVM 20 on macOS (Homebrew `llvm@20`) and Linux (Alpine `llvm20`), per `.github/workflows/nightly.yml`. They were not downloaded or run.
- **Isolation.**
  - Everything ran inside `nix shell nixpkgs#odin`, plus tokei, git-lfs or LLVM where needed.
  - `PATH` was cut down to that shell's store paths plus `/usr/bin:/bin:/usr/sbin:/sbin`.
  - `HOME` and the XDG directories pointed into scratch, and the sources were scratch copies.
  - Odin writes nothing outside its output directory.

## What was built

| Part | Package | Contents |
| --- | --- | --- |
| Engine, headless | `engine/headless` | `bytes`: little-endian writer and checked reader, with generic `write`/`read` of `#packed` wire values. `net`: UDP over `core:net`, with a network thread from `core:thread`, a bounded `core:sync/chan` inbox of 256 datagrams, a drop counter and name resolution. `time`: fixed step on the monotonic clock. `random`: SplitMix64 |
| Engine, client | `engine/client` | `Window`, `Frame`, `Texture`, `Audio_Device`, `Sound`, `Color`, `Rect`, `Key`, `Error`; raylib values copied into plain fields, with private conversions |
| Game | `game` | `protocol.odin` (the messages as a tagged union, `encode`, `decode`) and `match.odin` (the Match rules) |
| Server program | `server` → `r-type_server` | the 60 Hz Tick loop; logs joins, leaves, timeouts, and a counters line every 5 s |
| Client program | `client` → `r-type_client` | three-layer Star-field; Ships from `r-typesheet42.gif`, compiled in with `#load`; keyboard or `--script`; a synthesized "pew"; `--host`, `--port`, `--frames`, `--screenshot` |
| Fuzz test | `tests/fuzz` → `protocol_fuzz` | 10,000 round trips, then 100,000 random and mutated datagrams by default, generated as the Rust POC does; allocation counting through the context and in the C library; a crash handler that prints the datagram |
| Layering check | `scripts/check_layering` | the ADR 0001 rules Odin cannot express, run by `scripts/build.sh` before every build |

Behaviour follows the other three POCs:
- the same wire format;
- the same decoder checks, in the same order: a fixed-size body is read whole before its values are judged, and the snapshot is read one Ship at a time;
- the same Match rules, options and log lines.

There are 15 unit tests, 8 in `engine/headless` and 7 in `game`. They check:
- the byte reader and writer;
- the UDP transport and the fixed-step clock;
- the generator, against reference SplitMix64 values;
- the exact bytes of every message, and every rejection reason;
- by reflection, that every message body is a packed little-endian wire value;
- the Match rules.

## Verified on this Mac

| Check | Result |
| --- | --- |
| `bash scripts/build.sh` in its four modes (release, debug, size, unchecked) | builds, under `-vet -strict-style` |
| `odin check … -vet -strict-style -vet-cast -vet-using-param -vet-tabs -vet-semicolon` | clean on `server`, `client`, `tests/fuzz` and `scripts/check_layering`, and with `-no-entry-point` on `engine/headless` and `game` |
| `bash scripts/build.sh test` | 8/8 and 7/7, in 0.30 s and 0.3 ms. On a fresh copy it first failed, because `odin` does not create the output directory (`ld: can't open output file`); fixed |
| Server and four scripted Clients (the shared demo script) | 4 Players join; the Client with `--frames 420` leaves and the others are told |
| Screenshot | `screenshot.png`, looked at: four Ships in the sheet's four colours, the Star-field, "Player 4" and "4/4 Players" |
| `kill -9` on a Client | "Player 2 timed out" 3.03 s after the kill; the remaining Clients logged "Player 2 left the Match" |
| 5 garbage datagrams from `nc` | counted as 5 malformed and ignored. The transport dropped 0 datagrams in every run |
| A fifth Client | "r-type_client: the Match is full", exit status 1 |
| Tick rate | the Server alone logged Tick 300 and Tick 600 5.005 s and 5.000 s apart |
| Fuzz, `100000 42`, all four modes | 10,000 round trips, 0 mismatches; the Rust and Zig reports' tallies exactly; identical output in every mode |
| Fuzz, 5,000,000 datagrams, seed 7 | release 1.232, 1.236, 1.254 s; unchecked 1.175, 1.175, 1.176 s; identical tallies; 0 allocations |
| A decoder with a range check removed | the checked build stops at the first datagram that needs the check and prints it (exit 133). The unchecked build corrupts memory silently and crashes later (exit 139) |
| Toolchain lock | a wrong pin, a wrong hash, nixpkgs' own `vendor/` and a wrong raylib version each stop the build; seven version strings tested against the pin |
| Interoperability | both directions with C++, Rust and Zig, plus a mixed Match; captures identical (see below) |
| Windows | dev-2026-09: `.obj` files from Odin; the Server `.exe` linked by hand, not run; the Client cannot link. dev-2026-10: refuses without a Windows SDK |
| Sanitizers | see "Sanitizers" |
| OLS | go-to-definition across packages, with no configuration file |

As in the other POCs, the "pew" was generated and played on each fire without error, but nobody listened to it. Every run used `--script`.

## Setup from a clean machine

**What every platform needs: the release archive.** Sizes per dev-2026-10's assets, published 2026-10-06:
- 62.0 MB for `macos-arm64`; dev-2026-10 no longer builds for Intel Macs (#7495);
- 70.3 MB for `linux-amd64`, 68.3 MB for `linux-arm64`;
- 149.4 MB for `windows-amd64`.

The archive holds the compiler, `base`, `core` and `vendor`, with raylib's prebuilt libraries. A build downloads nothing and compiles only our code. Linking goes through the system's tools.

**macOS** (tested with nixpkgs' compiler; the archive was not tried):
1. Install the Xcode Command Line Tools.
   - Odin links with `clang` and asks `xcrun --sdk macosx --show-sdk-path` for the SDK (`src/linker.cpp`).
   - If `xcrun` fails, the fallback writes the SDK path into a new local variable that shadows the real one (line 865). Odin then passes an empty `--sysroot`. So the Command Line Tools are required.
2. Unpack the archive, put it on `PATH`, and run `bash scripts/build.sh`.

**nixpkgs instead.** `nix shell nixpkgs#odin` works only with `ODIN_ROOT` pointing at a checkout of the tag, with raylib's LFS objects fetched. `scripts/build.sh` refuses nixpkgs' own root; the message is under "Version management". Until nixpkgs carries dev-2026-10, its package has to be built from the new tag, as README.md shows.

**Minimum macOS version.**
- Odin passes `-mmacos-version-min` to the linker only when given `-minimum-os-version` (`src/linker.cpp`). Otherwise the linker's default applies:
  - a Server linked by Apple's clang declared `minos 26.0`, this Mac's version;
  - nixpkgs' clang gives `minos 14.0`.
- With `-minimum-os-version:11.0`, both gave 11.0.
- No program was run on an older macOS.

**Linux** (not tested): the archive, plus:
- clang, since the install docs list LLVM 17 to 22 (for example `apt install clang`);
- X11's development library, which `vendor:raylib` links (`system:X11`).

**Windows** (not tested): the archive, plus MSVC and the Windows SDK from Visual Studio's "Desktop development with C++" component (install docs). That means accepting Microsoft's licence. `scripts/build.sh` is bash, so the README gives the raw `odin` commands.

**Toolchain weight here:**
- nixpkgs' `odin` is 215 MB, and 1.57 GB with its closure (LLVM 21, clang, LLD).
- The tag's checkout is 356 MB on disk, of which `vendor/` is 100 MB.
- The two LFS objects fetched are 5,080,192 B and 5,297,172 B.

**Assessment:** on paper, the lightest setup of the four POCs: one archive, no package downloads, no C build, no CMake, no libclang. In practice:
- macOS still needs the Command Line Tools, as for Rust and Zig;
- Windows needs Visual Studio, unlike Zig;
- the nixpkgs package does not work for this project as packaged.

## Measurements

### Build times

**What was timed.** The wall-clock time of `bash scripts/build.sh`, in release (`-o:speed`, bounds checks on) and debug (`-debug`). In order, it:
- checks the toolchain lock;
- builds and runs the layering check;
- builds the Server, the Client and the fuzz test, one after the other.

Runs were made inside the nix shell, on a scratch copy of the final sources, on 2026-10-05 between 22:23 and 22:25 CEST. The load average was 2.4–3.7, with the user's applications open. The C++, Rust and Zig columns come from their reports and were not re-measured.

**Odin keeps no cache.** A cold build (fresh copy, empty output directory, toolchain installed) is therefore the same build as a clean build, an "our code only" build and a no-op. The table keeps those rows to show it.

| Build | Odin (runs) | Rust, from its report | Zig, from its report | C++, from its report |
| --- | --- | --- | --- | --- |
| Cold | 4.553, 4.104, 4.067 s | 13.53, 12.24, 12.86 s (crate downloads, raylib built) | 33.23, 33.06, 33.19 s (87 MB downloaded) | 24.6 s + 4.8 s, 30.4 s + 4.7 s |
| Clean, dependencies ready | the same build | 11.27, 11.58, 10.80, 10.96 s | 15.46, 16.29, 16.37 s | 1.6 s + 5.4, 5.1, 5.1 s |
| Our code only | the same build | 0.51, 0.51, 0.52 s | 5.37, 5.48, 5.54 s | |
| Implementation edit: spawn x in `game/match.odin`, 64 → 65 → 66 → 67 | 4.147, 4.190, 4.150 s | 0.47, 0.44, 0.44, 0.43 s | 5.41, 5.41, 5.39 s | 0.47, 0.47, 0.50 s |
| Public type edit: a field added to `Ship_State`, three times (this changes the wire format) | 4.113, 4.194, 4.128 s | 0.45, 0.46, 0.44, 0.45 s | 6.46, 5.41, 5.52, 5.47 s | 1.60, 1.59 s |
| No-op | 4.178, 4.104, 4.223 s | 0.05 s (×3) | 0.229, 0.230, 0.230 s | 0.21 s |
| Debug: cold; implementation edit; public edit; no-op | 1.638, 1.691, 1.672 s; 1.628, 1.643, 1.561 s; 1.591, 1.561, 1.634 s; 1.627, 1.503, 1.585 s | 9.05 s; 0.30, 0.29 s; 0.33, 0.32 s; 0.06 s | 7.26, 7.28, 7.40 s; 1.52, 1.50, 1.51 s; 1.51, 1.66, 1.68 s; 0.222, 0.223, 0.223 s | |
| Windows cross-build | not possible (see "The Windows result") | 19.22 s | 15.93, 16.02, 16.14 s | 1.5 s + 7.6 s |

The same series ran in the afternoon (16:45–16:48), before the fix to the version check in `scripts/build.sh`. It gave release builds of 4.08–4.46 s and debug builds of 1.50–1.89 s: the same picture.

**Where a release build's time goes.** `compile-model.sh`, three runs each:

| Step | Time |
| --- | --- |
| Lock check: `odin version`, `odin root`, and the SHA-256 of a 5 MB library | 0.025 s (0.107 s the first time) |
| Building the layering check | 0.292–0.305 s |
| Running it | 0.273 s the first time after a build, 0.010–0.012 s afterwards |
| Server, Client, fuzz test, `-o:speed` | 1.038–1.059, 1.444–1.480, 0.964–0.966 s |
| The same, debug | 0.264–0.268, 0.345–0.350, 0.249–0.259 s |
| `odin check` (parse and type-check only), Server and Client | 0.054–0.055, 0.064–0.067 s |

`build.sh` always runs a freshly built checker, so it pays the slow first run every time. I did not establish why a new binary's first run takes 0.27 s.

The compiler's own timings for the Client (`-show-timings`, `-o:speed`):

| Phase | Time |
| --- | --- |
| Parsing | 12.7 ms |
| Type checking | 39.6 ms |
| LLVM code generation | 1,247 ms (86.1 %) |
| Linking | 148 ms (10.2 %) |
| Total | 1,449 ms |

**Why every edit costs a full build:**
- **The program is the unit of compilation, and nothing is cached.**
  - Odin parses and checks the whole program, every imported package included.
  - It then hands LLVM one module per program for `-o:speed` and `-o:size`. Per `odin build -help`, separate modules are the default only for `-o:none` and `-o:minimal`.
  - It keeps nothing between runs.
- **That one module is generated on one thread.** The Client took 1.472–1.481 s with `-thread-count:1`, the same as without it.
- **What would help, within this release:**
  - `-use-separate-modules` cut the Client's `-o:speed` build to 0.501–0.544 s. It gives one LLVM module per package; its effect on the generated code was not measured.
  - Building the three programs in parallel took 1.599–1.607 s instead of about 3.5 s in sequence. `scripts/build.sh` does not do this.
- **A cache exists, but only behind an internal flag.**
  - `-internal-cached` is absent from `odin build -help`. It turns on separate modules and keeps `.odin-cache/` in the output directory.
  - The Client then took 0.511 s, then 0.068 and 0.070 s with nothing changed.
  - Not used, since it is internal.

**Assessment:** at this size a full build is cheap. Debug builds take 1.5–1.7 s, the same as one Zig Debug edit. But every edit costs what a cold build costs, so a project ten times this size pays ten times as much for a one-line change, unless Odin's caching becomes a supported feature.

### Binary sizes

Release builds are `-o:speed` with bounds checks on. "Stripped" means `strip` run on a copy. The other columns come from the reports: Zig ReleaseSafe, Rust release, and C++.

| Binary | Odin, as built | Odin, stripped | Zig, as built | Zig, stripped | Rust, as built | Rust, stripped | C++, as built | C++, stripped |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `r-type_server` | 243,488 B | 234,728 B | 475,840 B | 402,328 B | 536,144 B | 414,312 B | 204,672 B | 204,712 B |
| `r-type_client` | 1,733,616 B | 1,479,192 B | 1,274,256 B | 1,058,600 B | 1,294,496 B | 1,074,600 B | 807,616 B | 745,208 B |
| `protocol_fuzz` | 225,232 B | 216,744 B | 477,280 B | | | | 122,608 B | |

Other Odin modes, in bytes:

| Binary | `-o:size` | stripped | `-o:speed -no-bounds-check` | stripped | `-debug` | stripped |
| --- | --- | --- | --- | --- | --- | --- |
| `r-type_server` | 228,112 | 218,248 | 226,336 | 218,184 | 589,296 | 482,456 |
| `r-type_client` | 1,718,592 | 1,462,744 | 1,732,976 | 1,479,176 | 2,197,168 | 1,816,104 |
| `protocol_fuzz` | 226,224 | 216,776 | 224,544 | 216,712 | 535,424 | 445,128 |

Bounds checks make the Server 7.6 % bigger (243,488 B against 226,336 B) and the Client 0.04 % bigger, since raylib makes up most of the Client.

What is linked dynamically:
- **Server and fuzz test:** `/usr/lib/libSystem.B.dylib` only. In the Server, `nm` finds 0 symbols matching `InitWindow`, `glfw`, `rlgl` or raylib's `Draw…`. The Client has 616, or 552 with the Zig report's pattern (`InitWindow|glfw`).
- **Client:** Cocoa, OpenGL, IOKit, AppKit, CoreFoundation, CoreGraphics, CoreServices, Foundation, `libobjc` and `libSystem`. raylib is linked statically from `vendor/raylib/macos/libraylib.a`.
- **Minimum macOS:**
  - `minos 14.0` and `sdk 14.4` for the measured builds, which nixpkgs' clang linked;
  - `minos 26.0` and `sdk 26.5` for a Server linked by Apple's clang;
  - 11.0 with `-minimum-os-version:11.0`.

### Lines of code

These are tokei 15.0.0 code lines only. Odin keeps unit tests in separate `_test.odin` files of the same package, so they are counted apart. tokei does not read `odin.lock`, so its 5 non-comment lines were counted by hand. The other columns come from the reports.

| Part | C++ | Rust (without unit tests) | Zig (without unit tests) | Odin, code | Odin, unit tests |
| --- | --- | --- | --- | --- | --- |
| Engine, headless | 207 | 313 (252, of which 30 are the random generator) | 351 (270, of which 87 are the compile-time codec) | 258: `bytes` 79, `net` 130, `time` 28, `random` 21 | 130 |
| Engine, client | 182 | 198 (198) | 226 (226, of which 83 are the API check) | 197 | |
| Game | 363 | 570 (408) | 369 (266) | 311: `protocol` 219, `match` 92 | 171 |
| Server program | 139 | 135 | 114 | 135 | |
| Client program | 314 | 349 | 305 | 364: `main` 255, Star-field 52, sprites 38, sound 19 | |
| Fuzz test | 128 | 164 | 222 | 375, of which 131 are the C-library watch | |
| Build description | 76 (`xmake.lua`) | 123 | 130 | 68: `scripts/build.sh` 63, `odin.lock` 5 | |
| Boundary check outside the build description | | | 83 (`api_check.zig` and its call site) | 247 (`scripts/check_layering`) | |
| Helper scripts | 14 | 18 | 0 | 0 | |

### Fuzz tallies, next to C++, Rust and Zig

All four ran with `100000 42`.
- **Odin reproduces the Rust test's datagrams.** It uses the same SplitMix64 (high 32 bits, bounded by remainder) and the same draws in the same order.
  - Where Rust evaluates an assignment's value before its index, the Odin code draws the value into a local first, so the order does not depend on Odin's rules.
  - Loop counts drawn from the generator are drawn once, before the loop, because Odin re-evaluates a range's upper bound on every iteration.
- **C++ draws different datagrams** (`std::mt19937`), so only its proportions compare.
- **The C++, Rust and Zig columns come from their reports.**

| | C++ | Rust | Zig | Odin |
| --- | --- | --- | --- | --- |
| Round trips, mismatches | 10,000, 0 | 10,000, 0 | 10,000, 0 | 10,000, 0 |
| Accepted | 6,403 | 6,243 | 6,243 | 6,243 |
| Too long | 10,024 | 9,979 | 9,979 | 9,979 |
| Truncated | 16,744 | 16,719 | 16,719 | 16,719 |
| Bad protocol id | 46,536 | 46,610 | 46,610 | 46,610 |
| Bad version | 3,150 | 3,050 | 3,050 | 3,050 |
| Unknown message type | 2,365 | 2,346 | 2,346 | 2,346 |
| Value out of range | 3,747 | 3,690 | 3,690 | 3,690 |
| Trailing bytes | 11,031 | 11,363 | 11,363 | 11,363 |
| Allocations in `decode()` | 0 | 0 | 0 | 0 through the context, 0 from the C library |
| Panics | not applicable | 0 | none: a panic would have ended the run | none: a failed check traps and would have ended the run |

With seed 7 and 5,000,000 datagrams, every run printed the same tallies:

| Outcome | Count |
| --- | --- |
| Accepted | 316,353 |
| Too long | 499,806 |
| Truncated | 838,715 |
| Bad protocol id | 2,327,698 |
| Bad version | 152,760 |
| Unknown message type | 118,434 |
| Value out of range | 187,959 |
| Trailing bytes | 558,275 |

## How the Engine/Game boundary and the headless Server are enforced

**By Odin, with nothing to configure:**
- **Import cycles are refused.** `game` imports `engine/headless`, so the Engine importing the Game closes a cycle, and the build fails with `Error: Cyclic importation of 'headless'` and `'game' refers to`. This holds even when nothing uses the import.
- **`@(private)` and `#+private` hide declarations from other packages.** A Client call to the Engine's private `to_raylib_color` fails with `'to_raylib_color' is not exported by 'engine'`.
- **A program links only what its reachable code calls.** Odin links a foreign library only if a procedure from it is used. A Server that imports the client Engine for a colour constant (case 3), or a Game with an uncalled procedure that calls raylib (7b), still links `libSystem` alone, with 0 raylib symbols.
- **`-vet` reports unused imports** (`'rl' declared but not used`). That catches case 7a by accident.
- **`vendor` cannot be redefined:** `-collection:vendor=…` gives `Library collection 'vendor' already exists with path '…'`.

**Not by Odin:**
- **Any package may import any directory**, by relative path, or any collection. No manifest lists a package's dependencies.
- **There are no private struct fields.** So the Engine copies raylib's `Texture2D` and `Sound` into its own structs. `#assert`s on raylib's field counts make a raylib upgrade that adds a field stop the build.
- **Nothing stops a public declaration from naming raylib** (case 8).

**By `scripts/check_layering`, 247 lines of Odin.** `scripts/build.sh` builds and runs it before the programs.
- **How it reads the project.** It walks the project's directories and parses every `.odin` file with `core:odin/parser`, the standard library's Odin parser.
- **Which part may import which:**
  - `engine/headless` imports nothing of ours;
  - `engine/client` and `game` import `engine/headless` only;
  - the Server and the fuzz test import `engine/headless` and `game`;
  - the Client imports those and `engine/client`;
  - a directory not in the table is refused.
- **Libraries:**
  - raylib (`vendor:raylib`, `vendor:raylib/rlgl`) is allowed only in `engine/client`;
  - no other vendor package is allowed;
  - no foreign import is allowed anywhere.
- **`engine/client`'s public declarations,** signatures and aliases included, may not mention raylib's import names or a private declaration of the package, since a private declaration could alias raylib.
- **Each message** names the file, line and column, the rule and the ADR. The run ends with `check_layering: N violation(s) of ADR 0001` and status 1.

**The violations tried**, as in the earlier reports where they apply, each on a scratch copy of the final sources (re-run at 22:28):

| # | Violation | Odin | The checker's message | What the Server links |
| --- | --- | --- | --- | --- |
| 1 | `engine/headless/net.odin` imports and uses the Game | `Error: Cyclic importation of 'headless'` | `engine/headless/net.odin(20:1) ADR 0001: engine/headless may not import "../../game": the Engine knows nothing about the Game` | |
| 2a | `engine/headless` imports the Game, unused | the same; `-vet` adds `'game' declared but not used` | the same, at `bytes.odin(19:1)` | |
| 2b | `engine/client` imports and uses the Game | builds | `engine/client/client.odin(14:1) ADR 0001: engine/client may not import "../../game": the Engine knows nothing about the Game` | |
| 3 | The Server imports `engine/client` for `engine.WHITE` | builds | `server/main.odin(16:1) ADR 0001: server may not import "../engine/client": only the Client program draws, the Server and the Game stay headless` | `libSystem` only, 0 raylib symbols |
| 4 | The Server opens a Window through `engine/client` | builds | the same | 10 libraries, 616 symbols, 1,172,616 B |
| 5 | The Server calls `rl.InitWindow` | builds | `server/main.odin(16:1) ADR 0001: server may not import "vendor:raylib": raylib stays behind the Engine's client part` | 10 libraries, 616 symbols |
| 6 | The Client program calls `rl.SetWindowTitle`, around the Engine | builds | `client/main.odin(14:1) ADR 0001: client may not import "vendor:raylib": …` | |
| 7a | The Client program imports raylib, unused | builds; `-vet`: `'rl' declared but not used` | the same | |
| 7b | The Game imports raylib, in a procedure nothing calls | builds | `game/match.odin(6:1) ADR 0001: game may not import "vendor:raylib": …` | `libSystem` only, 0 symbols |
| 7c | The same procedure, called from `step` | builds | the same | 10 libraries, 616 symbols |
| 8a | `engine/client` re-exports `rl.DrawText` as `draw_text_raw` | builds | `engine/client/client.odin(115:18) ADR 0001: engine/client's public draw_text_raw exposes raylib's rl.DrawText: …` | |
| 8b | A public procedure returns `rl.Texture2D` | builds | `…(166:42) …public texture_raw exposes raylib's rl.Texture2D: …` | |
| 8c | A private alias of `rl.Texture2D` in a public signature | builds | `…(169:42) …public raw_texture exposes the private Raw_Texture: …` | |
| 8d | A `#+private` file aliases `rl.DrawText`, and a public alias re-exports it | builds | `…(115:18) …public draw_text_any exposes the private draw_text_raw: …` | |
| 9 | The Server links `vendor:raylib/macos/libraylib.a` itself, through its own `foreign import` | builds | `server/main.odin(21:1) ADR 0001: server may not import a foreign library: libraries come from the vendor collection` | 10 libraries, 616 symbols |
| 10 | A new package `shared/` uses raylib, and the Server imports it | builds | `shared/shared.odin(3:9) ADR 0001: shared is not one of the parts of this project's layout`, then `server/main.odin(18:1) ADR 0001: server may not import "../shared" (shared): it is not one of the parts it may use` | 10 libraries, 616 symbols |

**What it cost:**
- **Code:** 247 lines of Odin, against Zig's 32 + 83 and the 19 lines of xmake rules or `deny.toml`.
- **Time:** about 0.6 s per build, 0.29–0.31 s to build it plus 0.27 s for its first run.
- **Its limits:**
  - It reads syntax, not types. It knows raylib by its import names within `engine/client`, and it catches aliases made through private declarations.
  - A public declaration whose type reached raylib through another package's type would pass. None exists today, since only `engine/client` may import raylib.

**Assessment:** with Zig's, the most complete enforcement of the four POCs, since both catch case 8. It is also the most code, and the code is ours to maintain. It is ordinary Odin that teammates can read. Odin links only what reachable code calls, so a stray import costs nothing at run time. That is why only the checker keeps the Server's sources headless.

## Odin specifics

### Version management of `vendor:`

**What `vendor:` is.**
- It is a collection of bindings that ships with the compiler, in the same archive and under the same Git tag.
- Its README says the Odin team curates and maintains it, and asks contributors to consult the team before proposing a package or a binding update. That text came with PR #6972, merged 2026-07-07.
- The FAQ: "Odin will never officially support a package manager."
- `vendor:raylib` is whatever the installed compiler carries. A project cannot point `vendor` elsewhere (the collection error above).

**How raylib ships.**
- `vendor/raylib/` holds hand-written bindings: `raylib.odin`, 1,872 lines, with `VERSION :: "6.0"`.
- It also holds prebuilt libraries per platform, as 16 Git LFS objects. Among them are `macos/libraylib.a` (5.1 MB), `windows/raylib.lib` (5.3 MB) and the two Linux `libraylib.a` (2.9 MB each).

**The scheme this POC uses:**
1. **`odin.lock`** names the release (tag and full commit) and records the SHA-256 of the four static raylib libraries, as Git LFS records them.
2. **`scripts/build.sh`**, before compiling anything, refuses:
   - a compiler whose `odin version` names another release or another commit;
   - a raylib library whose SHA-256 differs.

   The check is 30 lines of bash and takes 0.025 s.
3. **`engine/client`** asserts at compile time that `rl.VERSION` and `rlgl.VERSION` are "6.0", and that raylib's `Texture2D`, `Sound` and `AudioStream` still have the field counts the Engine copies.
4. **The checker** refuses other vendor packages and foreign libraries, so nothing escapes the lock.
5. **README.md, "Upgrading Odin and vendor:raylib"**, gives the procedure:
   1. read the new release's `vendor/raylib` history;
   2. move the pin and let the checks fail;
   3. record the new hashes and version;
   4. test, then commit, with CI on every platform.

**What it caught**, each on a scratch copy, with the final `scripts/build.sh`:

| Mismatch | Message |
| --- | --- |
| `odin.lock` pins another release | `odin.lock pins Odin dev-2026-08 (8412dc37a), but this odin is dev-2026-09` |
| A recorded hash differs by one digit | `…/vendor/raylib/macos/libraylib.a is not the library odin.lock records (SHA-256 0f1b656b…)` |
| nixpkgs' own `vendor/` (no `ODIN_ROOT`) | `/nix/store/…-odin-dev-2026-09/share//vendor/raylib/macos/libraylib.a is missing: this Odin's vendor collection is not the one odin.lock records` |
| The Engine expects raylib 6.1 | `engine/client/client.odin(17:1) Error: Compile time assertion: rl.VERSION == "6.1" && rlgl.VERSION == "6.1" ("vendor:raylib is not the raylib 6.1 recorded in odin.lock")` |

**A mistake found late.**
- The check first compared the third word of `odin version` with the pin. That works for nixpkgs' compiler, which prints `dev-2026-09`.
- The release archives are different. Odin's nightly job builds them with `-DNIGHTLY` and the commit (`nightly.yml`, `build_odin.sh`, `build.bat`). Users of dev-2026-09 report `dev-2026-09-nightly:a2fb372` (#7646, #7757). A build from a Git checkout prints `dev-2026-09:a2fb372b7`.
- So the first check would have refused the official archive.
- The fixed check accepts all three forms, provided the commit matches the pin. A stand-in `odin` tested it against seven version strings: three accepted, four refused. The refused ones named another commit in the same month, a Git build of another commit, another release, and another month with no commit.
- I did not run the archive itself.

**Upstream's track record.** Sources: the Odin repository's history and the upstream projects' releases.

| Library | Upstream release | In Odin | Delay |
| --- | --- | --- | --- |
| raylib 4.5 | 2023-03-18 | dev-2023-04 (2023-04-03) | 16 days |
| raylib 5.0 | 2023-11-18 | dev-2024-01 (2024-01-03) | 46 days |
| raylib 5.5 | 2024-11-18 | dev-2024-12 (2024-12-06) | 18 days |
| raylib 6.0 | 2026-04-23 | dev-2026-07 (2026-07-06), through PR #6940; bindings fixed in dev-2026-07a (2026-07-10) | 74 days |
| miniaudio 0.11.22 | 2025-02-24 | committed 2025-05-16 | 81 days to the commit |
| miniaudio 0.11.23 | 2025-09-10 | skipped | |
| miniaudio 0.11.24 | 2026-01-16 | committed 2026-02-25 | 40 days to the commit |
| miniaudio 0.11.25 | 2026-03-03 | not in dev-2026-09 | 7 months and counting |
| ENet 1.3.17 | 2020-11-15 | committed 2021-10-23 | |
| ENet 1.3.18 | 2024-04-15 | not in dev-2026-09 | about 2.5 years |
| GLFW | 3.5.1 (2026-07-31) | `vendor:glfw` is 3.4.0 | |
| SDL3 | 3.4.18 (2026-10-02) | `vendor:sdl3` is 3.4.2 | |

- **One raylib at a time.** During the 6.0 work, 6.0 sat in a folder of its own beside 5.5. Then 5.5 was removed (`0d883bb3e`, "Remove raylib v5.5 in favor of v6.0", 2026-07-06). Upgrading Odin upgrades raylib.
- **Not everything in `vendor:` is pinned.**
  - On macOS and Linux, `vendor:ENet` links `system:enet`, whatever ENet the machine has. Only Windows gets prebuilt libraries.
  - `vendor:miniaudio` ships its C sources and a Windows library. On macOS and Linux the user compiles it with a script, and the binding refuses to build until then.
- **Libraries outside `vendor:`.**
  - Odin has no package format. A project copies a library's sources or binaries, and its bindings, into its own tree.
  - It imports them by relative path or through a collection of its own: `-collection:third_party=…` was accepted.
  - That is plain vendoring, versioned by the project's own history. This POC's checker refuses foreign imports, so using it would mean changing a rule.

**Assessment:** the evaluator's condition can be met. A lock file, a check before every build and a compile-time assertion make the versions explicit, and they caught all four mismatches tried. But they manage one version only: the compiler's.
- The team cannot take a raylib fix without a compiler upgrade.
- It cannot hold raylib back while upgrading Odin.
- It depends on the Odin team's pace: 16 to 74 days for raylib, and over two years for ENet.

The escape hatch is to copy `vendor/raylib` into the project under another collection name. That works, and is then ordinary vendoring, with nobody else maintaining it.

### The implicit context and allocators, next to Zig's explicit allocators

- **What it is.**
  - Every procedure with Odin's calling convention receives a pointer to the current `context` (Odin overview).
  - The context carries `allocator`, `temp_allocator`, `random_generator` and `logger`, among others.
  - `new`, `make` and `append` use `context.allocator` unless they are given one.
- **Where allocation happens here.**
  - When the transport opens, through `open(port, allocator := context.allocator)`: the transport, its inbox channel (256 datagrams of 1,200 bytes, about 310 KB) and the network thread.
  - In the Client, at start (name resolution, raylib) and on failure paths (`fmt.tprintf` into the temporary allocator).
  - Nothing allocates per Tick or per datagram. Datagrams, encoded packets and snapshots use fixed arrays.
  - A snapshot's Ships live in a fixed-capacity dynamic array, `[dynamic; 4]Ship_State`, whose `append` never allocates (PR #6406, March 2026).
- **Not a guarantee.**
  - An Odin signature says nothing about allocation: any procedure can allocate through the context it receives implicitly.
  - `runtime.heap_allocator`, `core:c/libc`'s `malloc` and `core:mem/virtual` bypass the context altogether. On macOS and Linux they end in the C library's `malloc` family or in `mmap`.
  - Zig relies on a convention, allocators passed as parameters, but its global allocators can bypass it too. So both POCs had to measure.
- **The fuzz test therefore counts both kinds:**
  - **Through the context.** Around each `decode`, it sets `context.allocator` and `context.temp_allocator` to a counting allocator. That takes two lines and no change to `decode`'s signature.
  - **In the C library.** It defines `counting_malloc`, `counting_calloc`, `counting_realloc`, `counting_posix_memalign`, `counting_aligned_alloc` and `counting_mmap`. Each counts calls on its own thread and forwards them with `dlsym(RTLD_NEXT, …)`.
    - `scripts/build.sh` makes the linker alias them to the C names: `-Wl,-alias` with ld64, `--defsym` on Linux.
    - Odin refuses a second procedure linked as `malloc` (`Non unique linking name for procedure 'malloc'`), since `core:c/libc` declares it.
  - **Volatile counters.** At `-o:speed`, LLVM folded a plain counter's reads across the calls to the built-in `malloc`, and the self-check read 0 although allocations had happened.
  - **A self-check.** Before fuzzing, the test makes one allocation of each kind and stops if a counter misses it. So a blind counter cannot read 0.
  - **Result:** 0 and 0 in every run: 100,000 datagrams in each of four modes, and 15,000,000 more in release and unchecked builds.
  - **Not proven:** inputs the fuzzing never produced, or memory handed out again by an allocator that already holds it.
- **Not tried:** `-default-to-panic-allocator`, which makes the default allocator panic.

**Assessment:** the context makes the allocation strategy easy to change from outside, for a test or a per-Tick arena, without threading a parameter through every call. It also hides that strategy: a C++ teammate cannot tell from a signature whether a procedure allocates. For R-Type's Tick loop, the discipline has to come from review and from tests like this one.

### The codec: `#packed`, `u16le`, `bit_set` and tagged unions

**How it is written:**
- **Message bodies** are `#packed` structs of one-byte fields and explicitly little-endian ones (`u16le`, `u32le`). The struct's layout is the wire layout on every platform.
  - The Engine's `write` and `read` copy such a value whole, with `intrinsics.unaligned_load` when reading.
  - A `where` clause refuses, at compile time, any struct with implicit padding.
- **The buttons byte** is `Buttons :: bit_set[Button; u8]`. One set difference rejects bits that name no button.
- **Dispatch.** `Message :: union #no_nil {…}`. `encode` switches over the union and `decode` over the `Message_Type` enum, and both `switch`es must be exhaustive.
- **Value checks** form a procedure group, `valid :: proc{valid_accept, valid_reject, valid_input, valid_player_left}`, picked by type inside a generic `read_valid`.
- **The snapshot**, whose length varies, spells out its own encoding: 18 lines in `read_snapshot`.

**How much code.** `protocol.odin` has 219 lines:

| Section | Lines |
| --- | --- |
| Types and constants | 76 |
| `describe` | 13 |
| Header and buffers | 17 |
| `encode` | 26 |
| `decode` | 30 |
| Readers | 11 |
| Value checks | 26 |
| Snapshot | 18 |

The codec proper is 128 of those lines, plus `engine/headless/bytes.odin`'s 79. By the Zig report's counts, Zig's Game codec is 66 lines plus 87 in its Engine, Rust's 122 lines plus a 5-line `From` impl, and C++'s `protocol.cpp` 152.

**How readable its errors are**, from deliberate mistakes on scratch copies:
- **A padded struct written directly** (`Snapshot_Head` without `#packed`) fails to compile. The error reads `'where' clause evaluated to false: !intrinsics.type_struct_has_implicit_padding(T)`, followed by `T :: Snapshot_Head;` and `game/protocol.odin(195:2) at caller location`. Clear.
- **A padded struct nested in a packed one** (`Input_State` without `#packed`, inside the `#packed Input`) compiles: the intrinsic looks one level deep only. Three unit tests fail:
  - the reflection test, with `Input_State is not a wire value` and `Input is not a wire value`;
  - the exact-bytes test, which prints both byte lists;
  - a rejection test.
- **An `f32` field added to `Ship_State`** also compiles. The tests fail with `Ship_State is not a wire value` and the snapshot's bytes.
- **A message type added to the enum but not handled** gives `game/protocol.odin(219:2) Unhandled switch case: Pause`, with `Suggestion: Was '#partial switch' wanted?`.
- **A variant added to the union** gives the same error at every exhaustive `switch` over messages: in the Game, and in the Server (`server/main.odin(84:2)`).

**Assessment:** as in Zig, the wire format reads straight off the declarations, and exhaustiveness comes for free. The price is the same too: field order is the protocol, and the compile-time check sees only one level, so deeper layers are left to the tests.

### Bounds checks without overflow checks

- **Bounds** are checked by default (Odin overview): at compile time for constant indices, and at run time otherwise. Checks can be turned off per block (`#no_bounds_check`) or per program (`-no-bounds-check`).
- **Overflow is never checked.** Unsigned arithmetic is modulo 2^n, and signed overflow is defined and does not panic (Odin overview). Tick and sequence counters wrap by definition. By comparison, Zig checks overflow in safe builds and Rust in debug builds.
- **The demonstration.** I removed the snapshot's Player-range check and replaced its `bit_set` with a `[4]bool` array.
  - The checked fuzz build stopped at the first datagram that needed the check: `game/protocol.odin(293:11) Index 34 is out of range 0..<4`. The crash handler printed the 41-byte datagram, and the process ended on its trap (exit 133).
  - With `-no-bounds-check`, the out-of-range writes went unnoticed until the program crashed later, on another datagram (exit 139).
- **A macOS trap in the crash handler.** macOS 26 ignores `SA_RESETHAND` for `SIGTRAP`, from C as from Odin (a C probe confirmed it), so the handler ran forever. The clue was a 15.5 GB log. The handler now restores the default action itself.
- **Cost of the checks:** 4.8–6.7 % on the 5-million-datagram run (1.232–1.254 s against 1.175–1.176 s), and 7.6 % of the Server's size.
- **The decoder's own checks are code.** The byte reader reports failure and `decode` returns `Truncated`, whatever the build mode.

### `or_return`, next to Zig's `try` and Rust's `?`

- **How it is used.** `decode` reads `header := read(&input, Header) or_return`. If the last value returned is a non-nil error or `false`, the procedure returns at once with it (Odin overview).
  - `or_break` drains the Server's inbox.
  - `or_return` also turns parse failures into usage errors in both programs.
- **The types must already agree.** The Engine's reader returns `(T, bool)`, and `decode` returns `(Packet, Decode_Error)`. `or_return` passes the value through without converting it. So the Game wraps the reader in a 5-line `read` that turns `false` into `.Truncated`.
  - In Zig, error sets merge by themselves.
  - In Rust, `?` needed a `From` impl.
- **Errors carry values.** `Decode_Error` is an enum, and `core:net`'s errors are unions of enums, which `%v` prints by name.

**Assessment:** between the two: lighter than C++'s `std::expected` plumbing, slightly heavier than Zig's `try`.

### The compilation model

The figures are under "Build times": whole-program compilation, no cache, one LLVM module per program in optimised builds, LLVM taking 86 % of the time.

Released in dev-2026-10:
- PR #7701 multithreads the semantic checker. Type checking is 40 ms of 1.45 s here, so it matters little at this size.
- PRs #7720, #7729 and #7747 speed up the LLVM backend and the compiler. They target the 86 %.

Together they saved about 4 % per release build and 6 % per debug build here (see "Rechecked on dev-2026-10"). There is still no cache, so every edit still costs a full build.

### `core:net` for UDP, and stopping the network thread

- **What it offers:**
  - `make_unbound_udp_socket`, `bind`, `recv_udp`, `send_udp` and `bound_endpoint`, for IPv4 and IPv6;
  - name resolution, done by Odin itself on POSIX systems, from `/etc/hosts` and `/etc/resolv.conf` (`core/net/dns.odin`).
- **No cancellation.** `recv_udp` blocks, and nothing in `core:net` interrupts it. So the transport's `close` sets a flag and sends a datagram to its own socket every millisecond until the thread has finished.
- **The empty datagram.** The wake-up was first an empty datagram, and `close` hung.
  - `send_udp` loops on `for bytes_written < len(buf)`, so with an empty buffer it never calls `sendto`, on Darwin, the BSDs and Windows (`socket_posix.odin`, `socket_freebsd.odin`, `socket_windows.odin`). It reports success all the same.
  - Only Linux calls `sendto` once.
  - A one-byte datagram works.
- **The inbox** is a `core:sync/chan` buffered channel of 256 `Datagram`s. The network thread writes with `try_send`, and drops and counts a datagram when the inbox is full. The main thread reads with `try_recv`. No datagram was dropped in any run.
- **The clock.** `core:time`'s `tick_now` is `CLOCK_MONOTONIC_RAW` on Darwin and Linux, and `QueryPerformanceCounter` on Windows.
- **The 30 Hz Server.**
  - `for _ in 0 ..< headless.wait(&ticks)` evaluates the range's upper bound before every iteration. The code generator re-initialises it inside the loop (`src/llvm_backend_stmt.cpp`, line 936).
  - So each pass consumed another due Tick, the Server ran at 30 Hz, and the timeout took 6.07 s instead of 3.
  - In a probe, `for _ in 0 ..< three()` ran 3 times and called `three()` 4 times, whereas iterating over a `bit_set` evaluated it once.
  - The fix is a local: `due := headless.wait(&ticks)`.
- **Not tried:** `core:nbio`, added on 2026-01-11 and present in dev-2026-09. It brings non-blocking I/O with per-thread event loops and timeouts, and could replace the thread and the wake-up. The brief chose `core:net` and `core:thread`.

**Assessment:** enough for R-Type: UDP, threads, channels and a monotonic clock, all in the standard library. Stopping the thread takes a workaround, as in Rust; Zig's cancellable receive was cleaner.

### `vendor:raylib` as a binding

- **Close to C.** The bindings are hand-written. Functions keep their C names and C types, for example `InitWindow :: proc(width, height: c.int, title: cstring)`. Where raylib uses constants, the binding has Odin enums and bit sets: `KeyboardKey`, and `ConfigFlags :: distinct bit_set[ConfigFlag; c.int]`.
- **Strings are `cstring`s.** Odin strings are not zero-terminated, so `draw_text` copies its text into a 256-byte buffer on every call, and `save_screenshot` its path into a 1,024-byte one.
- **Buffers are a pointer and a length:** `LoadImageFromMemory(fileType: cstring, fileData: rawptr, dataSize: c.int)`.
- **Types are plain structs.** `Texture2D`, `Sound` and `AudioStream` have public fields, which is why the Engine keeps copies and field-count asserts.
- **Static and prebuilt.** Nothing compiles. The Client links the 5.1 MB `libraylib.a`, with raylib's miniaudio inside it.
- **`rlgl` is a separate package**, `vendor:raylib/rlgl`. The screenshot needs its `DrawRenderBatchActive` to flush raylib's draw batch first.
- **A known open issue, avoided:** #7750, where `VSYNC_HINT` does not cap the frame rate. As the brief advised, the Client paces itself with `SetTargetFPS(60)`.

**Assessment:** complete and current (raylib 6.0), with no build step. It feels less like Odin than raylib-zig feels like Zig, but a teammate who knows raylib's C API reads it at once.

### Sanitizers (15-minute box)

Odin offers `odin build -sanitize:address|memory|thread`. On this Mac:

| Linker | AddressSanitizer | ThreadSanitizer |
| --- | --- | --- |
| nixpkgs' clang 21.1.8, used for every measured build | builds, but a hello world, the fuzz test and the Server hang before printing anything; a watchdog killed them (status 142) | builds, but the same programs crash at start (status 139) |
| Apple clang 21.0.0, as the release archive links | fails to link: `"___asan_version_mismatch_check_v8", referenced from: _asan.module_ctor` | links Apple's runtime. A hello world ran, and the Server, with two Clients and a garbage datagram, reported 0 ThreadSanitizer warnings |

The earlier POCs saw the same: in the C++ POC, LLVM 21's AddressSanitizer runtime hung on macOS 26, and in the Zig POC, ThreadSanitizer builds crashed. Odin's nixpkgs build uses LLVM 21 too. The official archive's LLVM 20 instrumentation with Apple's runtime was not tried.

### `odin test`

- **Where tests live.** Tests are `@(test)` procedures in files tagged `#+test`, inside the package they test. Only `odin test <package>` compiles them. There are 15 here, with no framework to install.
- **The runner:**
  - runs tests on several threads;
  - gives each run a random seed and prints it;
  - tracks memory per test and reports leaks;
  - prints how to re-run only the failed tests (`-define:ODIN_TEST_NAMES=…`).
- **One snag.** `testing.fail_now` ends the test, so a `defer` after it is an error (`Unreachable defer statement`). `testing.expect(t, false, …)` did the job instead.
- **No built-in fuzzer.** The fuzz test is a program.

### The churn

- **Monthly releases, named after the month**, with two re-releases in the last year: dev-2025-12a and dev-2026-07a.
- **Recent breaking changes** (release notes):
  - dev-2026-03 replaced `core:os` with the rewrite previously at `core:os/os2`, keeping the old package at `core:os/old` until Q3 2026. `core:os/old` is gone in dev-2026-09.
  - dev-2026-07 renamed `core:mem`'s `DEFAULT_PAGE_SIZE` to `PAGE_SIZE` and dropped LLVM 14.
  - dev-2026-09 removed an `os.Error == 0` compatibility hack, and the `inline` and `no_inline` keywords from `core:odin`.
- **Fixes released in dev-2026-10.** None of those the brief listed was hit on dev-2026-09: #7607, #7570, #7641, f04f867b2, #7652, #7668, #7656, #7685 and #7682. All nine shipped in dev-2026-10.
  - #7682 fixes the `nocapture` attribute on LLVM 21 and later, which nixpkgs' build uses. The release uses LLVM 20.
  - #7685 rewrites parametric polymorphism, which the codec relies on.
- **What I reached for from memory, and was wrong:**
  - `runtime.random_generator_read_u64` does not exist; `random_generator_read_ptr` does;
  - `[4]u8(address)` does not parse; `([4]u8)(address)` does.
- **Documentation against behaviour.** `core:fmt` documents the `0` flag as padding with zeros instead of spaces, yet `%7d` prints `0009979`.
  - The reason: `fmt_write_padding` pads integers with zeros unless the space or minus flag is set (`core/fmt/fmt.odin`, line 1034).
  - The fuzz test prints its tallies with `% 7d`.
- **Tooling lag.** OLS has no dev-2026-09 release. Its newest is dev-2026-08, which nixpkgs carries.

## What hurt

- **No build cache.** Any edit costs a full build of every program: 4.1–4.6 s in release and 1.5–1.7 s in debug, against Rust's 0.44 s and 0.30 s. That is acceptable at this size, but it grows with the program.
- **The boundary is ours to enforce:** 247 lines of checker, about 0.6 s per build.
- **Windows:**
  - no cross-link without a Windows SDK, and so without accepting Microsoft's licence (dev-2026-10's cross-linking is experimental);
  - with dev-2026-09, an exit status that reports success (dev-2026-10 fails properly);
  - a raylib library that needs MSVC;
  - Visual Studio's licence for the native build.
- **Sanitizers on macOS:** neither works with nixpkgs' toolchain, and only ThreadSanitizer works with Apple's clang.
- **Packaging:**
  - nixpkgs strips `vendor/raylib`;
  - the release's version string differs from nixpkgs' and from a Git build's;
  - the Command Line Tools are required, and a failing `xcrun` leaves an empty `--sysroot`;
  - binaries require the linking Mac's macOS version unless told otherwise.
- **Small semantic surprises**, each of which cost a debugging session:
  - range bounds re-evaluated on every iteration (a 30 Hz Server);
  - `send_udp` silently sending nothing for an empty buffer (a Client that never exited);
  - `%7d` padding with zeros;
  - `testing.fail_now` combined with `defer`.
- **`vendor:` couples raylib to the compiler** (see "Version management").
- **Counting allocations in the C library** needed linker aliases and volatile counters.

## What was pleasant

- **Nothing to download or build but our code.** One archive, raylib prebuilt, no CMake, no libclang, no package fetch. A cold build is just a 4.1–4.6 s build.
- **The wire format as declarations:**
  - `#packed` structs of `u16le` and `u32le` fields, copied whole, with a compile-time padding check;
  - a `bit_set` for the buttons;
  - an enumerated array, `[Decode_Error]int`, for the tallies.
- **Exhaustive `switch`es** over the message union and the type enum, with clear errors.
- **Fixed-capacity dynamic arrays:** a snapshot's Ships with `append`, and no allocation.
- **`or_return` and `or_break`** in the decoder and the loops.
- **The implicit context:** two lines swap the allocators around `decode`.
- **A parser in the standard library:** the layering checker is ordinary Odin, with nothing extra to install.
- **Built-in tests,** with leak tracking.
- **Linking follows use.** The Server links `libSystem` alone, and binaries are small: a 243 KB Server, 218 KB in size mode.
- **Fast debug builds:** 1.5–1.7 s for the three programs and the checker.
- **Compile-time conveniences:** `#load`, `#assert`, and `#+build` files per platform.

**Assessment for the team:**
- Odin is a small language that reads like C with better types. Teammates who know C++ will find manual memory management and `defer` familiar.
- What has to be learned: the context and allocators, and a few semantics that differ from C++, such as range bounds.
- The risks:
  - the Windows build needs Visual Studio;
  - the boundary checker is ours to maintain;
  - monthly releases bring breaking changes;
  - `vendor:` versions move only with the compiler.

## Interoperability with the C++, Rust and Zig POCs

The Odin implementation follows the layout documented in the C++ `protocol.cppm`. A unit test checks the exact bytes of every message, among them the brief's example: an Accept for Player 2 with sequence 0x01020304 is `52 54 01 02 04 03 02 01 02`.

The other programs were rebuilt from their workspaces' sources:
- C++ with its helper script and nixpkgs' LLVM 22.1.8;
- Rust with 1.98.1;
- Zig with 0.16.0.

Zig had to be rebuilt too: the Zig binaries handed to me in scratch had been built from a measurement copy with the spawn x set to 67, and the capture showed `0x43`.

| Run | Result |
| --- | --- |
| Odin Server, four C++ Clients, the demo script | all 4 join; the leaving and the killed Client are reported to the others; timeout 3.08 s after `kill -9`; 5 malformed; screenshot saved |
| Odin Server, four Rust Clients | the same; 3.07 s |
| Odin Server, four Zig Clients | the same; 3.07 s |
| C++ Server, four Odin Clients | the same; 3.07 s |
| Rust Server, four Odin Clients | the same; 3.08 s |
| Zig Server, four Odin Clients | the same; 3.03 s |
| One Match on the Odin Server: a C++ Client (the one killed), a Rust, a Zig and an Odin Client | all 4 join; 3.08 s; every remaining Client is told; the Odin Client's screenshot, looked at, shows the 4 Ships |
| What each Client sends first, captured with `nc -u -l` for 1.2 s | Odin, C++, Rust and Zig: 16 bytes each, two connects (sequence 1 and 2), identical (`cmp`) |
| What each Server answers a hand-made connect, captured for 0.5 s | Odin, C++, Rust and Zig: 549 bytes each, identical (`cmp`): an accept, then 30 snapshots with the Ship at x 64, y 90. Even the Tick numbers matched |

No mismatch was found. The Odin, Rust and Zig decoders were fuzzed against each other indirectly: the same datagrams gave the same tallies. Per-datagram agreement was not checked.

## The Windows result

**Cross-build from macOS: it does not link.**
- With dev-2026-09, `odin build server -target:windows_amd64` compiled `r-type_server.obj` (467,978 B). It then printed `Linking for cross compilation for this platform is not yet supported (windows amd64)` and exited with status 0.
- That exit status is issue #4821, open since 2025-02-10. Scripts and CI would take the failure for a success.
- dev-2026-10 adds experimental cross-linking for Windows (#7654), with a new `-windows-sdk-root` option (#7788). Without it, the same command stops at once with `-windows-sdk-root:<path> must be used to target Windows` and exit status 1. No Windows SDK was obtained, since that means accepting Microsoft's licence, so the new path is untested.
- **The Server, linked by hand:**
  - `ld.lld` (LLD 21.1.8), MinGW-w64 14.0.0's start files and libraries, `libgcc.a` for `___chkstk_ms`, and a one-line C file defining `_fltused`, which Odin's object references;
  - the result is `r-type_server.exe`, 420,352 B, x86-64 console;
  - it imports `bcrypt.dll`, `KERNEL32.dll`, `msvcrt.dll`, `ntdll.dll` and `WS2_32.dll`;
  - it was not run.
- **The Client cannot be linked that way.** MSVC built `vendor/raylib/windows/raylib.lib`:
  - it asks for `MSVCRT`, `OLDNAMES` and `uuid.lib`;
  - it needs MSVC's security cookie, its `/GS` handler, `__chkstk` and the Universal CRT's `__stdio_common_*` functions, which MinGW lacks. The first of 21 errors is `ld.lld: error: undefined symbol: __security_cookie`.
- The Client's own code also needs `dnsapi` (`DnsQuery_UTF8`) for name resolution.
- Neither xwin nor any Microsoft download was used, to avoid accepting a licence.

**Native build on Windows: documented, not tested.**
- It needs the archive, plus MSVC and the Windows SDK. The install docs mention the developer command prompt only for building Odin itself from source.
- README.md gives the commands, in Nushell.

**What dev-2026-10 changes.**
- PR #7739 makes `radlink` the default linker on Windows. `radlink` ships in the repository as `bin/radlink.exe`, a Windows program.
- Cross-linking from macOS now exists, but it is experimental and needs a Windows SDK (above).

**Assessment:** the weakest Windows story of the four POCs. Zig cross-builds with one flag, and Rust and C++ with MinGW. Odin needs a Windows machine with Visual Studio for the Client.

## Rechecked on dev-2026-10

dev-2026-10 was published on 2026-10-06, from commit `84bc3fc21`. The POC moved to it the same day, following "Upgrading Odin and vendor:raylib" in README.md, on a scratch copy first.

- **The upgrade took one line.** `vendor/raylib` is identical in both tags (`git diff dev-2026-09 dev-2026-10 -- vendor/raylib` is empty), so the four raylib hashes in `odin.lock` stood. Only the `odin` line moved.
- **The code builds unchanged** under `-vet -strict-style`, although the release rewrote parametric polymorphism and fixed a `-strict-style` rule. The 15 unit tests pass.
- **Same behaviour.** With `100000 42`, the fuzz tallies are identical, with 0 allocations through the context and from the C library. The Server answers a hand-made connect with the same 549 bytes (`cmp`).
- **Unchanged surprises:**
  - `for _ in 0 ..< f()` still calls `f` before every iteration;
  - `%7d` still pads with zeros, since the `fmt` change (#7724) is not in the release;
  - `odin build -help` still documents no cache;
  - the `xcrun` fallback still declares a second `darwin_sdk_path` (`src/linker.cpp`, now near line 1029).

Both compilers built the same sources on 2026-10-06, alternately, with a load average of 3.2–4.4. Each time is a whole `bash scripts/build.sh`:

| | dev-2026-09 | dev-2026-10 |
| --- | --- | --- |
| Release build | 4.097, 4.270, 4.292 s | 4.024, 4.031, 4.119 s |
| Debug build | 1.498, 1.545, 1.655 s | 1.399, 1.510, 1.511 s |
| `r-type_server`, as built / stripped | 243,488 / 234,736 B | 243,648 / 234,728 B |
| `r-type_client`, as built / stripped | 1,733,616 / 1,479,200 B | 1,733,776 / 1,479,208 B |
| `protocol_fuzz`, as built / stripped | 225,232 / 216,752 B | 225,360 / 216,728 B |

The dev-2026-09 sizes differ from those under "Binary sizes" by a few bytes, since these builds ran from another directory.

**Assessment:** at this size, the release's compile-time work saves about 0.16 s per release build (4 %) and 0.09 s per debug build (6 %), comparing means. LLVM's code generation still dominates, and there is still no cache. For `vendor:`, this first upgrade cost one line, because raylib did not move.

## Improvements that need non-stable features

These exist in dev-2026-10 only behind an internal flag or as an experimental feature:
- **A build cache.** `-internal-cached` (internal, and still absent from `odin build -help`) cut an unchanged Client rebuild from 0.51 s to 0.07 s on dev-2026-09.
- **Windows cross-linking** (#7654, experimental): `.exe` files from the Mac, given a Windows SDK and, for the Client, MSVC's runtime libraries.

dev-2026-10 released what this section listed for dev-2026-09: the multithreaded checker (#7701), the compile-time work (#7720, #7729, #7747), `radlink` as the default Windows linker (#7739), and the nine fixes under "The churn".

dev-2026-09's experimental features, inline `asm` templates and `#+feature` opt-ins, were neither needed nor used.

## Not verified

- **Other platforms:** building on Linux, building natively on Windows, and running the Windows `.exe`.
- **The official release archives.** Neither release's archive was downloaded. Their version strings come only from issue reports and the build scripts. Their LLVM 20 code generation, sizes and times are unmeasured. Every figure here comes from nixpkgs' LLVM 21.1.8 builds of the tags.
- **Use:** hearing the sound; playing with the keyboard (every run was scripted); a real network (every run used localhost).
- **The other POCs' figures:** taken from their reports, not re-measured.
- **Decoder agreement:** per-datagram agreement with the other decoders; the C++ decoder was not fuzzed against Odin's.
- **dev-2026-10 beyond the recheck:**
  - the demo, the interoperability runs, the boundary cases and the sanitizers were not redone;
  - the Client was built but not run;
  - cross-linking for Windows with a Windows SDK was not tried.
- **macOS:**
  - running a program on an older macOS;
  - why a freshly linked program's first run takes 0.27 s;
  - AddressSanitizer with the release's LLVM 20.
- **OLS:** used through a scripted LSP client only, not in an editor.
- **Options not tried or not measured:** `core:nbio`; `-default-to-panic-allocator`; the effect of `-use-separate-modules` on generated code.
- **Long runs:** Tick and sequence counters wrapping after 2^32.
