#!/usr/bin/env bash
set -euo pipefail

# Ensure numeric formatting uses dot decimal for Influx line protocol values.
export LC_NUMERIC=C
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib-push-metrics.sh"

ROUTED_TARGET_IP="172.29.0.20"

CLIENT="${1:-apple}"
TARGET_HOST="${2:-$ROUTED_TARGET_IP}"
TARGET_PORT="${3:-4043}"
MAX_RUNTIME_SECS="${4:-60}"
RUN_LABEL="${5:-$(date +%Y%m%d-%H%M%S)}"

DATA_DIR="$SCRIPT_DIR/../data/network-quality/$RUN_LABEL"
mkdir -p "$DATA_DIR"

JSON_OUT="$DATA_DIR/networkquality.json"
TEXT_OUT="$DATA_DIR/networkquality.txt"

if ! ping -c 1 "$TARGET_HOST" >/dev/null 2>&1; then
  echo "*** $TARGET_HOST unreachable - setup routed path first ***" >&2
  echo "***   Linux: ./scripts/setup-routing.sh $TARGET_HOST ***" >&2
  echo "***   macOS: ./scripts/setup-mac-wireguard.sh ***" >&2
  exit 1
fi

profile="$(gateway_profile)"
timestamp_ns="$(( $(date +%s) * 1000000000 ))"

url="https://$TARGET_HOST:$TARGET_PORT/.well-known/nq"
echo "=== network quality: client=$CLIENT url=$url run=$RUN_LABEL ==="

case "$CLIENT" in
  apple)
    if ! command -v networkQuality >/dev/null 2>&1; then
      echo "networkQuality binary not found on this host" >&2
      exit 1
    fi
    networkQuality -C "$url" -k -M "$MAX_RUNTIME_SECS" -c"$JSON_OUT" | tee "$TEXT_OUT"
    ;;
  go)
    GORESP_BIN="${GORESP_BIN:-$SCRIPT_DIR/../applications/goresponsiveness/networkQuality}"
    if [ ! -x "$GORESP_BIN" ]; then
      echo "goresponsiveness binary not found at $GORESP_BIN" >&2
      echo "Set GORESP_BIN to your built binary path." >&2
      exit 1
    fi
    "$GORESP_BIN" --url "$url" --insecure-skip-verify | tee "$TEXT_OUT"

    # Build a small JSON file so ingestion code is shared with apple mode.
    dl_mbps="$(sed -n 's/^Download:[[:space:]]*\([0-9.][0-9.]*\)[[:space:]]*Mbps.*/\1/p' "$TEXT_OUT" | head -1)"
    ul_mbps="$(sed -n 's/^Upload:[[:space:]]*\([0-9.][0-9.]*\)[[:space:]]*Mbps.*/\1/p' "$TEXT_OUT" | head -1)"
    rpm="$(sed -n 's/^RPM:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$TEXT_OUT" | head -1)"
    jq -n \
      --argjson dl "${dl_mbps:-0}" \
      --argjson ul "${ul_mbps:-0}" \
      --argjson rpm "${rpm:-0}" \
      '{dl_throughput: ($dl * 1000000), ul_throughput: ($ul * 1000000), responsiveness: ("Go (" + ($rpm|tostring) + " RPM)"), base_rtt: 0}' > "$JSON_OUT"
    ;;
  *)
    echo "client must be 'apple' or 'go'" >&2
    exit 1
    ;;
esac

if [ ! -s "$JSON_OUT" ]; then
  echo "missing network quality JSON output: $JSON_OUT" >&2
  exit 1
fi

dl_bps="$(jq -r '.dl_throughput // 0' "$JSON_OUT")"
ul_bps="$(jq -r '.ul_throughput // 0' "$JSON_OUT")"
idle_rtt_ms="$(jq -r '.base_rtt // 0' "$JSON_OUT")"
rpm="$(jq -r '
  if (.responsiveness | type) == "number" then
    (.responsiveness | floor)
  elif (.responsiveness | type) == "string" then
    (.responsiveness | capture("(?<rpm>[0-9]+)[[:space:]]*RPM").rpm? // "0")
  else
    "0"
  end
' "$JSON_OUT" 2>/dev/null || echo 0)"

idle_rpm="$(awk -v rtt="$idle_rtt_ms" 'BEGIN{if (rtt > 0) printf "%.3f", 60000/rtt; else print "0"}')"
loaded_rtt_ms="$(awk -v lrpm="$rpm" 'BEGIN{if (lrpm > 0) printf "%.3f", 60000/lrpm; else print "0"}')"

dl_mbps="$(awk -v bps="$dl_bps" 'BEGIN{printf "%.3f", bps/1000000}')"
ul_mbps="$(awk -v bps="$ul_bps" 'BEGIN{printf "%.3f", bps/1000000}')"

{
  printf 'qoo_network_quality_rpm,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,phase=idle value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$idle_rpm" "$timestamp_ns"
  printf 'qoo_network_quality_rpm,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,phase=loaded value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$rpm" "$timestamp_ns"
  printf 'qoo_network_quality_rtt_ms,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,phase=idle value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$idle_rtt_ms" "$timestamp_ns"
  printf 'qoo_network_quality_rtt_ms,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,phase=loaded value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$loaded_rtt_ms" "$timestamp_ns"
  printf 'qoo_network_quality_throughput_mbps,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,direction=download value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$dl_mbps" "$timestamp_ns"
  printf 'qoo_network_quality_throughput_mbps,source=network-quality,mode=active,bandwidth=true,client=%s,run=%s,profile=%s,direction=upload value=%s %s\n' "$CLIENT" "$RUN_LABEL" "$profile" "$ul_mbps" "$timestamp_ns"
} | influx_write

# Push all latency samples (idle + loaded arrays) so dashboard histograms can
# render from the selected dashboard time range only.
jq -r \
  --arg client "$CLIENT" \
  --arg run "$RUN_LABEL" \
  --arg profile "$profile" \
  --arg ts "$timestamp_ns" '
  def lp(state; series; idx; v):
    "qoo_network_quality_latency_sample_ms,source=network-quality,mode=active,bandwidth=true,client=\($client),run=\($run),profile=\($profile),state=\(state),series=\(series),sample_idx=\(idx) value=\(v) \($ts)";

  [
    (.il_h2_req_resp // [] | to_entries[] | lp("idle"; "il_h2_req_resp"; .key; .value)),
    (.il_tcp_handshake_443 // [] | to_entries[] | lp("idle"; "il_tcp_handshake_443"; .key; .value)),
    (.il_tls_handshake // [] | to_entries[] | lp("idle"; "il_tls_handshake"; .key; .value)),

    (.lud_foreign_h2_req_resp // [] | to_entries[] | lp("loaded"; "lud_foreign_h2_req_resp"; .key; .value)),
    (.lud_foreign_tcp_handshake_443 // [] | to_entries[] | lp("loaded"; "lud_foreign_tcp_handshake_443"; .key; .value)),
    (.lud_foreign_tls_handshake // [] | to_entries[] | lp("loaded"; "lud_foreign_tls_handshake"; .key; .value)),
    (.lud_self_h2_req_resp // [] | to_entries[] | lp("loaded"; "lud_self_h2_req_resp"; .key; .value))
  ]
  | .[]
' "$JSON_OUT" | influx_write

cat <<EOF
[run-network-quality.sh] Ingested results
  run_label: $RUN_LABEL
  profile: $profile
  client: $CLIENT
  url: $url
  files:
    - $TEXT_OUT
    - $JSON_OUT
EOF