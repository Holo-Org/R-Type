# How netem and Clumsy reproduce the kick-off's test conditions

Issue: Holo-Org/R-Type#67. Researched on 2026-11-07.

The evaluators will test the game with Clumsy (Windows) or netem (Linux) under
five conditions: 1 Mbit/s bandwidth, latency above 100 ms, 2% packet loss,
duplication and reordering, and tampered packets. This note gives the commands
and settings to reproduce them, and says what is verified and what is not.

Legend: **[doc]** stated by the cited primary source; **[code]** read in the
tool's source code; **[derived]** my reasoning from those sources, not run;
**[untested]** a command assembled from the man pages and never executed here
(the author's machine is macOS, with no Linux kernel or Windows to hand).

## 1. netem (Linux)

### Basics

- netem is a qdisc, so it shapes the **egress** queue of the device it is
  attached to. Syntax: `tc qdisc ... dev DEVICE add netem OPTIONS` [doc: tc-netem(8)].
- Units: delay and jitter in ms; loss, duplicate, corrupt, reorder in percent;
  rate in `kbit`, `mbit`, etc. [doc]. The man page's own example uses `kbit`;
  it does not list every unit, so `1mbit` is the usual tc spelling (see tc(8)).
- Options can be combined in one `netem` command [doc: synopsis lists them all].
- `reorder` only works if there is a `delay`, and the delay must exceed the
  gap between packets, otherwise nothing is reordered [doc].
- `limit` is the maximum number of packets held while delaying (default 1000
  per the kernel; the man page only says "packets") [doc].

### One block per condition

Replace `lo` by the real interface (for instance `eth0`) where relevant. Use
`add` the first time; swap `add` for `change` to alter an existing netem.

```sh
# 1. Very low bandwidth: 1 Mbit/s
sudo tc qdisc add dev lo root netem rate 1mbit

# 2. High latency: see the loopback pitfall below. 120 ms one way on a real link
sudo tc qdisc add dev eth0 root netem delay 120ms
# optional jitter and a normal distribution: delay 120ms 20ms distribution normal

# 3. Packet loss: 2%
sudo tc qdisc add dev lo root netem loss random 2%

# 4a. Duplication: 5% of packets are copied
sudo tc qdisc add dev lo root netem duplicate 5%

# 4b. Reordering: needs a delay. 25% of packets skip the 10 ms delay (50% correlation)
sudo tc qdisc add dev lo root netem delay 10ms reorder 25% 50%

# 5. Altered packets: one random bit flipped in 5% of packets
sudo tc qdisc add dev lo root netem corrupt 5%
```

Everything at once (this is what an evaluator most likely runs), then remove:

```sh
sudo tc qdisc add dev eth0 root netem \
    delay 120ms 20ms loss random 2% duplicate 5% reorder 25% 50% \
    corrupt 1% rate 1mbit
tc -s qdisc show dev eth0        # check it, with counters
sudo tc qdisc change dev eth0 root netem delay 200ms   # replaces ALL options
sudo tc qdisc del dev eth0 root  # remove everything
```

`change` replaces the whole option set, it does not add to it [derived from the
kernel's `netem_change()`, which rebuilds the parameters; [doc] examples use
`change` with a single option each].

### Two machines, a real interface

- Run the commands on the interface that faces the other machine, on **each**
  machine for a symmetric link. On one machine only, the impairment applies to
  that machine's outgoing packets only (it is an egress qdisc) [derived].
- Delay then costs one delay per direction that has netem; with netem on both
  ends, RTT is about twice the delay (plus jitter).
- Do not break your own SSH session: restrict netem to the game's UDP port
  (next section), or keep a second path to the machine.

### Restricting to one UDP port (prio + u32) [untested]

The man page shows the pattern (a `prio` qdisc, netem in one band, a `u32`
filter sending matching traffic there) [doc]. Adapted to one port, with
`4242` as a placeholder for the game's port:

```sh
sudo tc qdisc add dev eth0 root handle 1: prio
sudo tc qdisc add dev eth0 parent 1:3 handle 30: netem delay 120ms loss random 2%
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 \
    match ip protocol 17 0xff \
    match ip dport 4242 0xffff flowid 1:3
sudo tc qdisc del dev eth0 root  # removes the lot
```

On the server machine, match `sport` instead of `dport` to hit the
server-to-client direction.

### Combining rate with delay: netem `rate` or a `tbf` qdisc

- **Simplest: netem `rate` plus `delay` in one qdisc**, as above. netem adds
  the packet's transmission time at the configured rate to its send time, so
  packets are spaced out [code: `packet_time_ns()` and `netem_enqueue()` in
  sch_netem.c].
- netem's own man page warns that rate throttling is affected by the kernel
  clock granularity and can produce packet bursts [doc].
- **Alternative: a `tbf` qdisc** for the rate and netem for the rest. tbf needs
  `rate`, `burst`, and either `latency` or `limit`; burst must be at least
  rate/HZ or packets can be dropped [doc: tc-tbf(8)]. The tbf man page shows
  attaching an inner qdisc with `parent 10:1` [doc]. [untested]:

```sh
sudo tc qdisc add dev eth0 root handle 1: tbf rate 1mbit burst 8kb latency 300ms
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 120ms loss random 2%
```

- Queue depth matters at 1 Mbit/s: with the default 1000-packet limit, a
  sender that exceeds the rate sees seconds of queueing rather than loss.
  Lower `limit` (for instance `limit 50`) if you want loss instead [derived].

### Pitfalls

1. **Delay on `lo` is paid twice per round trip.** Packets in both directions
   leave through `lo`, so a root qdisc on `lo` delays the request and the
   reply. `delay 60ms` on `lo` gives an RTT of about 120 ms [derived, not
   measured; the equivalent behaviour is documented for Clumsy, see 2]. To
   delay one direction only, use the port filter above with `dport` or `sport`.
2. **netem on `lo` also hits everything else on localhost** (databases, your
   editor's language server). Use the port filter when that matters [derived].
3. **`reorder` without `delay` does nothing** [doc]. Jitter alone can also
   reorder, because of netem's internal time-sorted queue; the man page shows
   how to replace it with a plain FIFO to keep order or to allow reordering [doc].
4. **`corrupt` and UDP checksums.** In the kernel, netem's corrupt path first
   makes the checksum real (`skb_checksum_help()`, which sets
   `ip_summed = CHECKSUM_NONE` and writes the checksum into the packet), then
   flips one random bit at a random byte of `skb->data` [code: sch_netem.c
   `netem_enqueue()`; net/core/dev.c `skb_checksum_help()`]. Consequences
   [derived, **not tested**]:
   - the receiver's UDP checksum is computed over the already-flipped data, so
     a flip inside the UDP header or payload is normally **detected and the
     datagram silently dropped by the kernel**; the game never sees it;
   - a flip may land in a part nobody checks (on `lo` the data starts with a
     14-byte Ethernet header, `hard_header_len = ETH_HLEN` [code: loopback.c]),
     or in a datagram sent with a zero UDP checksum, and those reach the program;
   - so `corrupt` mostly behaves like extra loss. To exercise the game's own
     integrity checks, the Clumsy path (Redo checksum on) is the reliable one,
     or flip bits in the test harness itself.
5. **Do not run `add` twice.** The second `add` fails with "File exists"; use
   `change` or `del` first [common tc behaviour, not looked up].
6. **Remove it after use**; a leftover netem on `lo` slows the whole machine.

## 2. Clumsy (Windows)

Clumsy 0.3 is a no-install tool built on WinDivert; it captures packets
system-wide, works for localhost-to-localhost connections, and lets you toggle
each function while the program runs [doc: clumsy README and site]. Note the
site lists version 0.3, while the source below is the `master` branch; names
and defaults may differ in the released binary [unverified].

### Settings to reproduce the five conditions

| Condition | Clumsy function | Setting | Notes |
|---|---|---|---|
| Latency over 100 ms | Lag | Delay(ms) = 120 (range 0 to 15000, default 50) | [code: lag.c] |
| Loss 2% | Drop | Chance(%) = 2.0 | Chance steps of 0.1%, default 10.0 [code: drop.c] |
| Duplication | Duplicate | Chance(%) = 5.0, Count = 2 | Count 2 sends one extra copy; range 2 to 50 [code: duplicate.c] |
| Reordering | Out of order | Chance(%) = 10.0 | No delay value: it swaps adjacent queued packets or holds one back for at most 10 processing steps [code: ood.c] |
| Altered packets | Tamper | Chance(%) = 5.0, **Redo checksum ON** | Default is ON [code: tamper.c] |
| 1 Mbit/s | Bandwidth | Limit(KB/s) = 122 | See note below [code: bandwidth.c] |

Each function has Inbound and Outbound checkboxes (default both on) and its
own enable checkbox; its icon turns green when it works [doc: clumsy manual].
Throttle (Timeframe(ms), Drop Throttled, Chance) and Set TCP RST are also
present but are not in the kick-off's list [doc/code].

Bandwidth notes [code: bandwidth.c]:

- The limit is in KB/s, with 1 KB taken as 1024 bytes (`limit * 1024`).
  122 KB/s is 999,424 bit/s, close to 1 Mbit/s; 125 would give 1.02 Mbit/s.
- It does **not** queue or delay: when the traffic of the last 1000 ms window
  would exceed the limit, the packet is **dropped**. So it behaves like a
  policer; netem's `rate` behaves like a shaper. Expect more loss in Clumsy
  than with netem at the same rate.
- The cap is not enforced during the first second after enabling it.

Tamper notes [code: tamper.c]:

- Only packets that have a payload are touched. Short payloads (4 bytes or
  fewer) are XORed whole; longer ones have about a quarter of the bytes XORed,
  starting near the middle, with a fixed 8-byte pattern.
- With **Redo checksum** on, the code calls `WinDivertHelperCalcChecksums()`
  after the change, so the datagram has a valid checksum and **reaches the
  program altered**. With it off, the original checksum is kept and Windows
  will presumably reject the datagram (the source does not say so; inferred).
- The source has the comment `FIXME checksum seems to have some problem`, so
  do not assume it is flawless [code].
- WinDivert requires that injected packets have correct checksums or the
  matching checksum flag unset, and that a modified packet is recomputed with
  `WinDivertHelperCalcChecksums` before reinjection [doc: WinDivert 2.2 docs,
  sections 5.7 and 6.13].

### Filter for one UDP port

The filter box is passed straight to WinDivert [doc: clumsy manual]. Operators:
`and`, `or`, `not` (or `&&`, `||`, `!`), parentheses, `=`/`==`, `!=`, `<`, `>`.
UDP fields are `udp.SrcPort`, `udp.DstPort`, `udp.PayloadLength` [doc: WinDivert
filter language, section 7; clumsy manual]. With `4242` as a placeholder:

```text
udp.DstPort == 4242 or udp.SrcPort == 4242
```

For localhost traffic see the next section: add `outbound` and never `inbound`.
The default preset in the source loads this one for loopback:

```text
outbound and ip.DstAddr >= 127.0.0.1 and ip.DstAddr <= 127.255.255.255
```

Custom presets go in `config.txt` next to the executable, one `name: filter`
per line, `#` for comments [code: main.c]. Clumsy can also be driven from the
command line as `--key value` pairs, for example `--filter "..."`,
`--lag-time 120`, `--tamper-checksum on` (names read from the source:
`lag-inbound`, `lag-outbound`, `lag-time`, `tamper-inbound`, `tamper-outbound`,
`tamper-chance`, `tamper-checksum`, `bandwidth-inbound`, `bandwidth-outbound`,
`bandwidth-bandwidth`, `ood-chance`, a module toggle by its short name such as
`--lag on`, and `--timeout` in seconds) [code: main.c, utils.c and module
files]. The other parameter names were not read.

### Loopback on one Windows machine

- Yes, Clumsy handles localhost traffic [doc: README; manual]. WinDivert
  classifies **all loopback packets as outbound** and cannot capture them on
  the inbound path, so the filter must not require `inbound` [doc: clumsy
  manual; WinDivert docs, section 5.3].
- "Loopback" in Windows means any packet from and to the same machine, not
  only 127.0.0.0/8 [doc: WinDivert docs].
- The manual says loopback packets are processed twice (on send and on receive):
  with an outbound filter and 500 ms of lag, a localhost ping showed about
  1000 ms, and adding a destination port to the filter avoids the doubling
  [doc: clumsy manual]. Same pitfall as netem on `lo`. How exactly the
  doubling arises for a one-direction UDP flow is not explained there; measure
  it rather than assume.
- Running Clumsy needs the WinDivert driver; whether it must be started as
  administrator was not established from the sources read.

## 3. GitHub-hosted ubuntu-24.04 runners

**Short answer: yes, it works in practice. Use `sudo modprobe sch_netem`
first, and fall back to `linux-modules-extra-$(uname -r)` if that fails.**

Evidence:

- The runner image README for Ubuntu 24.04 lists kernel `7.0.0-1017-azure`
  and iproute2 6.1.0-1ubuntu6.4 (image 20261101.360.1), and says nothing about
  netem, tc modules or `linux-modules-extra` [doc: actions/runner-images,
  Ubuntu2404-Readme.md]. So nothing is promised by GitHub either way.
- A real workflow on `ubuntu-24.04` runs `sudo tc qdisc add dev lo root netem
  delay 10ms 2ms loss 0.5%` with **no modprobe and no extra package**, nightly,
  and its recent scheduled runs (3 to 7 November 2026) succeeded
  [DitchOoM/socket, `.github/workflows/quic-bench.yaml`; runs listed with
  `gh run list`]. This is the best evidence that `lo` + netem works out of the box.
- Another public workflow on `ubuntu-latest` loads it defensively and recent
  runs succeed: `sudo modprobe sch_netem || { sudo apt-get install -y
  "linux-modules-extra-$(uname -r)"; sudo modprobe sch_netem; }`
  [bigbluebutton/bbb-webrtc-recorder, `.github/workflows/e2e.yml`]. Another does
  the same with `modprobe -a sch_netem sch_prio cls_u32`, commenting that the
  runner's cloud kernel "may ship netem only in its -extra package"
  [matthart1983/netwatch, `health-lab.yml`]. That comment is a maintainer's
  caution, not proof the module is missing.
- Why the fallback is prudent: on `ubuntu-22.04` the matching
  `linux-modules-extra-5.15.0-1042-azure` package had no installation
  candidate when the runner kernel was newer than the packaged one, so
  `modprobe` of an extra module failed [GitHub community discussion 63910, for
  other modules; unanswered]. The same risk could apply to a future 24.04 kernel.
- A search of actions/runner-images issues for "netem" returned nothing.

Recommended step (the `lo` form is the proven one):

```yaml
jobs:
  netem:
    runs-on: ubuntu-24.04   # pin it: ubuntu-latest moves to 26.04 in November 2026
    steps:
      - name: Load netem
        run: |
          sudo modprobe sch_netem || {
            sudo apt-get install -y "linux-modules-extra-$(uname -r)"
            sudo modprobe sch_netem
          }
      - name: Impair loopback
        run: sudo tc qdisc add dev lo root netem delay 60ms loss random 2%
      # ... run the tests ...
      - name: Clean up
        if: always()
        run: sudo tc qdisc del dev lo root
```

The `ubuntu-latest` move to Ubuntu 26.04 is announced in the runner-images
README. I did not run any workflow myself, and I did not check macOS or
Windows hosted runners.

## 4. macOS: dnctl and pfctl (dummynet)

macOS ships `dnctl(8)` (pipes) and `pfctl(8)`/`pf.conf` (rules that send
traffic into a pipe). From the local man page of dnctl on macOS 26.5.2 [doc]:

- A pipe emulates a link with a given bandwidth, propagation delay, queue
  size and packet loss rate. Parameters: `bw` (for instance `300Kbit/s`, unit
  glued to the number), `delay` (ms, rounded to the clock tick), `plr`
  (0 to 1, so 2% is `0.02`), `queue` (slots or KBytes).
- The man page lists **no duplication, no reordering and no corruption**. For
  those conditions use a Linux VM, or Clumsy/netem on the evaluator's side.
- The man page's own example pairs `dnctl pipe 1 config delay 250ms bw
  1Mbit/s` with the rules `dummynet in all pipe 1` and `dummynet out all pipe 2`
  in pf.conf.

Sketch for one UDP port [untested; I did not change the firewall on this
machine; the pf dummynet rule syntax is from the dnctl man page examples, and
the anchor setup needs checking]:

```sh
sudo dnctl pipe 1 config bw 1Mbit/s delay 60ms plr 0.02 queue 50
echo 'dummynet in  quick proto udp from any to any port 4242 pipe 1
dummynet out quick proto udp from any to any port 4242 pipe 1' | sudo pfctl -f - -E
sudo dnctl list
# remove
sudo dnctl -q flush ; sudo pfctl -f /etc/pf.conf ; sudo pfctl -d
```

Two cautions: `pfctl -f -` replaces the active ruleset, so load rules the way
your setup expects (an anchor is cleaner), and whether pf sees traffic on
`lo0` depends on `set skip on lo0`, which the pf.conf man page mentions as
common practice [doc]. Whether dummynet works on `lo0` was not established.
On macOS, delay on a loopback flow would likely be paid in both directions as
with netem; this is a guess.

## What could not be verified

- Nothing in this note was executed against a kernel or Windows: all commands
  are from man pages and source code, and those marked [untested] or [derived]
  are my assembly of them.
- Whether corrupted datagrams from `netem corrupt` ever reach a UDP socket
  (point 4 of the pitfalls) is inferred from the kernel code, not measured.
- Whether Clumsy 0.3 (the released binary) matches the `master` source read.
- Clumsy's administrator requirement and the exact cause of the loopback
  "processed twice" doubling.
- dnctl/pfctl behaviour on `lo0`, and the anchor syntax on current macOS.

## Sources

- tc-netem(8): https://man7.org/linux/man-pages/man8/tc-netem.8.html
- tc-tbf(8): https://man7.org/linux/man-pages/man8/tc-tbf.8.html
- Linux sch_netem.c: https://github.com/torvalds/linux/blob/master/net/sched/sch_netem.c
- Linux net/core/dev.c (`skb_checksum_help`): https://github.com/torvalds/linux/blob/master/net/core/dev.c
- Linux loopback driver: https://github.com/torvalds/linux/blob/master/drivers/net/loopback.c
- Clumsy site: https://jagt.github.io/clumsy/
- Clumsy manual: https://jagt.github.io/clumsy/manual.html
- Clumsy repository: https://github.com/jagt/clumsy (src/tamper.c, bandwidth.c, lag.c,
  drop.c, duplicate.c, ood.c, throttle.c, main.c, utils.c)
- WinDivert docs: https://github.com/basil00/WinDivert/blob/master/doc/windivert.html
- Ubuntu 24.04 runner image: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
- DitchOoM/socket workflow: https://github.com/DitchOoM/socket/blob/0451d96bdc3a7b0504f95b4358491e8bc1b04240/.github/workflows/quic-bench.yaml
- bbb-webrtc-recorder workflow: https://github.com/bigbluebutton/bbb-webrtc-recorder/blob/88714905bcc5398f6344fc77dcb7a6dbf9c7804b/.github/workflows/e2e.yml
- netwatch workflow: https://github.com/matthart1983/netwatch/blob/dcc81ba375d0068d70490c876a9763f93e239b22/.github/workflows/health-lab.yml
- GitHub community discussion on missing linux-modules-extra: https://github.com/orgs/community/discussions/63910
- dnctl(8) and pf.conf(5): `man dnctl`, `man pf.conf` on macOS 26.5.2
