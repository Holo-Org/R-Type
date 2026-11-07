# R-Type

A networked horizontal shoot'em up in the spirit of R-Type, for up to four Players per Match, built on a game engine of our own. The Server runs every Match and has the final say; each Player sees and plays it through a Client.

It is the R-Type project of Epitech's Advanced C++ unit (G-CPP-500), written in Zig rather than C++: [ADR 0004](docs/adr/0004-zig-instead-of-cpp.md) explains why.

**Documentation:** <https://holo-org.github.io/R-Type/>

## Platforms

| Platform | Server | Client |
|---|---|---|
| Linux (x86-64) | Supported | Supported, with X11 |
| Windows (x86-64) | Supported | Supported |
| macOS | Best effort | Best effort |

## Requirements

- [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0). Zig 0.17 is not supported yet.
- On Linux, the X11 and OpenGL development packages. On Debian or Ubuntu:

  ```sh
  sudo apt-get install libgl-dev libx11-dev libxcursor-dev libxi-dev libxinerama-dev libxrandr-dev
  ```

Nothing else is installed by hand: the build fetches [raylib-zig](https://github.com/raylib-zig/raylib-zig) at a pinned commit and builds raylib 6.0 from source.

## Build

```sh
zig build                              # both programs, in zig-out/bin
zig build -Doptimize=ReleaseSafe       # an optimised build
zig build -Dtarget=x86_64-windows      # the Windows programs, from any platform
zig build test                         # the unit tests
```

Prebuilt Linux and Windows programs are attached to each [release](https://github.com/Holo-Org/R-Type/releases).

## Play

Start a Server, which listens on UDP port 4242 and runs five Matches of up to four Players, 20 Players in all:

```sh
zig-out/bin/r-type_server
```

Then each Player starts a Client, giving the Server's address:

```sh
zig-out/bin/r-type_client --host 192.168.1.20
```

Each Client joins the first Match that has room. A Match begins 5 seconds after its last Player joins, and lasts until every Ship is destroyed. A Client that finds every Match being played waits for the next one. The round trip to the Server, and how much of its traffic is lost, show in the top-right corner.

| Action | Keyboard | Gamepad |
|---|---|---|
| Move | Arrow keys | D-pad or left stick |
| Fire | Space | A (cross) |
| Leave the Match | Esc, twice while the Ship is alive | |

The keys and buttons, auto-fire (fire as a toggle, rather than a key to hold) and the sound effects' volume can be changed in `settings.zon`, which the Client writes with its defaults and comments the first time it starts:

- Linux: `~/.config/r-type/settings.zon` (or under `$XDG_CONFIG_HOME`)
- Windows: `%APPDATA%\r-type\settings.zon`
- macOS: `~/Library/Application Support/r-type/settings.zon`

A `settings.zon` next to the Client's executable replaces that file entirely.

### Server options

| Option | Default | Meaning |
|---|---|---|
| `--port <port>` | 4242 | UDP port to listen on |
| `--matches <n>` | 5 | Matches run at once, each for up to four Players |
| `--seed <seed>` | random | Seed of the first Match's Waves; the log gives each Match's, and `--matches 1 --seed <seed>` replays it |
| `--snapshot-every <ticks>` | 1 | Send a Snapshot every this many Ticks (60 per second); 2 or 4 save bandwidth, and Clients stay smooth |
| `--join-window <seconds>` | 5 | How long a Match waits for more Players after each join |
| `--hit-points <n>` | 3 | Hit points of each Ship |
| `--invulnerability <seconds>` | 4 | Invulnerability after each hit |
| `--game-over-pause <seconds>` | 5 | Pause between game over and the next join window |
| `--stats <file.csv>` | | Write each Connection's round trip, loss and traffic there, every 5 seconds |

The Server logs the same figures every 5 seconds.

### Client options

| Option | Default | Meaning |
|---|---|---|
| `--host <host>` | 127.0.0.1 | Server's address or name |
| `--port <port>` | 4242 | Server's UDP port |
| `--demo <seed>` | | Play a Match run inside the Client, without a Server |
| `--script <n>` | | Play by itself, following pattern n, for tests and measurements |
| `--frames <n>` | | Quit after n Frames |
| `--screenshot <file.png>` | | With `--frames`, save the last Frame |

### Testing a Server with bots

`r-type_bot` runs scripted Clients without a window, each with its own socket, so one machine can stand in for a full session. It prints what each bot measured, and fails if a bot never joined or lost the Server:

```sh
zig-out/bin/r-type_bot --host 192.168.1.20 --clients 20 --seconds 60
```

## Contributing

Work happens on short branches, merged into `main` through pull requests, squashed, with the `/merge` command. Commit titles read `area: imperative summary`, such as `server: run the match over the reliable channel`. The checks in [.jj-ci.toml](.jj-ci.toml) run on every pull request, and locally before `jj push` for those who use [jj-ci](https://github.com/renman-ymd/jj-ci). The [developer documentation](https://holo-org.github.io/R-Type/) explains how the code is organised.

## Authors

Renaud Manet, Loïs Maumenée and Alex Guibert.
