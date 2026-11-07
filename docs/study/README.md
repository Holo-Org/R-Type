# Comparative study

Why we use what we use. Each page takes one question, sets out the options we weighed, with figures where we measured them, and says what we chose and what it costs. The decisions themselves are recorded in the [ADRs](../adr/README.md); these pages hold the comparison behind them.

| Page | Question |
|---|---|
| [Language](language.md) | Why Zig, not C++, Rust or Odin? |
| [Libraries](libraries.md) | Which libraries for the window, drawing, input, sound, networking and encoding? |
| [Networking](networking.md) | How do the Server and the Clients stay in step over UDP, and how do 20 Players fit on one Server? |
| [Algorithms and data structures](data-structures.md) | How are entities stored, time kept, and messages made reliable? |
| [Storage](storage.md) | What is kept on disk, and in which format? |
| [Security](security.md) | What can go wrong with each technology, what guards against it, and how we follow it over time? |

## Where the figures come from

- **The four language POCs**: the same slice of R-Type, a headless Server and a raylib Client speaking one protocol byte for byte, built in C++, Rust, Zig and Odin between 29 September and 6 October 2026, each with a report of what was measured: [C++](https://github.com/Holo-Org/R-Type/blob/poc/lang-cpp/prototypes/lang-cpp/REPORT.md), [Rust](https://github.com/Holo-Org/R-Type/blob/poc/lang-rust/prototypes/lang-rust/REPORT.md), [Zig](https://github.com/Holo-Org/R-Type/blob/poc/lang-zig/prototypes/lang-zig/REPORT.md), [Odin](https://github.com/Holo-Org/R-Type/blob/poc/lang-odin/prototypes/lang-odin/REPORT.md).
- **The research notes**: [the languages and their ecosystems](https://github.com/Holo-Org/R-Type/blob/docs/language-poc-research/docs/research/languages.md), [following our dependencies' security](https://github.com/Holo-Org/R-Type/blob/research/dependency-security/docs/research/dependency-security.md), [simulating bad networks](https://github.com/Holo-Org/R-Type/blob/research/network-conditions/docs/research/network-conditions.md).
- **The netcode simulator**: six ways of keeping Clients in step, played side by side on the same simulated network ([`poc/netcode`](https://github.com/Holo-Org/R-Type/tree/poc/netcode/prototypes/netcode)).
- **The measurements** of the finished game under the kick-off's test conditions: [Network measurements](../measurements.md).
