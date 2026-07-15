#!/bin/sh
# Tails a running godash qoo_raw.jsonl export and writes each new line's
# RTT/TTLB/loss straight to InfluxDB as its own point, tagged
# source="godash" so client-side QoO overlays directly with the collector's
# network-side qoo_* metrics in the same Grafana panels.
#
# Earlier implementations used an intermediate metrics bridge. For bursty
# godash segment writes, direct InfluxDB writes proved more reliable and
# simpler to operate. Each segment is now written as its own timestamped point
# and is durable once acknowledged by InfluxDB.
#
# Usage: ./push-godash-metrics.sh <qoo_raw.jsonl path> [protocol]
# Meant to be launched in the background by run-godash.sh for the duration
# of a stream; exits on its own once the file stops growing and is killed.
set -eu

# See scripts/run-active-probes.sh for why: awk's printf below honors
# LC_NUMERIC, comma-decimal locales break InfluxDB line-protocol syntax.
export LC_NUMERIC=C

JSONL_FILE="$1"
PROTOCOL="${2:-unknown}"
RUN_NUM="${3:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-push-metrics.sh"

# godash creates the export file lazily on its first flush - wait for it.
i=0
while [ ! -f "$JSONL_FILE" ] && [ "$i" -lt 50 ]; do
    sleep 0.2
    i=$((i + 1))
done

GW_PROFILE="$(gateway_profile)"

# godash is active application traffic (real segment fetches, not a
# dedicated link probe) and doesn't push an explicit bandwidth/throughput
# number - mode=active,bandwidth=false tags group it apart from
# active-probe (active, bandwidth=true) and collector (passive) in Grafana.
# run=$RUN_NUM (see run-godash.sh) lets Grafana show one series per run
# instead of per segment - all of one run's segments share this tag, so
# the godash dashboard panels can group by it instead of by segment.
TAGS="source=godash,mode=active,bandwidth=false,flow=godash-$PROTOCOL,run=$RUN_NUM"

# Use a FIFO instead of a direct `tail -F | while ...` pipe so `tail` remains
# a tracked child process. This lets EXIT/INT/TERM traps reliably clean up
# `tail` and the FIFO, including on interrupted runs.
FIFO="$(mktemp -u)"
mkfifo "$FIFO"
tail -n +1 -F "$JSONL_FILE" 2>/dev/null > "$FIFO" &
TAIL_PID=$!

cleanup() {
    kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

SEG=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    SEG=$((SEG + 1))

    RTT_MS="$(echo "$line" | grep -o '"rtt_ms"[[:space:]]*:[[:space:]]*[0-9.eE+-]*' | sed 's/.*://')"
    TTLB_MS="$(echo "$line" | grep -o '"ttlb_ms"[[:space:]]*:[[:space:]]*[0-9.eE+-]*' | sed 's/.*://')"
    LOST="$(echo "$line" | grep -o '"transport_lost_packets_total"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*://')"
    SENT="$(echo "$line" | grep -o '"transport_sent_packets_total"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*://')"

    LOSS_RATIO=""
    if [ -n "${LOST:-}" ] && [ -n "${SENT:-}" ] && [ "$SENT" -gt 0 ] 2>/dev/null; then
        LOSS_RATIO="$(awk -v lost="$LOST" -v sent="$SENT" 'BEGIN{printf "%.6f", lost/sent}')"
    fi

    {
        [ -n "${RTT_MS:-}" ]  && printf 'qoo_rtt_ms,%s,profile=%s,segment=%s value=%s\n' "$TAGS" "$GW_PROFILE" "$SEG" "$RTT_MS"
        [ -n "${TTLB_MS:-}" ] && printf 'qoo_ttlb_ms,%s,profile=%s,segment=%s value=%s\n' "$TAGS" "$GW_PROFILE" "$SEG" "$TTLB_MS"
        [ -n "${LOSS_RATIO:-}" ] && printf 'qoo_loss_ratio,%s,profile=%s,segment=%s value=%s\n' "$TAGS" "$GW_PROFILE" "$SEG" "$LOSS_RATIO"
        true
    } | influx_write
done < "$FIFO"
