# QoO Hackathon Platform

> Demo-only setup: this repository is intended for hackathon/demo use, not
> production. It uses convenience defaults (for example, static local tokens,
> permissive local API behavior, and developer-grade service configuration)
> that must be replaced/hardened before any real deployment.

Docker-based platform for QoO demos at IETF 126.

It lets you route application traffic through an emulated network gateway,
apply impairment profiles with tc/netem, and observe QoO-related metrics in
Grafana.

## What you get

- Gateway-driven impairment control (latency, jitter, loss, bandwidth)
- Live metrics pipeline (collector -> InfluxDB -> Grafana)
- Control panel and Gateway API for profile switching
- Scripted active probes and goDASH test workflows
- Optional browser container in the emulated path (noVNC on port 5800)
- Separate lightweight LibreQoS CLI container (`libreqos-cli`, amd64)

## Architecture (high level)

Traffic path:

1. Host-side test client traffic enters `gateway`.
2. `gateway` applies the active impairment profile.
3. Traffic exits to `target`.

Observability path:

1. `collector` reads packet capture and gateway status.
2. `collector` computes metrics and writes to InfluxDB.
3. Grafana dashboards visualize RTT/loss/throughput/QoO.

Control path:

1. `control` UI calls `gateway` API endpoints.
2. `gateway` switches profile scripts.

## Quickstart

### 1. Start stack

```sh
git clone <this repo>
cd ietf-hackathon-ietf-126
docker compose up -d --build
docker compose ps
```

### 2. Enable routed test path

Linux:

```sh
./scripts/setup-routing.sh
```

Linux routing note: by default this adds a host route for `172.29.0.20` via
gateway LAN IP `172.28.0.10`, forcing that destination through gateway
impairment.
Linux status note: expected to work, but current validation focus has been the
macOS WireGuard fallback path.

macOS (Docker Desktop):

```sh
./scripts/setup-mac-wireguard.sh
sudo wg-quick up .wg-mac/qoo-gateway.conf
```

macOS quick path (recommended):

```sh
./scripts/full-up.sh
```

### 3. Validate path and metrics

```sh
./scripts/run-active-probes.sh 172.29.0.20 172.29.0.20 3 3
```

### 4. Open UI

- Control panel: http://localhost:8080
- Grafana: http://localhost:3000
- InfluxDB: http://localhost:8086
- Gateway API: http://localhost:9000
- Browser (noVNC): http://localhost:5800

### 5. Run app-level tests

```sh
./scripts/run-godash.sh tcp
./scripts/run-godash.sh quic

# LibreQoS CLI (lightweight amd64 container)
./scripts/libreqos-test.sh

```

When done:

```sh
./scripts/teardown-routing.sh
sudo wg-quick down .wg-mac/qoo-gateway.conf  # macOS only
docker compose down
```

macOS quick teardown:

```sh
./scripts/full-down.sh
```

## Supported measurements and tests

| Type | Tool | Output |
|---|---|---|
| Active probes | `scripts/run-active-probes.sh` | Ping RTT/loss and iperf throughput metrics |
| DASH client test | `scripts/run-godash.sh` (tcp/quic) | Segment-level QoO inputs + run exports |
| Browser path test | noVNC browser on `:5800` + profile switch | Interactive user-perceived impact |
| Packet capture | `data/pcap/capture.pcap` | Raw traffic for inspection/replay |
| Time-series telemetry | Collector -> InfluxDB -> Grafana | Dashboard-ready QoO views |

## Profiles and control

- List profiles: `GET /profiles`
- Read active profile: `GET /status`
- Switch profile: `POST /profile/<name>`
- Custom shaping: `POST /custom`

QoO threshold profile API:

- `GET /qoo-config`
- `POST /qoo-config`
- `GET /qoo-active-profile`
- `GET /qoo-profiles`
- `GET /qoo-profiles/<name>`
- `POST /qoo-profiles/<name>`
- `POST /qoo-profiles/load/<name>`
- `POST /qoo-profiles/reload`
- `POST /qoo-profiles/import`
- `GET /qoo-profiles/export/<name>`

Use the control panel for the same actions.

## QoO threshold profile persistence

QoO threshold profiles are file-backed.

- Source-of-truth: `profiles/*.json`
- Gateway mount: `/qoo-profiles`
- Mirror sink: Influx measurement `qoo_config_profile`

Behavior:

- Gateway syncs profile files to Influx on startup and on reload.
- Save/import writes file first, then mirrors to Influx.
- Existing profile name returns HTTP 409 unless overwrite is explicitly requested.
- Only `.json` files are considered QoO profiles.

Quick commands:

```sh
curl -s http://localhost:9000/qoo-profiles | jq .
curl -s -X POST http://localhost:9000/qoo-profiles/reload | jq .
curl -s -X POST http://localhost:9000/qoo-profiles/load/video-call | jq .
```

## Dashboard layouts (quick map)

- `qoo-overview`: main summary dashboard; profile selector + active profile + threshold card
- `qoo-active-overview`: active probe-focused view; same profile controls
- `qoo-passive-overview`: passive metric-focused view; same profile controls
- `qoo-comparison`: multi-profile comparison; repeated timeline rows by selected profile

Quick dashboard health check:

```sh
docker compose logs --tail=200 dashboard | rg -i 'Flux query failed|compilation failed'
```

## Lightweight troubleshooting

- `run-godash.sh` reports `Path: BYPASS`
  - Routed target path is not active. Re-run routing setup (`setup-routing.sh`
    on Linux, `setup-mac-wireguard.sh` + `wg-quick up` on macOS).
- No new points in Grafana
  - Check `docker compose logs collector` and confirm test traffic is actually
    passing through the gateway.
- Profile switches but latency/loss do not change
  - Verify `gateway` is up and active profile changed (`curl
    http://localhost:9000/status`).
- Browser UI on `:5800` not reachable
  - Recreate browser service: `docker compose up -d --force-recreate browser`.
- macOS tunnel stops passing traffic after gateway recreation
  - Re-run `./scripts/setup-mac-wireguard.sh`, then `sudo wg-quick up
    .wg-mac/qoo-gateway.conf`.

## Docs map

- Common workflows and commands: `CHEATSHEET.md`
- Deep implementation notes and historical context: `PLAN.md`
