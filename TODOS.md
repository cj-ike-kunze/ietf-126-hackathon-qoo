# TODOs

- [ ] Validate goresponsiveness client path end-to-end with target networkqualityd.
  - Build client binary from https://github.com/network-quality/goresponsiveness.
  - Run via scripts/run-network-quality.sh go 172.29.0.20 4043 60 (set GORESP_BIN if needed).
  - Confirm qoo_network_quality_* points for client=go in Influx and Grafana overview panel.
