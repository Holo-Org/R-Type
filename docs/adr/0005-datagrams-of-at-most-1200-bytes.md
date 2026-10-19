---
status: accepted
---

# Datagrams of at most 1,200 bytes

Every datagram the Server or a Client sends carries at most 1,200 bytes of UDP payload, the size QUIC requires every network path to support ([RFC 9000 §14](https://www.rfc-editor.org/rfc/rfc9000#section-14)). Every IPv6 link carries packets of at least 1,280 bytes ([RFC 8200 §5](https://www.rfc-editor.org/rfc/rfc8200#section-5)), and RFC 9000 notes that most modern IPv4 networks do too. After the IP and UDP headers, that leaves 1,232 bytes of payload over IPv6 and 1,252 over IPv4, so 1,200 keeps a margin under both. A larger datagram risks IP fragmentation, which this project avoids. IPv6 routers never fragment: only the sender may, so a datagram too big for a link on its path is dropped. A fragmented IPv4 datagram is lost as soon as any one of its fragments is lost. RFC 9000 puts it plainly: UDP datagrams "MUST NOT be fragmented at the IP layer".

## Considered options

- **1,472 bytes**, the largest IPv4 payload on an Ethernet link with a 1,500-byte MTU: enough on a LAN, but paths through VPNs and tunnels can carry less.
- **Larger datagrams, up to UDP's 65,507 bytes**, left to IP fragmentation: one lost fragment loses the whole datagram, and IPv6 paths drop what does not fit.
- **Discovering each path's real limit** (path MTU discovery, RFC 9000 §14.2 and §14.3): more room on good paths, at the cost of probing logic that Part 1 does not need.

## Consequences

- A Snapshot must fit in one datagram ([ADR 0002](0002-snapshots-and-a-reliable-channel.md)), which bounds how many entities one Snapshot can describe.
- The Engine's transport drops, and counts, any incoming datagram larger than 1,200 bytes (`max_datagram_size` in `engine/headless/net.zig`).
