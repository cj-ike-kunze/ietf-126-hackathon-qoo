package main

import (
	"math"
	"sort"
)

// PercentileRequirement is one row of a latency requirement profile per
// draft-ietf-ippm-qoo: ROPMs is the "required operating point" (good) and
// CPUPMs is the "connectivity performance unacceptable point" (bad) latency,
// both measured at Percentile.
type PercentileRequirement struct {
	Percentile float64
	ROPMs      float64
	CPUPMs     float64
}

// CategoryProfile is an illustrative requirement profile for an application
// category, shaped like the example in draft-ietf-ippm-qoo section 3.2. The
// draft explicitly does not standardize per-application values, so these are
// reasonable placeholders, not normative numbers.
type CategoryProfile struct {
	LatencyPercentiles []PercentileRequirement
	LossROP            float64 // ratio, e.g. 0.001 = 0.1%
	LossCPUP           float64
	MinThroughputMbps  float64
}

// QoOConfig mirrors gateway /qoo-config and defines runtime thresholds for
// latency/loss/throughput scoring.
type QoOConfig struct {
	MinThroughputMbps      float64
	LossLower              float64
	LossUpper              float64
	LatencyP50Lower        float64
	LatencyP50Upper        float64
	LatencyP75Lower        float64
	LatencyP75Upper        float64
	LatencyP90Lower        float64
	LatencyP90Upper        float64
	LatencyP95Lower        float64
	LatencyP95Upper        float64
	LatencyP99Lower        float64
	LatencyP99Upper        float64
	LatencyPercentilesKeys []string
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// componentScore implements the draft's shared linear-interpolation formula:
// m = 1 - ((measured - ROP) / (CPUP - ROP)), clamped to [0,1].
func componentScore(measured, rop, cpup float64) float64 {
	if cpup == rop {
		if measured <= rop {
			return 1
		}
		return 0
	}
	return clamp01(1 - (measured-rop)/(cpup-rop))
}

func percentile(samples []float64, p float64) float64 {
	n := len(samples)
	if n == 0 {
		return 0
	}
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	if n == 1 {
		return sorted[0]
	}
	rank := p * float64(n-1)
	lower := int(math.Floor(rank))
	upper := int(math.Ceil(rank))
	if lower == upper {
		return sorted[lower]
	}
	frac := rank - float64(lower)
	return sorted[lower] + frac*(sorted[upper]-sorted[lower])
}

// latencyScore takes the minimum component score across all measured
// percentiles, per the draft's QoO_latency definition.
func latencyScore(samples []float64, percentiles []PercentileRequirement) float64 {
	if len(samples) == 0 {
		return 100
	}
	minMetric := 1.0
	for _, pr := range percentiles {
		measured := percentile(samples, pr.Percentile)
		if m := componentScore(measured, pr.ROPMs, pr.CPUPMs); m < minMetric {
			minMetric = m
		}
	}
	return minMetric * 100
}

func lossScore(lossRatio, rop, cpup float64) float64 {
	return componentScore(lossRatio, rop, cpup) * 100
}

func throughputScore(mbps, minRequired float64) float64 {
	if mbps >= minRequired {
		return 100
	}
	return 0
}

func defaultQoOConfig() QoOConfig {
	return QoOConfig{
		MinThroughputMbps:      2,
		LossLower:              0.001,
		LossUpper:              0.02,
		LatencyP50Lower:        50,
		LatencyP50Upper:        150,
		LatencyP75Lower:        75,
		LatencyP75Upper:        175,
		LatencyP90Lower:        90,
		LatencyP90Upper:        190,
		LatencyP95Lower:        100,
		LatencyP95Upper:        200,
		LatencyP99Lower:        150,
		LatencyP99Upper:        300,
		LatencyPercentilesKeys: []string{"p50", "p75", "p90", "p95", "p99"},
	}
}

func requirementsFromConfig(cfg QoOConfig) []PercentileRequirement {
	reqs := make([]PercentileRequirement, 0, len(cfg.LatencyPercentilesKeys))
	for _, k := range cfg.LatencyPercentilesKeys {
		switch k {
		case "p50":
			reqs = append(reqs, PercentileRequirement{Percentile: 0.50, ROPMs: cfg.LatencyP50Lower, CPUPMs: cfg.LatencyP50Upper})
		case "p75":
			reqs = append(reqs, PercentileRequirement{Percentile: 0.75, ROPMs: cfg.LatencyP75Lower, CPUPMs: cfg.LatencyP75Upper})
		case "p90":
			reqs = append(reqs, PercentileRequirement{Percentile: 0.90, ROPMs: cfg.LatencyP90Lower, CPUPMs: cfg.LatencyP90Upper})
		case "p95":
			reqs = append(reqs, PercentileRequirement{Percentile: 0.95, ROPMs: cfg.LatencyP95Lower, CPUPMs: cfg.LatencyP95Upper})
		case "p99":
			reqs = append(reqs, PercentileRequirement{Percentile: 0.99, ROPMs: cfg.LatencyP99Lower, CPUPMs: cfg.LatencyP99Upper})
		}
	}
	if len(reqs) == 0 {
		fallback := defaultQoOConfig()
		return requirementsFromConfig(fallback)
	}
	return reqs
}

// QoOScoreWithConfig computes QoO using the gateway-provided QoO config.
func QoOScoreWithConfig(latencySamplesMs []float64, lossRatio, throughputMbps float64, cfg QoOConfig) float64 {
	lat := latencyScore(latencySamplesMs, requirementsFromConfig(cfg))
	loss := lossScore(lossRatio, cfg.LossLower, cfg.LossUpper)
	tput := throughputScore(throughputMbps, cfg.MinThroughputMbps)
	return math.Min(lat, math.Min(loss, tput))
}

