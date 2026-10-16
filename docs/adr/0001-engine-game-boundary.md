---
status: accepted
---

# Engine and Game are separate, and the Server is headless

The Engine is a set of libraries that know nothing about R-Type: a headless part (entities, time, events, networking) and a client part (rendering, audio, input). The Game builds on top of it, the build enforces that direction, and the Server links only the headless part, so it builds and runs without any graphics or audio library. We chose this over a plain client/server/common layout because Part 1 grades visibly decoupled rendering, networking and game logic, because a headless Server is simpler to build, test and deploy, and because it keeps Part 2's standalone-engine track open; to keep the cost low, the Engine starts thin, and code moves into it only once it has proven game-agnostic.

## Considered options

- **A plain `client/`, `server/`, `common/` layout**, with boundaries by convention only: the cheapest start, but nothing stops the Server from pulling in graphics code, or Engine code from depending on R-Type.
- **The Engine in its own repository from day one**: premature for three people with about nine working days per Part.
