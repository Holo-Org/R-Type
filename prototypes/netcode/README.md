# Netcode Simulator

> **PROTOTYPE. Throwaway code.** This is not part of the Engine or the Game, not a
> protocol spec, and not tested. It exists so the team can feel how replication
> approaches behave on a bad network and pick one together. Once the choice is
> made, keep the decision and archive this folder.

## The question

For each replication approach, what does each Client actually see compared with
the Server's truth, how late is it, how much bandwidth does it use, and what
breaks, under latency, jitter, loss, duplication, reordering and a bandwidth cap?

## How to open it

Double-click `index.html`. It is one self-contained file: no install, no server,
no network access. From the repository root in Nushell:

```nu
^open prototypes/netcode/index.html
```

Then either press the buttons in **Guided walkthroughs** (each one starts by
resetting to a known, seeded state), or use **Free play**: pick an approach,
optionally a second one to run side by side on the same network luck, move the
network sliders, and break things with "Drop the next packet", "Latency spike" or
"Crash Client". Tick "I play Player 1" to fly Player 1 with the arrow keys and
space.

## Approaches modelled

| | Approach | In one line |
|---|---|---|
| A | Event stream, unreliable | One message per thing that happens, sent once. A lost message is gone for good. |
| A | Event stream, reliable and ordered | Same messages with acknowledgements and resends, applied strictly in order. |
| B | Snapshots | Clients send their keys every Tick (last N repeated); the Server sends every entity every K Ticks, unreliably, newest wins. |
| C | Hybrid | B, plus a small reliable channel for Player joined/left/timed out, explosions, Ship destroyed, game over. |
| D | TCP-like | B's snapshots on one reliable ordered stream over the same lossy link. Head-of-line blocking. |
| E | Lockstep | Only inputs travel; everyone advances Tick t once they have every Player's input for t. |

## Walkthroughs

1. **Lost spawn**: A unreliable, 2% loss. The packet announcing Wave 2 is lost on its way to Client 2, which never sees those Enemies.
2. **Self-healing**: A unreliable vs B at 10% loss. A piles up missing entities and frozen ghosts; B stays exact, just late.
3. **Appendix test**: 150 ms, 2% loss, 2% duplication. A reliable freezes behind every loss; C does not; then B vs C.
4. **5 KB/s**: B at 60 snapshots per second on a 5 KB/s link. The queue grows without end; K = 4 fixes it; fewer entities alone does not.
5. **Head-of-line**: D vs B. One lost packet freezes the D Client until the resend, then everything lands at once.
6. **Lockstep stall**: E vs B. One slow Client, then one crash, stop everyone; at 150 ms the Match runs at half speed unless input delay grows.
7. **Client crash**: A unreliable vs C. Detection by a 3 s timeout, and a lost "Player left" announcement that only C recovers.

## Modelling assumptions

Everything below is a choice made for this prototype, shown on the page as well.

### Network

- Each Client has two links (Server → Client and Client → Server) with the same settings. 1 KB = 1000 bytes.
- Latency is one way. Jitter adds a random 0 to jitter ms per packet but keeps packet order. Reordering is a separate setting: that share of packets is held back 20 to 60 ms.
- Loss and duplication are independent per packet, with no bursts.
- Bandwidth cap: a packet occupies the link for size ÷ cap, behind one first-in, first-out queue that never drops. Sending more than the cap becomes ever-growing delay.
- Randomness is a hash of (seed, link, Tick, packet position within the Tick), so both sides of a comparison see the same network luck and every scenario replays identically.
- The Server reads packets once per Tick, each Client once per Frame, both at 60 Hz.

### Bytes (assumed layout, uncompressed)

| Part | Bytes |
|---|---|
| IPv4 + UDP headers | 28 |
| Game header: protocol id 2, type 1, flags 1, Tick 4, sequence 2, ack 2, ack bits 4 | 16 |
| D only: IPv4 + TCP headers, then protocol id 2, type 1, flags 1, Tick 4 | 40 + 8 |
| Snapshot: entity count 1, connected Players 1, then per entity id 2, kind 1, Player or flags 1, x 2, y 2 | 2 + 8 per entity |
| Inputs (B, C): count 1, then 1 byte of keys per input | 1 + N |
| Events (A): spawned 8, moved 7, fired 12, destroyed 3, Ship destroyed 8, Player left 3, keys changed 2 | as listed |
| Reliable message id (A reliable, C) | +2 each |
| Lockstep: Tick count 1, then per Tick Players present 1 + 1 per Player | 1 + … |

At 60 packets per second, the 44 bytes of IPv4, UDP and game headers alone cost 2.6 KB/s.

### Protocols

- Acknowledgements carry the latest sequence number received plus 32 bits for the 32 before it.
- A reliable and C resend a message not confirmed after the measured round trip + 50 ms. D resends a segment after max(200 ms, 2 × measured round trip), with no fast retransmit, congestion control or backoff.
- A Clients send a keys-changed message only when their keys change, plus a heartbeat after 250 ms of silence; reliable A Clients also acknowledge every Frame in which they received something. Unreliable A applies messages in arrival order and ignores messages about entities it does not know. A Clients move Projectiles themselves after "fired"; Enemies and Ships move only on "moved".
- E repeats every unconfirmed input (and input bundle) in each packet, up to 32 Ticks. Nobody runs more than one Tick per 16.7 ms, so time lost waiting is never caught up.
- A Client silent for the timeout (3 s by default) is removed and announced to the others.

### Game

- 640 × 360 playfield. A Wave of Enemies spawns on the right every 4 s (first at 1.5 s) and drifts left; Enemies fire toward the Ship closest in height; Ships fire right; a destroyed Ship returns after 2 s. The Match never ends.
- Players other than you follow a seeded script that changes their keys every 0.5 s.

## Known inaccuracies

- Clients show the newest data they have: no interpolation, extrapolation or client-side prediction. Real Clients would trade some delay for smoothness, or hide their own Ship's delay by predicting it.
- The TCP-like stream is simplified: real TCP also has fast retransmit (usually recovering one loss in about a round trip) and congestion control (slowing down on loss).
- Real routers drop packets when their queue fills; this queue never drops.
- No delta compression, bit packing or MTU splitting of snapshots.
- "Late by" for A measures the newest Server Tick a Client has caught up with, so it overstates lateness in quiet moments when only heartbeats arrive.
- Time advances in whole Ticks (16.7 ms), which rounds every delay up to the next Tick.

## Where the logic lives

The `<script id="netcode-model">` block in `index.html` is a pure module (`Netcode`) with
no DOM access: the game, the links, the six replication variants and the metrics. The
second script is a thin page shell (drawing, controls, walkthroughs) that calls into it.
