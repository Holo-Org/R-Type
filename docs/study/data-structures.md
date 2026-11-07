# Algorithms and data structures

The data structures and algorithms the game relies on, which existing designs they follow, and which we made to measure.

## Entities: one table per kind

The Engine's ECS stores each kind of entity in a fixed-capacity table of its own: one array per component, live rows packed at the front ([ADR 0003](../adr/0003-a-minimal-ecs-of-our-own.md), [ADR 0006](../adr/0006-one-table-per-kind-of-entity.md)).

| | One table per kind (ours) | One array and one bit set per component | Sparse sets per component | Archetypes |
|---|---|---|---|---|
| A system's loop | the table's columns zipped in a plain `for` | bit sets combined, then indexed | one dense array, the others looked up | contiguous, per archetype |
| Adding or removing a component | not possible: an entity keeps its components | cheap | cheap | moves the entity |
| Memory | fixed at compile time, nothing allocated | fixed | grows | grows |
| What R-Type needs | entities that never change kind, a few hundred at most | | | |

Each table's capacity is its kind's budget, which also bounds a Snapshot: a compile-time check proves that a Snapshot of full tables fits in one datagram. A spawn into a full table is refused and counted, and rows leave a table only through a removal step after the systems, so nothing changes under a loop and nothing is deferred. Tables hand out one-byte ids from a wrapping counter that skips the ids in use: they exist for Snapshots, so that Clients tell entities apart.

## Time: a fixed step

The Server simulates 60 Ticks a second on the monotonic clock, whatever the CPU's speed, as the subject requires. `FixedStep` counts the steps due since the last call, and catches up on at most 5 after a pause rather than replaying a long backlog at once. The Client draws at its own frame rate and sends one Input per Tick, from the same clock.

## The reliable channel

Announcements ride on every datagram until acknowledged ([`engine/headless/reliable.zig`](https://github.com/Holo-Org/R-Type/blob/main/engine/headless/reliable.zig)):

- **Acknowledgements:** every header acknowledges the latest datagram received and, one bit each, the 32 before it, so a lost acknowledgement is repaired by the next. This is the design Glenn Fiedler describes in [Reliability, Ordering and Congestion Avoidance over UDP](https://gafferongames.com/post/reliability_ordering_and_congestion_avoidance_over_udp/).
- **Round trip:** measured from each acknowledgement and smoothed as TCP does ([RFC 6298](https://www.rfc-editor.org/rfc/rfc6298)): an eighth of the way to each new measurement.
- **Resends:** a message goes out again once the round trip plus 50 ms have passed without an acknowledgement of the datagram that last carried it.
- **Ordering:** the receiver keeps a window of 32 messages and hands them over in order, each once.
- **Back-pressure:** at most 32 messages wait for an acknowledgement; one more means the peer has stopped answering, and the Connection times out.
- **Measurement:** the same sequence numbers give, at each end, the datagrams lost, duplicated and late.

Nothing in the channel allocates, and it sends nothing itself: the program asks it, for every datagram, what header to write and which messages to add.

## Interpolation

The Client keeps its last 8 Scenes and draws at a render Tick of its own, which advances 60 times a second, aims at two Snapshot intervals behind the newest, slows by a tenth when ahead of that and jumps when far behind. Each entity's position is a linear interpolation between the two Scenes around the render Tick, matched by kind and id. A move of more than 64 pixels is drawn as a jump, since an id can go to another entity.

## Replayable Matches

Each Match's Waves come from a seeded generator, and the ECS keeps rows in spawn order, so the same seed and the same Inputs give the same Match. The Server logs each Match's seed; `--matches 1 --seed S` replays it, and the Match's tests rely on it.

## Codec

The encoding of each message is derived at compile time from its type ([libraries](libraries.md)). The decoder checks every count against its capacity before reading the entries, checks each entry before the next, and refuses anything left over, so a datagram is either one valid message or nothing.
