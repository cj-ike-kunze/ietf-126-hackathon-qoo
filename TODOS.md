# TODOs

- [ ] Validate goresponsiveness client path end-to-end with target networkqualityd.
  - Build client binary from https://github.com/network-quality/goresponsiveness.
  - Run via scripts/run-network-quality.sh go 172.29.0.20 4043 60 (set GORESP_BIN if needed).
  - Confirm qoo_network_quality_* points for client=go in Influx and Grafana overview panel.

- [ ] TCP `transport_sent_packets_total` parity in goDASH is deferred for a later pass.
  - Add a TCP sent-packet counter source for Linux builds (extend TCP_INFO
  capture path if a reliable sent counter is available on target kernels).
  - Add a macOS-compatible TCP sent-packet source (likely BPF/pcap-based
    counting) because current non-Linux path has no TCP_INFO support.
  - Export `tcp_sent_packets_total` and include it in
    `transport_sent_packets_total` in `applications/qoo-godash/qoe/qoo_export.go`
    when reliable values are available.
  - Keep `transport_sent_packets_total` omitted when unsupported, and avoid
    synthetic fallback values that could skew `qoo_loss_ratio`.
  - Re-validate end-to-end by rerunning `./scripts/run-godash.sh tcp` and
    confirming `qoo_loss_ratio` points appear for `source=active-godash`.
