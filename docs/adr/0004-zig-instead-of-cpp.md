---
status: accepted
---

# Zig instead of C++

The subject was written for C++, but the evaluator opened it to other languages, naming Rust and Zig himself; what he asked was clear documentation and defensible decisions. We built the same slice of R-Type in C++, Rust, Zig and Odin, and chose Zig. The team wanted to explore languages other than C++. C++ and Rust both offer three or four ways to write the same code, in different syntaxes and paradigms, and some of their syntax is hard to read: for three people reviewing each other's code, that makes reviews painful unless everyone writes alike.

## Considered options

- **C++**, with xmake and its package manager: The team does not want to work in it, and it has the review problem above.
- **Rust**: the closest contender. We preferred Zig, and feared the team's lack of functional-programming experience would make Rust's idioms costly.
- **Odin**: nobody on the team knows it. Its POC needed a hand-written boundary check, and Odin cannot link Windows executables from another system, so nobody could easily build or test them. It was also the most expensive POC to build, at two and a half five-hour sessions of AI assistance.

## Consequences

- Zig is pre-1.0: each release breaks the standard library, and bindings such as raylib-zig follow the compiler closely.
- The Zig POC cross-built the Windows executables from a Mac with one flag, which keeps Windows support within reach.
