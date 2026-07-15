package main

import (
	"bytes"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// WriteLoop periodically writes collector qoo_* values to InfluxDB's
// line-protocol write API on a fixed interval.
func WriteLoop(store *MetricStore, influxURL, org, bucket, token string, interval time.Duration) {
	client := &http.Client{Timeout: 5 * time.Second}
	// precision=ns (not "s"): keeps points from different write intervals
	// from ever landing on an identical rounded timestamp - see
	// scripts/lib-push-metrics.sh's influx_write for why this matters more
	// broadly (godash's per-segment bursts collapsing onto one x-position).
	writeURL := fmt.Sprintf("%s/api/v2/write?org=%s&bucket=%s&precision=ns", influxURL, org, bucket)

	for {
		time.Sleep(interval)
		body := buildLineProtocol(store)
		if body == "" {
			continue
		}
		req, err := http.NewRequest(http.MethodPost, writeURL, strings.NewReader(body))
		if err != nil {
			log.Printf("influx write: build request: %v", err)
			continue
		}
		req.Header.Set("Authorization", "Token "+token)
		req.Header.Set("Content-Type", "text/plain; charset=utf-8")
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("influx write: %v", err)
			continue
		}
		if resp.StatusCode >= 300 {
			var b bytes.Buffer
			b.ReadFrom(resp.Body)
			log.Printf("influx write: HTTP %d: %s", resp.StatusCode, b.String())
		}
		resp.Body.Close()
	}
}

// buildLineProtocol emits the collector metric set (qoo_rtt_ms,
// qoo_loss_ratio, qoo_jitter_ms, qoo_throughput_mbps, qoo_score,
// qoo_active_profile), one InfluxDB point per series with a
// single field named "value" - every qoo_* writer in this project (see
// scripts/lib-push-metrics.sh, scripts/push-godash-metrics.sh) follows the
// same "value" field convention so Grafana panels query them uniformly.
func buildLineProtocol(store *MetricStore) string {
	var b strings.Builder
	flows := store.Snapshot()
	rawProfile := store.ActiveProfile()
	if rawProfile == "" {
		// Line protocol rejects an empty tag value outright ("missing tag
		// value") - gateway_status.go leaves this "" until the first
		// successful /status poll, so there's a real window (container
		// startup) where this must not be a bare empty string.
		rawProfile = "unknown"
	}
	profile := escapeTag(rawProfile)
	rawQoOProfile := store.QoOProfile()
	if rawQoOProfile == "" {
		rawQoOProfile = "manual"
	}
	qooProfile := escapeTag(rawQoOProfile)
	qooConfig := store.QoOConfig()

	// mode/bandwidth are constant for every collector series: it observes
	// real traffic passively (never generates its own probe traffic) and
	// always derives an explicit throughput number from the capture. These
	// tags let Grafana group this apart from active-probe and godash
	// without a separate dashboard.
	const tags = "mode=passive,bandwidth=true"

	for _, fm := range flows {
		s := fm.Snapshot()
		flow := escapeTag(s.Label)

		// app names this flow after the active measurement it almost
		// certainly belongs to, purely from protocol + well-known port
		// (target/entrypoint.sh: HTTP :8000, QUIC/H3 :4433/udp, iperf3
		// :5201; ping has no port at all, only ICMP) - collector has no
		// other way to know which host-run script generated a given
		// packet, but these ports are fixed for this whole project, so a
		// static lookup is enough to give passive flows the same
		// recognizable names the active-probe/godash dashboards already
		// use, instead of a bare, meaningless "ip:port->ip:port" label.
		// Omitted (no "app" tag at all) for anything else, e.g. plain curl
		// traffic against target's HTTP port that isn't one of the above.
		appTag := ""
		if a := appName(s); a != "" {
			appTag = ",app=" + escapeTag(a)
		}

		// packets rides alongside value as a second field (not a tag - it's
		// a per-flow running count, unbounded) on the two metrics the
		// combined QoO score's GUI thresholds (dashboard/dashboards/
		// overview.json's minPacketsThroughput/minPacketsLoss variables)
		// filter on: a flow with only a handful of packets total gives a
		// statistically noisy loss ratio or throughput reading (e.g. 1
		// retransmit out of 6 packets is 16.7% "loss") that would otherwise
		// silently dominate a pooled/min'd combined score.
		packets := strconv.FormatUint(s.Packets, 10)

		fmt.Fprintf(&b, "qoo_rtt_ms,flow=%s,profile=%s,%s%s value=%s\n", flow, profile, tags, appTag, formatFloat(s.RTTMs))
		fmt.Fprintf(&b, "qoo_loss_ratio,flow=%s,profile=%s,%s%s value=%s,packets=%s\n", flow, profile, tags, appTag, formatFloat(s.LossRatio), packets)
		fmt.Fprintf(&b, "qoo_jitter_ms,flow=%s,profile=%s,%s%s value=%s\n", flow, profile, tags, appTag, formatFloat(s.JitterMs))
		fmt.Fprintf(&b, "qoo_throughput_mbps,flow=%s,profile=%s,%s%s value=%s,packets=%s\n", flow, profile, tags, appTag, formatFloat(s.ThroughputMbps), packets)

		// profile is included here too (not just on qoo_active_profile) so
		// comparison dashboards can split/compare qoo_score by profile directly.
		score := QoOScoreWithConfig(s.LatencySamples, s.LossRatio, s.ThroughputMbps, qooConfig)
		category := escapeTag(s.Category)
		fmt.Fprintf(&b, "qoo_score,flow=%s,category=%s,profile=%s,qoo_profile=%s,%s%s value=%s\n", flow, category, profile, qooProfile, tags, appTag, formatFloat(score))
	}

	fmt.Fprintf(&b, "qoo_active_profile,profile=%s value=1\n", profile)

	return b.String()
}

// appName maps a passive flow to the active measurement that almost
// certainly produced it, using only protocol + well-known port - see the
// call site in buildLineProtocol for why that's all collector has to go on.
func appName(s FlowSnapshot) string {
	switch {
	case s.Protocol == "icmp":
		return "ping"
	case s.ClientPort == 5201 || s.ServerPort == 5201:
		return "iperf3"
	case s.ClientPort == 8000 || s.ServerPort == 8000:
		return "godash-tcp"
	case s.Protocol == "udp" && (s.ClientPort == 4433 || s.ServerPort == 4433):
		return "godash-quic"
	default:
		return ""
	}
}

func formatFloat(v float64) string {
	return strconv.FormatFloat(v, 'f', 4, 64)
}

// escapeTag escapes the characters InfluxDB line protocol treats specially
// in tag keys/values (comma, space, equals sign). Flow labels look like
// "172.28.0.10:53412->172.29.0.20:8000", which has none of these, but this
// keeps it correct if that ever changes.
func escapeTag(v string) string {
	r := strings.NewReplacer(",", `\,`, " ", `\ `, "=", `\=`)
	return r.Replace(v)
}
