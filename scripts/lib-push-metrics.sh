# Shared helpers for writing client-side/active-probe measurements into the
# same InfluxDB/Grafana stack the gateway/collector pipeline already feeds.
# Sourced by run-active-probes.sh and push-godash-metrics.sh. A future app's
# script should do the same: `. "$SCRIPT_DIR/lib-push-metrics.sh"`, then call
# gateway_profile + influx_write - no new plumbing needed.
#
# Metric names intentionally reuse the collector's own names (qoo_rtt_ms,
# qoo_loss_ratio, qoo_throughput_mbps - see collector/influx_writer.go) with
# a source="..." tag added, so client-side and network-side QoO land in the
# same Grafana panels for direct overlay instead of separate ones.
#
# Every data source (collector included) also carries two grouping tags so
# Grafana can split "active vs passive" and "measures bandwidth or not"
# without per-app dashboards:
#   mode=active|passive     - active: this thing generates its own probe/
#                              app traffic on purpose (active-probe, godash).
#                              passive: it only observes real traffic it
#                              didn't generate (collector).
#   bandwidth=true|false    - true: pushes an explicit throughput number
#                              (collector, active-probe/iperf3). false: it
#                              doesn't measure raw link bandwidth, only
#                              RTT/loss/etc (godash).
# A new app's script should pick both before writing its influx_write calls.
#
# Metrics are written directly to InfluxDB's HTTP write API with explicit
# per-point timestamps.

INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
INFLUX_ORG="${INFLUX_ORG:-qoo}"
INFLUX_BUCKET="${INFLUX_BUCKET:-qoo}"
INFLUX_TOKEN="${INFLUX_TOKEN:-qoo-dev-token}"
GATEWAY_STATUS_URL="${GATEWAY_STATUS_URL:-http://localhost:9000/status}"

# Current gateway impairment profile (e.g. "latency-200ms"), or "unknown" if
# gateway isn't reachable - lets client-side metrics carry the same
# profile="..." tag the collector's network-side metrics use.
gateway_profile() {
    profile="$(curl -s --max-time 2 "$GATEWAY_STATUS_URL" 2>/dev/null \
        | grep -o '"active_profile"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/')"
    echo "${profile:-unknown}"
}

# influx_write   (InfluxDB line-protocol points on stdin, one per line)
#
# Writes straight to InfluxDB's HTTP write API. Each line's trailing
# timestamp (or server-side now if omitted) is stored as its own point.
#
# precision=ns preserves ordering and separation for bursty writes (such as
# per-segment godash points), avoiding second-level timestamp collisions.
influx_write() {
    curl -s --max-time 5 -X POST \
        "$INFLUX_URL/api/v2/write?org=$INFLUX_ORG&bucket=$INFLUX_BUCKET&precision=ns" \
        -H "Authorization: Token $INFLUX_TOKEN" \
        -H "Content-Type: text/plain; charset=utf-8" \
        --data-binary @-
}
