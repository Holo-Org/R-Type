# Security

What can go wrong with each technology we use, what guards against it, what does not, and how we follow our dependencies over time. The protocol's own security considerations are in [§9 of the spec](../protocol.md#9-security-considerations).

## By technology

| Technology | Main risks | What guards against them | What stays open |
|---|---|---|---|
| Our code, in Zig | out-of-bounds access, integer overflow, use after free | the release programs are built ReleaseSafe, which keeps bounds and overflow checks; nothing is allocated per datagram or per Tick | use after free is not checked by Zig; we rely on fixed-capacity storage and review |
| The protocol | malformed or hostile datagrams | every count checked against its capacity before reading; every value range-checked; datagrams above 1,200 bytes dropped; at most 256 datagrams read per Tick | no authentication: a forged source address can act as a Player, or make the Server send Snapshots to a victim for up to 3 s |
| Zig's standard library and compiler | bugs in the networking added in 0.16, and in a pre-1.0 toolchain | the Server uses only its UDP sockets and threads; a fixed compiler version | no advisory database covers Zig; fixes arrive with new releases, which break the standard library |
| raylib, in the Client only | its decoders of images, fonts and sounds, and the copies of GLFW, miniaudio and stb it carries | the Client loads no file from the network: its sprites are compiled in, its sounds generated; the Server links no raylib at all | those copies are in no manifest, so no scanner sees them |
| GitHub Actions | a compromised or outdated action in the workflows | Dependabot watches the actions | |

## Malformed datagrams

- The decoder takes no allocator, reads nothing past the datagram, and refuses a datagram as soon as one value is wrong, in an order the spec fixes.
- The Language POCs fuzzed it: 5,100,000 datagrams in Zig, random and mutated, with 0 allocations and no panic; the same seed drew the same tallies in Rust, Zig and Odin.
- The Server counts malformed datagrams in its report, and keeps running.
- Under altered datagrams that still pass the checks, the worst case is a Snapshot that misplaces entities for one Frame, or an Input that holds other Actions for one Tick ([why no checksum](https://github.com/Holo-Org/R-Type/issues/70)).

## What we did not do

- **A challenge handshake with a connection token.** It would stop forged addresses from joining, and the Server from streaming to a victim. It was planned ([Add the challenge handshake and connection token](https://github.com/Holo-Org/R-Type/issues/29)) and cut for time.
- **Encryption.** Nothing private crosses the network: Actions and positions.
- **Rate limits per address.** The Server bounds how much it reads per Tick, but one address can still fill the inbox for everyone.

## Following our dependencies over time

Nothing on GitHub reads Zig's `build.zig.zon`, and no advisory database covers Zig packages ([research](https://github.com/Holo-Org/R-Type/blob/research/dependency-security/docs/research/dependency-security.md)). So:

- **GitHub Actions:** Dependabot opens a pull request when an action we use has a new version.
- **raylib and raylib-zig:** pinned to a commit and a content hash; whoever moves a pin reads raylib's release notes first. An OSV scan of the pinned commits would work, but needs a hand-kept list that follows every pin, and we did not set it up.
- **Zig:** pinned to 0.16.0 in `build.zig.zon` and CI. Its release notes are where fixes are announced.

**What this leaves uncovered:** a vulnerability in raylib's bundled GLFW, miniaudio or stb reaches us only through a raylib release, and a raylib fix may only arrive through a raylib-zig that requires Zig 0.17, which means a toolchain move first.
