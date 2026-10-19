---
status: accepted
---

# Snapshots, plus a small reliable channel

Every Tick, each Client sends its Player's Input, repeating its last few Inputs in every packet. Every K Ticks, the Server sends each Client a Snapshot with no delivery guarantee, and the Client keeps only the newest one, so a lost Snapshot is simply replaced by the next. Spawns and deaths need no message of their own: entities appear in, or vanish from, the Snapshot. A small reliable channel, with acknowledgements and resends, carries what a Player must not miss: a Player joined, left or timed out, an explosion, a Ship destroyed, game over. What is on screen never waits for it. We chose this after playing with the six approaches in the netcode simulator (branch `poc/netcode`): under lag, its symptom is rubber-banding, which the team found the least annoying of those it saw, and it recovers from lost packets on its own.

## Considered options

- **An event stream**, unreliable or reliable and ordered: when lag clears, what a Client shows snaps back to the truth; a lost event leaves the Client wrong until something corrects it, and the reliable variant freezes behind every loss.
- **Snapshots alone**: the same recovery, but nothing guarantees delivery of what must not be missed, such as a Player leaving.
- **A TCP-like stream**: one lost packet freezes the Client until it is resent, and the subject wants in-game traffic over UDP.
- **Lockstep**: everyone freezes as soon as one Client is slow or gone.

## Consequences

- K is a Server setting, 1 by default: Clients draw the newest Snapshot as it is, so a larger K shows as jerky movement. In the simulator, 60 Snapshots a second overflowed a 5 KB/s link, and K = 4 fixed it.
- A Snapshot always fits in one datagram: the Server should refuse to create Snapshots bigger than the datagram limit.
- That refusal is a last resort, counted and logged, that should never trigger: the Game refuses any spawn that would push the next Snapshot past the datagram limit. This is the Snapshot's entity cap. Skipping a Snapshot would freeze every Client, and leaving entities out of one would make Clients read them as destroyed.
- Interpolation, prediction, delta compression and Snapshots split across datagrams are left for Part 2.
