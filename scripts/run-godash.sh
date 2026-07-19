#!/bin/sh
# Runs the qoo-godash DASH client (applications/qoo-godash) against target's
# DASH content, over either plain TCP/HTTPS or QUIC/HTTP3, with QoO
# requirements scoring + JSONL export enabled.
# Usage: ./run-godash.sh [tcp|quic] [target-host] [target-port] [streamDuration] [adapt-algorithm]
#
# target-host/target-port select which path to target is used:
#   - 172.29.0.20 (target's real container IP, reachable via setup-routing.sh
#     on Linux or scripts/setup-mac-wireguard.sh on macOS) -> ROUTED THROUGH
#     GATEWAY, actually impaired by the active tc/netem profile.
#   - 127.0.0.1 with target's published ports (18000 tcp / 14433 quic) ->
#     BYPASSES gateway entirely, hits target directly. Useful for protocol
#     testing, but does NOT reflect any impairment profile.
# If target-host isn't given, this script probes whether 172.29.0.20 is
# actually reachable and prefers the routed path automatically. The script
# explicitly reports when it is using the bypass path.
set -e

PROTOCOL="${1:-tcp}"
TARGET_HOST_ARG="$2"
TARGET_PORT_ARG="$3"
STREAM_DURATION="${4:-20}"
ADAPT="${5:-conventional}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GODASH_DIR="$SCRIPT_DIR/../applications/qoo-godash"
CONFIG_TEMPLATE="$SCRIPT_DIR/godash-qoo-config.template.json"
ROUTED_TARGET_IP="172.29.0.20"

if [ ! -d "$GODASH_DIR" ]; then
    echo "*** $GODASH_DIR not found - clone qoo-godash into applications/ first ***" >&2
    exit 1
fi

cd "$GODASH_DIR"

# Rebuild when binary missing OR source changed since last build.
if [ ! -x ./godash ] || [ -n "$(find . -name '*.go' -newer ./godash -print -quit)" ]; then
    echo "building godash binary..."
    go build -o godash .
fi

case "$PROTOCOL" in
    tcp)  QUIC_FLAG=off; TESTBED_FLAG=off ;;
    quic)
        QUIC_FLAG=on
        # QUIC path requires the goDASHbed-style testbed cert flow (godash
        # never validates a plain self-signed cert outside of it - see
        # PLAN.md's godash QUIC notes). target/certs/{cert,key}.pem and
        # this checkout's http/certs/{cert,key}.pem must be the same pair.
        TESTBED_FLAG=on
        ;;
    *)
        echo "*** protocol must be 'tcp' or 'quic', not '$PROTOCOL' ***" >&2
        exit 1
        ;;
esac

if [ -n "$TARGET_HOST_ARG" ]; then
    TARGET_HOST="$TARGET_HOST_ARG"
    if [ "$PROTOCOL" = "tcp" ]; then TARGET_PORT="${TARGET_PORT_ARG:-8000}"; else TARGET_PORT="${TARGET_PORT_ARG:-4433}"; fi
    if [ "$TARGET_HOST" = "$ROUTED_TARGET_IP" ]; then
        PATH_KIND="ROUTED (explicitly requested)"
    else
        PATH_KIND="unknown - explicitly requested host $TARGET_HOST, can't tell if it's impaired"
    fi
elif ping -c 1 "$ROUTED_TARGET_IP" >/dev/null 2>&1; then
    TARGET_HOST="$ROUTED_TARGET_IP"
    if [ "$PROTOCOL" = "tcp" ]; then TARGET_PORT="${TARGET_PORT_ARG:-8000}"; else TARGET_PORT="${TARGET_PORT_ARG:-4433}"; fi
    PATH_KIND="ROUTED through gateway (auto-detected, real impairment applies)"
else
    TARGET_HOST="127.0.0.1"
    if [ "$PROTOCOL" = "tcp" ]; then TARGET_PORT="${TARGET_PORT_ARG:-18000}"; else TARGET_PORT="${TARGET_PORT_ARG:-14433}"; fi
    PATH_KIND="BYPASS via published ports (routed IP $ROUTED_TARGET_IP unreachable - run setup-routing.sh or setup-mac-wireguard.sh for real impairment)"
fi

case "$PROTOCOL" in
    tcp)  URL="http://$TARGET_HOST:$TARGET_PORT/dash/manifest.mpd" ;;
    quic) URL="https://$TARGET_HOST:$TARGET_PORT/dash/manifest.mpd" ;;
esac

# Preflight check: fail early with a clear fix when requested streamDuration is
# longer than what the current MPD can provide.
MPD_DURATION_ISO="$(curl -fsS "$URL" 2>/dev/null | sed -n 's/.*mediaPresentationDuration="\([^"]*\)".*/\1/p' | head -n 1 || true)"
if [ -n "$MPD_DURATION_ISO" ]; then
    MPD_DURATION_SECS="$(printf '%s\n' "$MPD_DURATION_ISO" | awk '
        {
            d=$0
            sub(/^PT/, "", d)
            h=0; m=0; s=0
            if (match(d, /[0-9]+H/)) { h=substr(d, RSTART, RLENGTH-1) + 0 }
            if (match(d, /[0-9]+M/)) { m=substr(d, RSTART, RLENGTH-1) + 0 }
            if (match(d, /[0-9]+(\.[0-9]+)?S/)) { s=substr(d, RSTART, RLENGTH-1) + 0 }
            print int((h * 3600) + (m * 60) + s)
        }
    ' || true)"

    if [ -n "$MPD_DURATION_SECS" ] && [ "$MPD_DURATION_SECS" -gt 0 ] && [ "$STREAM_DURATION" -gt "$MPD_DURATION_SECS" ]; then
        echo "*** requested streamDuration=${STREAM_DURATION}s exceeds MPD duration=${MPD_DURATION_SECS}s at $URL ***" >&2
        echo "*** fix: rerun with a shorter duration, e.g. ./scripts/run-godash.sh $PROTOCOL $TARGET_HOST $TARGET_PORT $MPD_DURATION_SECS ***" >&2
        echo "*** or regenerate longer shared DASH: ./scripts/use-shared-video.sh browser/reference/FourPeople_lossless.mkv 120 ***" >&2
        exit 3
    fi
fi

# Distinct output folder per run. The directory is created when
# -outputFolder/-config is set.
#
# outputFolder itself stays under ./files/ (relative to this checkout) -
# godash joins it under a hardcoded "./files/" base internally
# (main.go's fileDownloadLocation), so it can't be redirected without
# patching godash's Go source. qooExportPath (the measurement data) has no
# such restriction, so it is stored under data/ with the rest of runtime
# outputs.
OUTPUT_FOLDER="${PROTOCOL}-$(date +%Y%m%d-%H%M%S)"
RUN_CONFIG="./.godash-run-config.json"
DATA_DIR="$SCRIPT_DIR/../data/godash/$OUTPUT_FOLDER"
mkdir -p "$DATA_DIR"
QOO_EXPORT_PATH="$DATA_DIR/qoo_raw.jsonl"

# Small persistent counter (1, 2, 3, ...) identifying this run in Grafana.
# Shared across tcp/quic so a run number uniquely identifies one invocation.
RUN_COUNTER_FILE="$SCRIPT_DIR/../data/godash/.run_counter"
mkdir -p "$(dirname "$RUN_COUNTER_FILE")"
RUN_NUM=$(( $(cat "$RUN_COUNTER_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$RUN_NUM" > "$RUN_COUNTER_FILE"

sed \
    -e "s#__ADAPT__#$ADAPT#g" \
    -e "s#__STREAM_DURATION__#$STREAM_DURATION#g" \
    -e "s#__OUTPUT_FOLDER__#$OUTPUT_FOLDER#g" \
    -e "s#__QUIC__#$QUIC_FLAG#g" \
    -e "s#__USETESTBED__#$TESTBED_FLAG#g" \
    -e "s#__URL__#$URL#g" \
    -e "s#__QOO_EXPORT_PATH__#$QOO_EXPORT_PATH#g" \
    "$CONFIG_TEMPLATE" > "$RUN_CONFIG"

echo "=== Path: $PATH_KIND ==="
echo "Running godash: protocol=$PROTOCOL url=$URL adapt=$ADAPT streamDuration=${STREAM_DURATION}s run=#$RUN_NUM"
echo "Output folder: files/$OUTPUT_FOLDER (segments/debug log)  QoO export: $QOO_EXPORT_PATH"

# Tail the QoO export live and write each segment straight to InfluxDB for
# the duration of the run, so client-side (godash) and network-side
# (collector) QoO show up side by side in Grafana. See
# scripts/push-godash-metrics.sh + scripts/lib-push-metrics.sh.
"$SCRIPT_DIR/push-godash-metrics.sh" "$QOO_EXPORT_PATH" "$PROTOCOL" "$RUN_NUM" &
METRICS_TAILER_PID=$!
trap 'kill "$METRICS_TAILER_PID" 2>/dev/null || true' EXIT

./godash -config "$RUN_CONFIG"

# godash can finish writing all its segments within milliseconds for a
# short/local stream - give the tailer a moment to catch up and push the
# last lines before the EXIT trap kills it, otherwise a fast run can end
# before the tailer's file-detection loop (scripts/push-godash-metrics.sh)
# has even opened the file once.
sleep 2
