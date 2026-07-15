package main

import (
	"encoding/json"
	"net/http"
	"time"
)

// pollActiveProfile periodically fetches the gateway's /status endpoint and
// updates store with whatever impairment profile is currently active.
func pollActiveProfile(store *MetricStore, url string, interval time.Duration) {
	client := &http.Client{Timeout: 2 * time.Second}
	for {
		if resp, err := client.Get(url); err == nil {
			var payload struct {
				ActiveProfile string `json:"active_profile"`
			}
			if json.NewDecoder(resp.Body).Decode(&payload) == nil && payload.ActiveProfile != "" {
				store.SetActiveProfile(payload.ActiveProfile)
			}
			resp.Body.Close()
		}
		time.Sleep(interval)
	}
}

// pollQoOState fetches the active QoO profile and scoring thresholds from
// gateway and keeps collector scoring in sync with control/qoo.html updates.
func pollQoOState(store *MetricStore, baseURL string, interval time.Duration) {
	client := &http.Client{Timeout: 2 * time.Second}

	for {
		if resp, err := client.Get(baseURL + "/qoo-active-profile"); err == nil {
			var payload struct {
				ActiveProfile string `json:"activeProfile"`
			}
			if json.NewDecoder(resp.Body).Decode(&payload) == nil && payload.ActiveProfile != "" {
				store.SetQoOProfile(payload.ActiveProfile)
			}
			resp.Body.Close()
		}

		if resp, err := client.Get(baseURL + "/qoo-config"); err == nil {
			var payload struct {
				MinThroughputMbps float64  `json:"qooMinThroughputMbps"`
				LossLower         float64  `json:"qooLossLower"`
				LossUpper         float64  `json:"qooLossUpper"`
				LatencyP50Lower   float64  `json:"qooLatencyP50Lower"`
				LatencyP50Upper   float64  `json:"qooLatencyP50Upper"`
				LatencyP75Lower   float64  `json:"qooLatencyP75Lower"`
				LatencyP75Upper   float64  `json:"qooLatencyP75Upper"`
				LatencyP90Lower   float64  `json:"qooLatencyP90Lower"`
				LatencyP90Upper   float64  `json:"qooLatencyP90Upper"`
				LatencyP95Lower   float64  `json:"qooLatencyP95Lower"`
				LatencyP95Upper   float64  `json:"qooLatencyP95Upper"`
				LatencyP99Lower   float64  `json:"qooLatencyP99Lower"`
				LatencyP99Upper   float64  `json:"qooLatencyP99Upper"`
				Percentiles       []string `json:"qooLatencyPercentiles"`
			}
			if json.NewDecoder(resp.Body).Decode(&payload) == nil {
				cfg := defaultQoOConfig()
				cfg.MinThroughputMbps = payload.MinThroughputMbps
				cfg.LossLower = payload.LossLower
				cfg.LossUpper = payload.LossUpper
				cfg.LatencyP50Lower = payload.LatencyP50Lower
				cfg.LatencyP50Upper = payload.LatencyP50Upper
				cfg.LatencyP75Lower = payload.LatencyP75Lower
				cfg.LatencyP75Upper = payload.LatencyP75Upper
				cfg.LatencyP90Lower = payload.LatencyP90Lower
				cfg.LatencyP90Upper = payload.LatencyP90Upper
				cfg.LatencyP95Lower = payload.LatencyP95Lower
				cfg.LatencyP95Upper = payload.LatencyP95Upper
				cfg.LatencyP99Lower = payload.LatencyP99Lower
				cfg.LatencyP99Upper = payload.LatencyP99Upper
				if len(payload.Percentiles) > 0 {
					cfg.LatencyPercentilesKeys = payload.Percentiles
				}
				store.SetQoOConfig(cfg)
			}
			resp.Body.Close()
		}

		time.Sleep(interval)
	}
}
