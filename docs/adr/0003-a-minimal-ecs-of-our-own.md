---
status: accepted
---

# A minimal ECS of our own, in both programs

The Engine's headless part provides a small entity-component-system, used by both the Server and the Client. An entity is an index plus a generation, each component type has its own storage, queries cover a few component types, and systems are plain functions run in a fixed order, each Tick on the Server and each Frame on the Client. There is no scheduler, no parallel systems and no reflection. The team first settled on no ECS, to save time, but the Server builds every Snapshot by walking its entities ([ADR 0002](0002-snapshots-and-a-reliable-channel.md)), which is what an ECS is for, and the subject recommends one. The evaluator requires any ECS to be home-made, which rules out EnTT, flecs and similar libraries.

## Considered options

- **No ECS**: plain structs, as in the language POCs. The cheapest start, but every Game system would be rewritten on the day an ECS arrives.
- **A fuller ECS**, with archetypes, a scheduler, parallel systems and serialization by reflection: out of reach in Part 1's time.

## Consequences

- Each program fixes its world's capacity at compile time: one array and one bit set per component type, a generation per slot, and queries that combine bit sets. Nothing is allocated after startup, and a spawn into a full world is dropped and counted.
- Networked entities are also bounded by the Snapshot's entity cap ([ADR 0002](0002-snapshots-and-a-reliable-channel.md)).
- Growable sparse sets and archetype tables were set aside: R-Type never has more than a few hundred entities, and a fixed capacity also bounds the memory a Match can use.
