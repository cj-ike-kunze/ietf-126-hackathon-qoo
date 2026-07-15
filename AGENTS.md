# AGENTS

## Purpose

This document is an operator handoff for contributors and coding agents.
It describes the current platform state, what is expected to work, and where
changes are safe.

## Current system scope

The platform is a Docker-based QoO demo stack for IETF 126.

It currently includes:

- gateway: traffic shaping + routing + optional WireGuard ingress + API
- target: HTTP/DASH/QUIC + iperf3 test endpoint
- collector: passive pcap metrics + QoO scoring + Influx writes
- influxdb: time-series storage (single metrics sink)
- dashboard: Grafana with provisioned dashboards
- control: web UI for profile/custom shaping control
- browser: optional noVNC browser container in emulated path
- scripts: setup/teardown, probes, godash runner, metric push helpers
- QoO profile source-of-truth is file-backed (`profiles/*.json`)
- gateway mirrors file profiles into InfluxDB on startup and reload
- qoo control UI supports save/load, reload-all, import, export

Not part of current architecture:

- Prometheus + Pushgateway pipeline
- optional client container fallback
- spindump integration

## Network model

- lan-net: 172.28.0.0/24
- wan-net: 172.29.0.0/24
- gateway LAN IP: 172.28.0.10
- target WAN IP: 172.29.0.20
- browser LAN IP: 172.28.0.30

Gateway is the choke point for impairment.

For macOS Docker Desktop, routed path uses WireGuard fallback through gateway.
For Linux, host route setup script is used.
Recent end-to-end validation has focused on the macOS fallback path.

## Runtime flow

1. Start stack: docker compose up -d --build
2. Enable routed path:
   - Linux: ./scripts/setup-routing.sh
   - macOS: ./scripts/full-up.sh (preferred) or setup-mac-wireguard + wg-quick up
3. Generate traffic:
   - ./scripts/run-active-probes.sh
   - ./scripts/run-godash.sh tcp|quic
   - optional browser tests on http://localhost:5800
4. Change impairment profiles via control UI (:8080) or gateway API (:9000)
5. Observe metrics in Grafana (:3000)

## Command cookbook

Stack lifecycle:

- docker compose up -d --build
- docker compose ps
- docker compose logs -f <service>
- docker compose down

Routing setup and teardown:

- Linux (default target 172.29.0.20):
   - ./scripts/setup-routing.sh
   - ./scripts/teardown-routing.sh
- macOS preferred fast path:
   - ./scripts/full-up.sh
   - ./scripts/full-down.sh
- macOS manual WireGuard path:
   - ./scripts/setup-mac-wireguard.sh
   - sudo wg-quick up .wg-mac/qoo-gateway.conf
   - sudo wg-quick down .wg-mac/qoo-gateway.conf

Traffic generation:

- ./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3
- ./scripts/run-godash.sh tcp
- ./scripts/run-godash.sh quic
- ./scripts/ping-in-browser.sh 172.29.0.20

Profile control:

- curl http://localhost:9000/profiles
- curl http://localhost:9000/status
- curl -X POST http://localhost:9000/profile/latency-200ms
- Custom shaping (full):
   curl -X POST http://localhost:9000/custom -H "Content-Type: application/json" -d '{"delay_ms":100,"jitter_ms":10,"distribution":"normal","downstream_loss_pct":2,"upstream_loss_pct":0,"loss_model":"uniform","downstream_rate_mbit":5,"upstream_rate_mbit":0}'
- Field notes: all fields are optional; distribution is normal|uniform; loss_model is uniform|burst.

Quick smoke check (post-change):

- docker compose ps
- curl http://localhost:9000/status
- ./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3

## Data flow

Traffic path:

host traffic -> gateway shaping -> target -> gateway -> host

Metrics path:

- gateway writes capture to data/pcap/capture.pcap
- collector tails capture + polls gateway status
- collector computes metrics + QoO score
- collector writes qoo_* to InfluxDB
- scripts also write active/godash metrics directly to InfluxDB
- Grafana reads InfluxDB

Persisted outputs:

- data/pcap/
- data/influxdb/
- data/grafana/
- data/godash/
- data/active-probes/
- data/wg-keys/

## Profiles and shaping

Named profiles live in gateway/profiles.

QoO scoring profiles (threshold configs) live in `profiles/*.json` and are
mounted into gateway at `/qoo-profiles`.

Source-of-truth model:

- files are authoritative for QoO profile definitions
- gateway syncs files -> Influx measurement `qoo_config_profile`
- save/import writes file first, then mirrors to Influx

Current profile set:

- baseline
- latency-50ms
- latency-200ms
- jitter-20ms
- loss-1pct
- loss-5pct
- burst-loss
- combined-bad
- bandwidth-1mbit
- bandwidth-5mbit

Gateway API endpoints used by UI/scripts:

- GET /profiles
- GET /status
- POST /profile/<name>
- POST /custom

Gateway QoO profile API endpoints:

- GET /qoo-config
- POST /qoo-config
- GET /qoo-active-profile
- GET /qoo-profiles
- GET /qoo-profiles/<name>
- POST /qoo-profiles/<name>
- POST /qoo-profiles/load/<name>
- POST /qoo-profiles/reload
- POST /qoo-profiles/import
- GET /qoo-profiles/export/<name>

Overwrite semantics:

- saving/importing an existing QoO profile returns HTTP 409 unless overwrite is
   explicitly requested

## QoO and metrics

Collector computes QoO score from passive metrics using active QoO config
polled from gateway state.
QoO score follows min(latency, loss, throughput) semantics.

Common measurements written:

- qoo_rtt_ms
- qoo_loss_ratio
- qoo_jitter_ms
- qoo_throughput_mbps
- qoo_score

Scripted active and godash metrics are also written to InfluxDB with profile
context.

## Dashboard layout map

Current Grafana dashboards:

- `qoo-overview`: all sources summary with QoO profile-aware threshold card
- `qoo-active-overview`: active probe focus, same threshold/profile controls
- `qoo-passive-overview`: passive metrics focus, same threshold/profile controls
- `qoo-comparison`: multi-profile comparison with repeated timeline blocks

## macOS workflow notes

Preferred path for reproducible setup:

- ./scripts/full-up.sh
- run tests
- ./scripts/full-down.sh

full-up refreshes WireGuard pairing/config and brings tunnel up.

## Edit guardrails

When changing networking/shaping logic:

- keep browser local access (localhost:5800) working
- keep internet-bound browser path going through gateway
- preserve macOS WireGuard routed path
- avoid reintroducing bypass defaults that hide impairment

When changing scripts/docs:

- keep setup-routing/teardown-routing defaults in sync with docs
- keep quickstart commands copy-pasteable

## Validation checklist

After meaningful changes, run at least:

- docker compose ps
- ./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3
- curl http://localhost:9000/status
- one profile switch + probe rerun
- (macOS) verify routed reachability to 172.29.0.20 via full-up path

Optional:

- ./scripts/run-godash.sh tcp
- browser noVNC access on :5800 and one browser ping test

After dashboard edits, also verify:

- `docker compose logs --tail=200 dashboard | rg -i 'Flux query failed|compilation failed'`
