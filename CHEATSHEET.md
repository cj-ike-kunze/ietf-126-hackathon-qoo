# QoO Platform Cheatsheet

This file is a hackathon quick card: fastest setup, demo loop, and supported
measurement/test commands.

## macOS fastest path (recommended for hackathon)

```sh
./scripts/full-up.sh
./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3
./scripts/full-down.sh
```

`full-up.sh` starts the stack, refreshes WireGuard config, and brings the
tunnel up. `full-down.sh` tears the stack and tunnel down.

## Hackathon happy path (quick demo loop)

```sh
docker compose up -d --build
docker compose ps

# Linux routed path
./scripts/setup-routing.sh

# macOS routed path (use instead of setup-routing.sh)
./scripts/setup-mac-wireguard.sh
sudo wg-quick up .wg-mac/qoo-gateway.conf

# Baseline run
./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3

# Impairment run
curl -X POST http://localhost:9000/profile/latency-200ms
./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3

# App-level run
./scripts/run-godash.sh tcp
```

## Stack lifecycle

```sh
docker compose up -d --build
docker compose ps
docker compose logs -f <service>
docker compose down
```

Common services: `gateway`, `target`, `collector`, `influxdb`, `dashboard`,
`control`, `browser`.

## Enable routed impairment path

Linux host routing:

```sh
./scripts/setup-routing.sh [target-ip-or-cidr] [gateway-ip]
./scripts/teardown-routing.sh [target-ip-or-cidr] [gateway-ip]
```

macOS fallback (WireGuard):

```sh
./scripts/setup-mac-wireguard.sh
sudo wg-quick up .wg-mac/qoo-gateway.conf
sudo wg-quick down .wg-mac/qoo-gateway.conf
```

Fast validation:

```sh
./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3
```

## Switch impairment profile

```sh
curl http://localhost:9000/profiles
curl http://localhost:9000/status
curl -X POST http://localhost:9000/profile/<name>
```

Or click a button at http://localhost:8080.

Custom shaping:

```sh
curl -X POST http://localhost:9000/custom -H "Content-Type: application/json" -d '{
  "delay_ms": 100,
  "jitter_ms": 10,
  "distribution": "normal",
  "downstream_loss_pct": 2,
  "upstream_loss_pct": 0,
  "loss_model": "uniform",
  "downstream_rate_mbit": 5,
  "upstream_rate_mbit": 0
}'
```

### Profiles

`baseline`, `latency-50ms`, `latency-200ms`, `jitter-20ms`, `loss-1pct`,
`loss-5pct`, `burst-loss`, `combined-bad`, `bandwidth-1mbit`,
`bandwidth-5mbit`.

## QoO threshold profiles (file-backed)

QoO threshold configs are sourced from `profiles/*.json` (file source-of-truth)
and mirrored to InfluxDB by gateway.

List/load/save/reload:

```sh
curl -s http://localhost:9000/qoo-profiles | jq .
curl -s http://localhost:9000/qoo-profiles/video-call | jq .
curl -s -X POST http://localhost:9000/qoo-profiles/load/video-call | jq .
curl -s -X POST http://localhost:9000/qoo-profiles/reload | jq .
```

Save overwrite behavior:

```sh
# first save may succeed; existing name returns 409 unless overwrite=true
curl -s -X POST http://localhost:9000/qoo-profiles/video-call \
  -H 'Content-Type: application/json' \
  -d '{"qooLossUpper":0.02}'

curl -s -X POST 'http://localhost:9000/qoo-profiles/video-call?overwrite=true' \
  -H 'Content-Type: application/json' \
  -d '{"qooLossUpper":0.02}'
```

Import/export:

```sh
# import from local JSON payload file
curl -s -X POST http://localhost:9000/qoo-profiles/import \
  -H 'Content-Type: application/json' \
  -d @profiles/video-call.json

curl -OJ http://localhost:9000/qoo-profiles/export/video-call
```

Note: only `.json` files in `profiles/` are treated as QoO profiles.

## Supported measurements and tests

Active probes (network quality):

```sh
./scripts/run-active-probes.sh [ping-target] [iperf-server] [ping-count] [iperf-duration]
```

goDASH client tests:

```sh
./scripts/run-godash.sh [tcp|quic] [target-host] [target-port] [streamDuration] [adapt-algorithm]
```

Browser path tests (noVNC):

```sh
docker compose up -d --build browser
open http://localhost:5800
./scripts/ping-in-browser.sh <target>
```

## Data and outputs

| Path | Data |
|---|---|
| `data/pcap/capture.pcap` | Gateway packet capture |
| `data/influxdb/` | InfluxDB persistent data |
| `data/grafana/` | Grafana state |
| `data/wg-keys/` | Gateway WireGuard keys |
| `data/godash/` | Exported goDASH run outputs |

## URLs

| Component | URL |
|---|---|
| Control panel | http://localhost:8080 |
| Grafana | http://localhost:3000 |
| InfluxDB | http://localhost:8086 |
| Gateway API | http://localhost:9000 |
| Browser (noVNC) | http://localhost:5800 |

## Dashboard layout quick map

- Overview (`qoo-overview`): cross-source main view + profile threshold card
- Active (`qoo-active-overview`): active probes + same profile controls
- Passive (`qoo-passive-overview`): passive metrics + same profile controls
- Comparison (`qoo-comparison`): repeated timelines per selected profile

Dashboard sanity check:

```sh
docker compose logs --tail=200 dashboard | rg -i 'Flux query failed|compilation failed'
```
