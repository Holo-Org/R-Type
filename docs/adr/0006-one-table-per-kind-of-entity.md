---
status: accepted
---

# One table per kind of entity

The ECS of [ADR 0003](0003-a-minimal-ecs-of-our-own.md) stores each kind of entity in a table of its own: one array per component, live rows packed at the front, and a fixed capacity. This replaces ADR 0003's storage, one array and one bit set per component type with a generation per slot. In Part 1, every entity keeps the components it spawned with, and the Game already gives each kind a budget so that a Snapshot fits in one datagram ([ADR 0002](0002-snapshots-and-a-reliable-channel.md)). One table per kind turns each budget into a table's capacity, lets a system zip a table's columns in a plain `for`, and leaves the bit sets, generations and deferred spawns with nothing to do.

## Considered options

- **ADR 0003's storage**, with queries that combine bit sets and deferred spawns and destroys: it pays for entities whose components change, which Part 1 does not have, and for handles that outlive a Tick, which the Server never keeps.
- **Sparse sets per component**: dense iteration and cheap addition and removal of single components, at the cost of a sparse array and an entity list per component, and of queries that look up every other component through them. Part 1 never adds or removes components, and at a few hundred entities, speed and memory do not differ measurably.

## Consequences

- An entity cannot gain or lose a component, nor change kind. Moving entities between tables when their components change is left for Part 2.
- A spawn takes effect at once, or is refused and counted when its table is full. Rows leave a table only through a removal step over that table, never inside a loop over it, so nothing is ever deferred.
- Each table hands out one-byte ids, unique among its live rows, from a wrapping counter that skips the ids in use. They exist for Snapshots: Clients tell entities apart by kind and id.
- A query returns, for every table that has the components it asks for, those components' columns, to zip.
- Darts and Pods each have a table of 32 rows under one Enemy budget of 32, which the Wave spawner checks.
- A compile-time check over the tables' capacities, rather than the budgets, proves that a Snapshot of full tables fits in one datagram.
- The Match owns the Server's World, in the Game. Each Client keeps a World of its own for what only it draws, and draws the Match's entities straight from the newest Snapshot.
