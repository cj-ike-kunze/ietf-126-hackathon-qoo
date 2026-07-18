#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-push-metrics.sh"

script_name="$(basename "$0")"
run_label="${1:-$(date +%Y%m%d-%H%M%S)}"
runner_service="${2:-libreqos-cli}"

# Usage:
#   ./scripts/libreqos-test.sh [run_label] [service]
# service defaults to libreqos-cli; use browser to run in full browser image.

host_run_dir="$SCRIPT_DIR/../data/libreqos/$run_label"
container_run_dir="/data/libreqos/$run_label"
samples_json="$host_run_dir/samples.json"
cli_output_txt="$host_run_dir/libreqos-cli-output.txt"
summary_json="$host_run_dir/summary.json"

mkdir -p "$host_run_dir"

cat <<EOF
[$script_name] Starting LibreQoS CLI run
  run_label: $run_label
  container service: $runner_service
  host output dir: $host_run_dir
EOF

# Run the CLI in the requested container service; samples are written directly
# into the host-mounted /data/libreqos path (no docker cp needed).
docker compose exec "$runner_service" sh -lc "mkdir -p '$container_run_dir' && /usr/local/bin/libreqos-test --no-tui --json --export-samples '$container_run_dir/samples.json'" \
  | tee "$cli_output_txt"

if [ ! -s "$samples_json" ]; then
  echo "[$script_name] ERROR: missing sample export at $samples_json" >&2
  exit 1
fi

jq '.summary' "$samples_json" > "$summary_json"

started_at_ms="$(jq -r '.summary.startedAt // 0' "$samples_json")"
if [ "$started_at_ms" = "0" ]; then
  started_at_ms="$(( $(date +%s) * 1000 ))"
fi

session_id="$(jq -r '.sessionId // "unknown"' "$samples_json")"
profile="$(gateway_profile)"

# Emit phase boundaries, RTT samples, and throughput samples to InfluxDB.
jq -r \
  --arg run "$run_label" \
  --arg profile "$profile" \
  --arg session "$session_id" \
  --argjson started "$started_at_ms" '
  [
    (.phases[]? | "qoo_libreqos_phase,source=libreqos,mode=active,bandwidth=true,run=\($run),profile=\($profile),session=\($session) value=\"\(.name)\" \((($started + (.startMs|tonumber)) * 1000000)|floor)"),
    (.latencySamples[]? | "qoo_libreqos_rtt_ms,source=libreqos,mode=active,bandwidth=true,run=\($run),profile=\($profile),session=\($session),phase=\(.phase),counted=\(.counted),sample_loss=\(.loss) value=\(.rttMs) \((($started + (.elapsedMs|tonumber)) * 1000000)|floor)"),
    (.throughputSamples[]? | "qoo_libreqos_throughput_mbps,source=libreqos,mode=active,bandwidth=true,run=\($run),profile=\($profile),session=\($session),phase=\(.phase),direction=\(.direction) value=\(.mbps) \((($started + (.elapsedMs|tonumber)) * 1000000)|floor)")
  ] | .[]
  ' "$samples_json" | influx_write

echo "[$script_name] Ingested LibreQoS samples into InfluxDB"
echo "[$script_name] Files:"
echo "  - $cli_output_txt"
echo "  - $samples_json"
echo "  - $summary_json"
