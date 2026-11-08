# Libraries

Everything the programs use beyond Zig's standard library is one C library, raylib, through raylib-zig. The rest is ours.

## Window, drawing, input and sound

| | raylib 6.0 | SDL 3.4 | SFML 3.1 |
|---|---|---|---|
| Covers | window, 2D drawing, textures, text, keyboard, gamepads, audio, in one library | window, input, audio, a 2D renderer; text and images in companion libraries | window, 2D drawing, text, input, audio, networking |
| From Zig | raylib-zig, tested with raylib 6.0 and Zig 0.16.0 | castholm/SDL, built by Zig without CMake | a C++ library: only through its C binding, CSFML, which we did not try |
| Builds | from source, with raylib's own `build.zig`: nothing to install on Windows or macOS, X11 and OpenGL headers on Linux | from source, with castholm/SDL's `build.zig` | CMake and a C++ toolchain |
| In every language we tried | yes: C++, Rust, Zig and Odin | yes | C++ only |

We chose **raylib**:

- one library covers everything the Client needs, so the client Engine wraps one API;
- it builds from source through Zig's package manager, which keeps the project self-contained, as the first defense's report noted;
- the evaluator accepts bindings to C libraries such as raylib;
- it ran in all four language POCs, so the comparison between languages was like for like.

It costs a pinned raylib-zig commit on its development branch, with no release for raylib 6.0, and bindings that follow the Zig compiler closely. raylib also carries copies of GLFW, miniaudio and stb, which no manifest lists ([security](security.md)).

raylib never shows outside the client Engine: `engine/client/api_check.zig` fails the build if any public declaration of the client Engine exposes a raylib type, so the Game, the Server and the bot cannot depend on it.

## Networking

The subject allows Asio or the operating system's sockets, wrapped in proper abstractions. Zig has no Asio; we use the standard library's `std.Io.net`, new in Zig 0.16, wrapped in the Engine's `UdpTransport`:

- a socket served by a network thread of its own, started with `io.concurrent`, which blocks on the socket and can be cancelled;
- a bounded inbox of 256 datagrams between that thread and the Tick loop, which drops and counts what does not fit;
- datagrams of more than 1,200 bytes dropped and counted ([ADR 0005](../adr/0005-datagrams-of-at-most-1200-bytes.md)).

A game-networking library (ENet, or renet in Rust) would have given us reliability, but the subject asks us to design the protocol, and the reliable channel we needed is small: about 400 lines with its tests ([data structures](data-structures.md)).

## Encoding

| | Derived at compile time (ours) | Written by hand per message | A serialisation library |
|---|---|---|---|
| Code per message | none: the struct is the layout | an encoder and a decoder | an annotation or a schema |
| Wire layout | field order, little-endian, no padding, stated in the spec | whatever is written | the library's |
| Checks | each type's `validate`, plus every count checked before use | by hand | the library's, often none for ranges |

`engine/headless/bytes.zig` derives the encoding of integers, enums, packed structs, arrays and structs from their declarations. A type with a variable length, such as a Snapshot, spells out its own. The [protocol spec](../protocol.md) is then a description of those declarations, and its test vectors are checked by the code's tests.

## Settings

Zig's standard library reads ZON, Zig's own data notation, which allows comments, so the settings file needs no library ([storage](storage.md)).

## What we did not use

- **An ECS library** (EnTT, flecs): the evaluator requires the ECS to be our own ([ADR 0003](../adr/0003-a-minimal-ecs-of-our-own.md)).
- **A game engine or framework**: forbidden by the subject.
- **A scripting language:** Track 1 and Track 3 topics, out of our scope.
