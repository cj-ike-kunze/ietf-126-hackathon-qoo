#!/usr/bin/env bash
set -euo pipefail

WG_FORCE_RECREATE="${WG_FORCE_RECREATE:-1}"
WG_CONF=".wg-mac/qoo-gateway.conf"

if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running. Starting Docker Desktop..."

    open -a Docker

    # Wait for Docker to become ready
    while ! docker info >/dev/null 2>&1; do
        sleep 2
    done

    echo "Docker is ready."
else
    echo "Docker is already running."
fi

docker compose up -d --build

# Drop stale tunnel state before generating fresh config.
sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true

WG_FORCE_RECREATE="$WG_FORCE_RECREATE" ./scripts/setup-mac-wireguard.sh
sudo wg-quick up "$WG_CONF"