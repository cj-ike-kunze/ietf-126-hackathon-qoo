package main

import (
	"log"
	"os"
	"time"
)

func main() {
	pcapPath := getenv("PCAP_PATH", "/pcap/capture.pcap")
	gatewayStatusURL := getenv("GATEWAY_STATUS_URL", "http://gateway:9000/status")
	gatewayBaseURL := getenv("GATEWAY_BASE_URL", "http://gateway:9000")
	category := getenv("APP_CATEGORY", "video-call")

	influxURL := getenv("INFLUX_URL", "http://influxdb:8086")
	influxOrg := getenv("INFLUX_ORG", "qoo")
	influxBucket := getenv("INFLUX_BUCKET", "qoo")
	influxToken := os.Getenv("INFLUX_TOKEN")
	writeInterval := getDurationEnv("COLLECTOR_WRITE_INTERVAL", 2*time.Second)

	store := NewMetricStore(category)

	go pollActiveProfile(store, gatewayStatusURL, 5*time.Second)
	go pollQoOState(store, gatewayBaseURL, 5*time.Second)
	go TailPcap(pcapPath, store)

	log.Printf("collector writing to %s (org=%s bucket=%s) every %s, reading pcap from %s (category=%s)",
		influxURL, influxOrg, influxBucket, writeInterval, pcapPath, category)
	WriteLoop(store, influxURL, influxOrg, influxBucket, influxToken, writeInterval)
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getDurationEnv(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
