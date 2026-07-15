#!/bin/sh
# Runs active ping + iperf3 probes through the gateway (against target's
# real routed IP, not the public internet) and emits JSON lines on stdout.
# Usage: ./run-active-probes.sh [ping-target] [iperf-server] [ping-count] [iperf-duration]
#
# Requires host routing to actually be set up first (setup-routing.sh on
# Linux, setup-mac-wireguard.sh on macOS) - target's iperf3 port isn't
# published to the host, unlike its HTTP/QUIC ports, specifically so this
# script doesn't silently bypass gateway impairment.
set -e

# Force C numeric locale: awk's printf honors LC_NUMERIC, and on hosts with
# a comma-decimal locale (e.g. pt_PT) it emits "761,729" instead of
# "761.729" for throughput/loss below - invalid InfluxDB line-protocol
# syntax, silently rejected by the write API and corrupting probes.jsonl as
# invalid JSON.
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-push-metrics.sh"

ROUTED_TARGET_IP="172.29.0.20"

PING_TARGET="${1:-$ROUTED_TARGET_IP}"
IPERF_SERVER="${2:-$ROUTED_TARGET_IP}"
PING_COUNT="${3:-20}"
IPERF_DURATION="${4:-10}"

# Same data/ folder every other part of the stack (pcap, influxdb, grafana)
# writes to - so probe history lives next to everything else instead of
# only ever appearing on stdout.
DATA_DIR="$SCRIPT_DIR/../data/active-probes"
mkdir -p "$DATA_DIR"
PROBES_LOG="$DATA_DIR/probes.jsonl"

# Small persistent counter (1, 2, 3, ...) identifying this invocation in
# Grafana - mirrors run-godash.sh's RUN_NUM. Target IP is still stored as a
# tag (useful raw context), but it's a poor legend label: it's constant
# across every run against the same target, so it can't tell two different
# invocations apart the way a run number can.
RUN_COUNTER_FILE="$DATA_DIR/.run_counter"
RUN_NUM=$(( $(cat "$RUN_COUNTER_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$RUN_NUM" > "$RUN_COUNTER_FILE"

ts() { date +%s; }
emit() { echo "$1" | tee -a "$PROBES_LOG"; }

if ! ping -c 1 "$ROUTED_TARGET_IP" >/dev/null 2>&1; then
    echo "*** $ROUTED_TARGET_IP unreachable - set up routing first: ***" >&2
    echo "***   Linux:  ./scripts/setup-routing.sh $ROUTED_TARGET_IP ***" >&2
    echo "***   macOS:  ./scripts/setup-mac-wireguard.sh ***" >&2
    exit 1
fi


echo "=== active probes: ping $PING_TARGET ($PING_COUNT) ==="

# --- ping probe ---
PING_OUT="$(ping -c "$PING_COUNT" "$PING_TARGET" 2>&1 || true)"

RTT_AVG="$(echo "$PING_OUT" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p' | head -1)"
LOSS_PCT="$(echo "$PING_OUT" | grep -Eo '[0-9.]+% packet loss' | grep -Eo '^[0-9.]+' | head -1)"

emit "{\"type\":\"ping\",\"target\":\"$PING_TARGET\",\"rtt_avg_ms\":${RTT_AVG:-null},\"loss_pct\":${LOSS_PCT:-null},\"ts\":$(ts)}"

# active-probes is a dedicated active measurement (synthetic ping/iperf3
# traffic, not real app traffic) that includes an explicit bandwidth
# measurement (iperf3) - mode/bandwidth tags let Grafana group this apart
# from godash (active, no bandwidth) and collector (passive). run=$RUN_NUM
# lets Grafana group/color by invocation instead of by (constant) target IP.
TAGS="source=active-probe,mode=active,bandwidth=true,run=$RUN_NUM"

GW_PROFILE="$(gateway_profile)"
{
    [ -n "$RTT_AVG" ] && printf 'qoo_rtt_ms,%s,target=%s,profile=%s value=%s\n' "$TAGS" "$PING_TARGET" "$GW_PROFILE" "$RTT_AVG"
    # awk -v passes the shell value as a variable instead of interpolating
    # it into the awk program text - interpolating it directly here (inside
    # a command substitution that's itself an argument to printf) triggers
    # a real quote-parsing bug in macOS's bash 3.2 (used as /bin/sh) that
    # silently drops the awk script's braces and hangs forever on stdin.
    [ -n "$LOSS_PCT" ] && printf 'qoo_loss_ratio,%s,target=%s,profile=%s value=%s\n' "$TAGS" "$PING_TARGET" "$GW_PROFILE" "$(awk -v pct="$LOSS_PCT" 'BEGIN{printf "%.6f", pct/100}')"

    # One point per individual ping reply (icmp_seq=N ... time=X ms), not
    # just the batch average - a separate measurement so it doesn't clash
    # with qoo_rtt_ms's one-value-per-point semantics.
    #
    # All of these lines get written in the SAME curl call as everything
    # else in this block (all piped into one `influx_write` below), and
    # `ping -c N` only returns after every reply is already in - so without
    # an explicit timestamp on each line, InfluxDB would stamp all N replies
    # with the exact same "now" (this call's write time), even though they
    # actually happened one real second apart. That collapsed every sample
    # onto one x-position in Grafana - indistinguishable from no data at
    # all. Reconstruct each reply's real time instead: ping's default
    # interval is 1 packet/sec, so counting back from "now" by (total
    # samples - 1 - position) seconds recovers each one's actual moment.
    PING_SAMPLES="$(echo "$PING_OUT" \
        | grep -Eo 'icmp_seq=[0-9]+.*time=[0-9.]+ ms' \
        | sed -E 's/icmp_seq=([0-9]+).*time=([0-9.]+) ms/\1 \2/')"
    SAMPLE_COUNT="$(printf '%s\n' "$PING_SAMPLES" | grep -c .)"
    NOW_EPOCH="$(ts)"
    i=0
    if [ "$SAMPLE_COUNT" -gt 0 ]; then
        printf '%s\n' "$PING_SAMPLES" | while read -r SEQ VAL; do
            [ -z "$SEQ" ] && continue
            SAMPLE_TS_NS=$(( (NOW_EPOCH - (SAMPLE_COUNT - 1 - i)) * 1000000000 ))
            printf 'qoo_ping_sample_rtt_ms,%s,target=%s,profile=%s,seq=%s value=%s %s\n' "$TAGS" "$PING_TARGET" "$GW_PROFILE" "$SEQ" "$VAL" "$SAMPLE_TS_NS"
            i=$((i + 1))
        done
    fi
} | influx_write

# --- iperf3 probe ---
if command -v iperf3 >/dev/null 2>&1; then
    echo "=== active probes: iperf3 $IPERF_SERVER ($IPERF_DURATION) ==="
    # target/entrypoint.sh runs a single `iperf3 -s`, which serves one client
    # at a time - back-to-back or overlapping runs of this script (or one
    # that didn't disconnect cleanly) make the server reply
    # {"error":"the server is busy running a test. try again later"} with no
    # bits_per_second at all, silently producing a null throughput. Retry a
    # couple of times with a short backoff instead of giving up on the first
    # collision - the server frees up as soon as the other client's test ends.
    IPERF_ATTEMPT=0
    IPERF_JSON='{}'
    while [ "$IPERF_ATTEMPT" -lt 3 ]; do
        IPERF_JSON="$(iperf3 -c "$IPERF_SERVER" -t "$IPERF_DURATION" -J 2>/dev/null || echo '{}')"
        case "$IPERF_JSON" in
            *bits_per_second*) break ;;
        esac
        IPERF_ATTEMPT=$((IPERF_ATTEMPT + 1))
        echo "iperf3 attempt $IPERF_ATTEMPT: server busy or no result, retrying..." >&2
        sleep 1
    done
    # iperf3's JSON is tab-indented - a tab sits between the colon and the
    # value ("bits_per_second":\t123.45), so a plain [0-9.]* right after
    # the colon matches nothing. sed strips everything up to the colon
    # instead of assuming no whitespace.
    THROUGHPUT_MBPS="$(echo "$IPERF_JSON" | grep -o '"bits_per_second"[[:space:]]*:[[:space:]]*[0-9.]*' | tail -1 | sed 's/^[^:]*:[[:space:]]*//')"
    if [ -n "$THROUGHPUT_MBPS" ]; then
        THROUGHPUT_MBPS="$(awk -v bps="$THROUGHPUT_MBPS" 'BEGIN{printf "%.3f", bps/1000000}')"
    fi
    emit "{\"type\":\"iperf3\",\"server\":\"$IPERF_SERVER\",\"throughput_mbps\":${THROUGHPUT_MBPS:-null},\"ts\":$(ts)}"
    if [ -n "$THROUGHPUT_MBPS" ]; then
        printf 'qoo_throughput_mbps,%s,target=%s,profile=%s value=%s\n' "$TAGS" "$IPERF_SERVER" "$GW_PROFILE" "$THROUGHPUT_MBPS" \
            | influx_write
    fi

    # iperf3 -J also reports one interval per second under "intervals[].sum"
    # (bits_per_second, and "end" - seconds since the test started) - report
    # each of those too, same idea as the individual ping samples above, not
    # just the -t-second test's single overall average. Parsed with python3
    # instead of more grep/sed: "intervals[].sum.bits_per_second" needs
    # actual JSON structure (there's also a per-stream bits_per_second next
    # to it, and a similarly-named "end.sum_received.bits_per_second"
    # overall summary) that a regex can't reliably tell apart from the
    # surrounding text alone.
    #
    # Like the ping samples above, these all land in one influx_write call
    # after iperf3 has already finished, so each needs its own reconstructed
    # timestamp (interval end-offset counted back from "now") - otherwise
    # every interval would get stamped with this call's single write time.
    INTERVALS="$(echo "$IPERF_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for iv in d.get("intervals", []):
    s = iv.get("sum", {})
    if "end" in s and "bits_per_second" in s:
        print(s["end"], s["bits_per_second"] / 1000000)
' 2>/dev/null)"
    if [ -n "$INTERVALS" ]; then
        NOW_EPOCH="$(ts)"
        i=0
        printf '%s\n' "$INTERVALS" | while read -r END_OFFSET MBPS; do
            [ -z "$END_OFFSET" ] && continue
            SAMPLE_TS_NS="$(awk -v now="$NOW_EPOCH" -v dur="$IPERF_DURATION" -v end="$END_OFFSET" \
                'BEGIN{printf "%.0f", (now - (dur - end)) * 1000000000}')"
            printf 'qoo_throughput_sample_mbps,%s,target=%s,profile=%s,interval=%s value=%.3f %s\n' \
                "$TAGS" "$IPERF_SERVER" "$GW_PROFILE" "$i" "$MBPS" "$SAMPLE_TS_NS"
            i=$((i + 1))
        done | influx_write
    fi
else
    echo "{\"type\":\"iperf3\",\"error\":\"iperf3 not installed - brew install iperf3 (macOS) or apt install iperf3 (Linux)\",\"ts\":$(ts)}" >&2
fi
