# Network measurements

How the finished game behaves with 20 Players under the test conditions of Kick-off 2: loss, duplication, latency, reordering and a 1 Mbit/s link. Every figure below comes from one run that anyone can repeat.

## How we measure

The [Measure workflow](https://github.com/Holo-Org/R-Type/actions/workflows/measure.yml) runs [`.github/scripts/measure.sh`](https://github.com/Holo-Org/R-Type/blob/main/.github/scripts/measure.sh) on a GitHub-hosted Ubuntu 24.04 runner. For each condition, it:

1. shapes the loopback interface with netem;
2. starts one Server running five Matches, with `--stats` writing each Connection's figures as CSV;
3. runs `r-type_bot --clients 20 --seconds 60`: 20 scripted Clients, each with its own socket, which weave and hold fire for a minute, then leave;
4. reads the Server's figures for each Connection when it ended, and the bots' own figures for what reached them.

Two things to keep in mind when reading the figures:

- **On loopback, every datagram leaves an interface once.** A delay of 80 ms therefore applies to each direction, and the round trip is about 160 ms plus the Ticks each end waits before reading.
- **A rate limit on loopback is shared by everything:** the 20 Clients' Inputs and the Server's Snapshots, together. That is much harsher than a single Player on a 1 Mbit/s link.

The figures in the table are from [run 42385323260](https://github.com/Holo-Org/R-Type/actions/runs/42385323260), on 7 November 2026; its artifact holds every log and CSV file.

## Results

| Condition | netem on `lo` | Players | Round trip | Client → Server lost | Server → Client lost | Server → each Client | Datagram from the Server | Server up | All 20 bots kept the Server |
|---|---|---|---|---|---|---|---|---|---|
| none | | 20 | 16 ms | 0.00% | 0.00% | 9.9 KB/s | 164 B | yes | yes |
| loss | `loss random 2% duplicate 2%` | 20 | 16 ms | 2.01% | 1.91% | 9.5 KB/s | 158 B | yes | yes |
| latency | `delay 80ms 10ms` | 20 | 175 ms | 0.02% | 0.00% | 9.7 KB/s | 162 B | yes | yes |
| reorder | `delay 20ms reorder 25% 50%` | 20 | 47 ms | 0.01% | 0.00% | 9.2 KB/s | 154 B | yes | yes |
| 1 Mbit/s | `rate 1mbit` | 20 | 2,035 ms | 23.92% | 50.13% | 9.4 KB/s | 156 B | yes | no: 11 lost it |
| 1 Mbit/s, K = 4 | `rate 1mbit`, `--snapshot-every 4` | 20 | 1,583 ms | 9.72% | 15.50% | 2.4 KB/s | 160 B | yes | yes |

Each Client sends 1.7 KB/s to the Server: one 27-byte Input every Tick.

## What it shows

- **The Server stayed up under every condition**, with 20 Players in five Matches, and read no malformed datagram.
- **Loss and duplication are measured as they are applied**: 2% loss came out as 2.01% one way and 1.91% the other. The Server counted 1,440 duplicated datagrams from the Clients and ignored each one: an Input older than the newest applied changes nothing, and a Snapshot older than the newest drawn is dropped.
- **Latency and reordering cost nothing but time.** With 160 ms of delay, the round trip is 175 ms, nothing is lost, and no Announcement had to be resent; 971 Inputs arrived after a later one and were ignored.
- **The average datagram from the Server is 154 to 164 bytes**, well under the 1,200-byte limit, and a Client's is 27 bytes. A Snapshot of full tables would be 854.
- **1 Mbit/s for a whole 20-Player session is not enough at one Snapshot per Tick.** The session needs about 1.8 Mbit/s: 20 × (9.4 + 1.7) KB/s. netem queues what does not fit, so the round trip grows to 2 seconds, then datagrams are dropped. The Server timed Players out 20 times, 7 of them for leaving 32 Announcements unacknowledged; every bot joined, but at the end 11 of them had not heard from the Server for 3 seconds. The Server itself kept running.
- **One Snapshot every 4 Ticks fits the session in 1 Mbit/s, and the Clients stay smooth thanks to interpolation.** Snapshots fall from 9.4 to 2.4 KB/s per Client, and every bot kept the Server. The round trip is still high, because the Clients' Inputs, 60 a second each with 28 bytes of IP and UDP headers on 27 bytes of payload, now weigh as much as the Snapshots: the next saving would be to send Inputs less often.
- **For one Player on a 1 Mbit/s link**, which is how a Client would meet such a link outside our test, a Connection needs about 11 KB/s, or 90 kbit/s, at one Snapshot per Tick.

## Not measured here

- **Altered datagrams.** netem's `corrupt` keeps the checksum valid before it flips a bit, so the receiving kernel most likely drops the datagram, and the program never sees it ([research](https://github.com/Holo-Org/R-Type/blob/research/network-conditions/docs/research/network-conditions.md)). Only Clumsy on Windows, with "Redo checksum" on, delivers altered datagrams; the protocol's checks bound what they can do ([§9 of the spec](protocol.md#9-security-considerations)).
- **Remote Players** over the Internet, with real paths rather than a simulated one.

## Repeating it

On GitHub: run the Measure workflow from the Actions tab. On any Linux machine with netem, from the repository's root:

```sh
zig build -Doptimize=ReleaseSafe
.github/scripts/measure.sh measurements 60
```

On Windows, with [Clumsy](https://jagt.github.io/clumsy/) and the filter `udp.DstPort == 4242 or udp.SrcPort == 4242`:

| Condition | Clumsy setting |
|---|---|
| Latency | Lag, 80 ms (applied once each way on a filtered port) |
| Loss | Drop, 2% |
| Duplication | Duplicate, 2%, count 2 |
| Reordering | Out of order, 10% |
| Altered datagrams | Tamper, 5%, "Redo checksum" on |
| 1 Mbit/s | Bandwidth, 122 KB/s |

Then run `r-type_server --stats run.csv` and `r-type_bot --clients 20`, or play.
