# Networking

How the Server and the Clients stay in step over UDP, and how one Server holds 20 Players. The measured results are on the [measurements page](../measurements.md).

## Keeping Clients in step

Before writing any of the game, we built a simulator ([`poc/netcode`](https://github.com/Holo-Org/R-Type/tree/poc/netcode/prototypes/netcode)) that runs a Server and Clients over a simulated network with latency, jitter, loss, duplication, reordering and a bandwidth cap, and played six approaches side by side on the same network luck:

| Approach | What travels | What we saw under lag and loss |
|---|---|---|
| Event stream, unreliable | one message per thing that happens, sent once | a lost event leaves the Client wrong until something corrects it |
| Event stream, reliable and ordered | the same, acknowledged and resent, applied in order | the Client freezes behind every loss, then snaps to the truth |
| Snapshots | every entity every K Ticks, newest wins; Inputs repeated | rubber-banding under lag, and recovery on its own after loss |
| **Snapshots plus a reliable channel** | the same, plus acknowledged Announcements for what must not be missed | the same recovery, and no Player leaving goes unnoticed |
| TCP-like stream | Snapshots on one reliable ordered stream | one lost packet freezes the Client until it is resent |
| Lockstep | only Inputs | everyone freezes as soon as one Client is slow or gone |

We chose Snapshots plus a small reliable channel ([ADR 0002](../adr/0002-snapshots-and-a-reliable-channel.md)): of the symptoms we saw, rubber-banding annoyed the team least, and it recovers from loss without help. It also keeps all in-game traffic on UDP, as the subject requires.

## Size of a datagram

At most 1,200 bytes of UDP payload, the size QUIC requires every path to carry, which avoids IP fragmentation on IPv4 and IPv6 alike ([ADR 0005](../adr/0005-datagrams-of-at-most-1200-bytes.md)). A Snapshot of full tables takes 854 bytes, which leaves room for 28 Announcements in the same datagram. Measured averages are far smaller: about 170 bytes from the Server and 27 from a Client in a 20-Player session.

## Hiding the delay: lag compensation

Kick-off 2 lists the techniques; we weighed them against our protocol and the time left.

| Technique | What it would need here | Chosen |
|---|---|---|
| Interpolation | Clients keep the last Snapshots and draw a little behind the newest | **Yes** |
| Extrapolation | Clients guess where entities go from their speed | No: Enemies weave and turn, so guesses would be wrong and corrected visibly |
| Client-side prediction and reconciliation | Clients move their own Ship at once and correct it from the Server's answer, which must say which Input it applied | No: the Server keeps only each Player's newest Actions, so it would first have to apply every Input at its own Tick |
| Input delay, rollback | every Client and the Server agree on an Input's Tick before it applies | No: a different protocol |

Interpolation draws about two Snapshot intervals behind the newest ([`client/interpolation.zig`](https://github.com/Holo-Org/R-Type/blob/main/client/interpolation.zig)). It makes fewer Snapshots look as smooth as more, so a Server can send a quarter of the Snapshots and use a quarter of the bandwidth. The price is that each Player sees their own Ship as late as everything else: 33 ms at one Snapshot per Tick, 133 ms at one every 4 Ticks. That is why the Server still sends one per Tick by default.

## Twenty Players on one Server

A Match takes four Players, as the subject's "four players in a game" says. The evaluator's target for the top score is 20 Players at once on one Server.

| Option | For | Against |
|---|---|---|
| **Five Matches side by side, each new Player in the first that takes them** | the protocol and the Client do not change; the Server stays one process | Players cannot choose who they play with |
| One Match of 20 Ships | everyone plays together | breaks four Players per game; 20 Ships and their Projectiles do not fit in one 1,200-byte Snapshot |
| A lobby where Players pick a Match | Players choose | a new screen and new messages, with no time left for them |

Every Match steps in the same Tick loop on the main thread, beside the network thread. Five Matches cost little at 60 Ticks a second, and a thread per Match would need locking around the shared transport for no gain we could measure.

## Measuring

Each end of a Connection counts what reaches it from the sequence numbers and acknowledgements the reliable channel already carries: the round trip, the datagrams lost, duplicated and late, and those sent that no acknowledgement covered. Nothing extra goes on the wire. The Server reports every Connection every 5 s and writes the figures as CSV; the Client shows its round trip and loss on screen. `r-type_bot` plays 20 scripted Clients from one process, so a full session can be rehearsed and measured anywhere, including in CI under netem ([measurements](../measurements.md)).
