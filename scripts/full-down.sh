#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WG_CONF="$REPO_DIR/.wg-mac/qoo-gateway.conf"

docker compose -f "$REPO_DIR/docker-compose.yml" down
sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true