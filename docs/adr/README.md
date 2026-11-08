# Architecture decision records

Each record explains one decision that would be costly to reverse, and that a newcomer would otherwise wonder about: what we chose, what we weighed it against, and what follows from it. A record is never rewritten to say something else; a later decision amends or replaces it, and says so.

| Record | Status |
|---|---|
| [0001: Engine and Game are separate, and the Server is headless](0001-engine-game-boundary.md) | Accepted |
| [0002: Snapshots, plus a small reliable channel](0002-snapshots-and-a-reliable-channel.md) | Accepted |
| [0003: A minimal ECS of our own, in both programs](0003-a-minimal-ecs-of-our-own.md) | Accepted, its storage replaced by 0006 |
| [0004: Zig instead of C++](0004-zig-instead-of-cpp.md) | Accepted |
| [0005: Datagrams of at most 1,200 bytes](0005-datagrams-of-at-most-1200-bytes.md) | Accepted |
| [0006: One table per kind of entity](0006-one-table-per-kind-of-entity.md) | Accepted |
