# Language

The subject is written for C++. On 28 September 2026 the evaluator opened it to other languages, naming Rust and Zig himself, and asked for clear documentation and defensible decisions in return. Rather than argue from reputation, we built the same slice of R-Type four times and compared what we measured. The decision is [ADR 0004](../adr/0004-zig-instead-of-cpp.md).

## What each POC built

A headless Server and a raylib Client on an Engine split into a headless and a client part, as [ADR 0001](../adr/0001-engine-game-boundary.md) requires: four scripted Clients in one Match, a Client killed and dropped after 3 s with the others told, garbage datagrams counted and ignored, and a fuzz test of the decoder. All four speak the same protocol byte for byte: Clients of one language played on Servers of the others.

## What we measured

| | C++ (xmake) | Rust | Zig | Odin |
|---|---|---|---|---|
| Rebuild after an edit, release | 0.47–1.60 s | 0.43–0.47 s | 5.4 s | 4.07–4.55 s (no build cache) |
| First build from nothing | about 30 s for raylib, built by xrepo | 12.2–13.5 s | 33 s, of which about 10 s of downloads | nothing to build but our code: raylib comes prebuilt |
| Package manager | xrepo, with a lock file | Cargo | Zig's, pinned by content hash | none: the compiler's `vendor:` collection |
| Windows programs from the Mac | MinGW-w64 cross-build | MinGW-w64, with three workarounds | one flag, first try, 16 s | none: the native build needs MSVC |
| ADR 0001 enforced by the toolchain | modules hide raylib and Asio | Cargo refuses undeclared crates; a 19-line `deny.toml` refuses the rest, but not a raylib type in the client Engine's API | `build.zig` refuses undeclared imports; 32 lines and an 83-line API check caught every case tried | almost nothing; a 247-line checker caught every case tried |
| Memory safety | discipline, sanitizers and fuzzing | no `unsafe` in our code | bounds and overflow checks in Debug and ReleaseSafe | bounds checks by default |
| Fuzzed datagrams, allocations, crashes | 100,000, 0, 0 | 5,100,000, 0, 0 | 5,100,000, 0, 0 | 15,000,000, 0, 0 |
| What hurt most | toolchain defects: `import std` with Apple's clang, a GCC crash, a sanitizer hang | gaps in the `raylib` crate's API, libclang everywhere for bindgen | downloads, whole-program rebuilds, a young standard library | no build cache, no Windows build from the Mac |

The fuzz tests of Rust, Zig and Odin drew the same datagrams from the same seed and classified them identically, which is strong evidence that the decoders agree.

## Why Zig

- **Reviews.** Three of us review each other's code. C++ and Rust each offer several ways to write the same thing, in different styles, and some of their syntax is hard to read; Zig has one obvious way more often, so reviews stay about the logic.
- **Windows.** The subject grades Windows support, and none of us develops on Windows. Zig builds the Windows programs from Linux or macOS with one flag, which is what makes the Windows CI job and the release's Windows programs cheap.
- **The layering we want, checked by the build.** Zig refuses an import that `build.zig` did not declare, and the rest of ADR 0001 fits in a few dozen lines of `build.zig` and a compile-time API check, both of which now run on every build.
- **The codec.** Zig's compile-time reflection derives each message's encoding from its declaration: no hand-written encoder or decoder per message.
- **The team.** Learning a language was one of our goals. The teammates know C++ and a little Rust; Rust's idioms would have cost them more without a functional-programming background.

## What it costs

- **Zig is not 1.0.** Each release breaks the standard library, and bindings such as raylib-zig follow the compiler closely: we pinned Zig 0.16.0 and a raylib-zig commit, and did not move to 0.17 during the project.
- **Rebuilds.** Every edit recompiles whole programs: 5.4 s in ReleaseSafe, 1.5 s in Debug, against Rust's half a second.
- **No Doxygen.** Zig's own documentation generator covers doc comments; the higher-level documentation is this site.
- **The subject's tooling has to be translated.** Zig's build system is both the build system and the package manager, which the evaluator accepted as meeting the subject's two requirements.

## Rejected

- **C++ with xmake and xrepo:** the best package-management story of the four, but the toolchain defects cost the most time, and the team did not want to work in it.
- **Rust:** the closest contender, with the fastest rebuilds and the strongest safety. We feared its idioms' learning cost for the team, and preferred Zig's simplicity.
- **Odin:** nobody knew it, it needed a hand-written boundary checker, it cannot build Windows programs from another system, and its `vendor:` collection only counts as a package manager if we manage its versions ourselves.
