#!/usr/bin/env bash
# Measures a 20-Player session under each of Kick-off 2's test conditions,
# shaped by netem on the loopback interface: one Server running five Matches
# and 20 bots (r-type_bot), for a minute each. Run by
# .github/workflows/measure.yml; on any Linux machine with sch_netem, from the
# repository's root, after `zig build -Doptimize=ReleaseSafe`:
#
#     .github/scripts/measure.sh [folder] [seconds]
#
# It writes into the folder (measurements/ by default), for each condition,
# the Server's log, its --stats CSV and the bots' log, then summary.md: one
# table row per condition, for the docs site's results page. It needs sudo for
# tc, and clears the loopback's qdisc when it ends.
#
# netem shapes what leaves an interface. On loopback, every datagram leaves
# once, so a delay applies to each direction and the round trip gets twice
# that; a rate limits the Server's and the bots' traffic together.

set -euo pipefail

out=${1:-measurements}
seconds=${2:-60}
bin=zig-out/bin
port=42600
mkdir -p "$out"

# name|netem options|Server options
conditions=(
  "none||"
  "loss|loss random 2% duplicate 2%|"
  "latency|delay 80ms 10ms|"
  "reorder|delay 20ms reorder 25% 50%|"
  "1mbit|rate 1mbit|"
  "1mbit-k4|rate 1mbit|--snapshot-every 4"
)

# Applies netem `options` to the loopback, or only clears it when empty.
shape() {
  sudo tc qdisc del dev lo root 2>/dev/null || true
  if [ -n "$1" ]; then
    # shellcheck disable=SC2086 # the options are words on purpose
    sudo tc qdisc add dev lo root netem $1
  fi
}
trap 'shape ""' EXIT

cat > "$out/summary.md" <<'EOF'
| Condition | netem on `lo` | Players | Round trip | Client → Server lost | Server → Client lost | Server → each Client | Datagram size | Server up | Bots |
|---|---|---|---|---|---|---|---|---|---|
EOF

for condition in "${conditions[@]}"; do
  IFS='|' read -r name netem server_options <<<"$condition"
  echo "== $name: netem '${netem:-none}' ${server_options}"
  shape "$netem"

  # shellcheck disable=SC2086 # the options are words on purpose
  "$bin/r-type_server" --port "$port" --seed 2026 --join-window 2 --stats "$out/$name.csv" $server_options \
    2> "$out/$name.server.log" &
  server=$!
  sleep 1
  bots=passed
  "$bin/r-type_bot" --port "$port" --clients 20 --seconds "$seconds" 2> "$out/$name.bots.log" || bots=failed
  # Connections whose disconnect was lost end by timing out, 3 s later.
  sleep 5
  if kill -0 "$server" 2>/dev/null; then up=yes; kill "$server"; else up=no; fi
  wait "$server" 2>/dev/null || true
  port=$((port + 1))

  # The bots' own figures: what reached them from the Server.
  read -r bot_received bot_lost < <(grep -o 'in: [0-9]* datagrams, [0-9]* lost' "$out/$name.bots.log" |
    awk '{ received += $2; lost += $4 } END { print received + 0, lost + 0 }')
  # The Server's, from each Connection's last row, when it ended.
  awk -F, -v name="$name" -v netem="${netem:-none}${server_options:+, $server_options}" \
    -v up="$up" -v bots="$bots" -v bot_received="$bot_received" -v bot_lost="$bot_lost" '
    $5 == "closed" {
      n++; rtt += $6; received += $7; lost += $8; sent += $11
      bytes_out += $14; seconds += $2
    }
    END {
      if (n == 0) { printf "| %s | `%s` | 0 | | | | | | %s | %s |\n", name, netem, up, bots; exit }
      printf "| %s | `%s` | %d | %d ms | %.2f%% | %.2f%% | %.1f KB/s | %d B | %s | %s |\n",
        name, netem, n, rtt / n,
        100 * lost / (received + lost),
        (bot_received + bot_lost) ? 100 * bot_lost / (bot_received + bot_lost) : 0,
        bytes_out / seconds / 1000, bytes_out / sent, up, bots
    }' "$out/$name.csv" >> "$out/summary.md"
  tail -n 1 "$out/summary.md"
done
