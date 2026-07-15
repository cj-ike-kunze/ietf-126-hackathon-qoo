#!/usr/bin/env bash
# Rebuild and restart the Grafana (dashboard) service only.
# Usage: ./restart-grafana.sh [service-name]
# Default service-name: dashboard
set -euo pipefail

SERVICE="${1:-dashboard}"

# Detect compose command: prefer `docker compose`, fall back to `docker-compose` if present
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "Error: neither 'docker compose' nor 'docker-compose' is available in PATH" >&2
  exit 1
fi

echo "Rebuilding service: $SERVICE"
"${COMPOSE_CMD[@]}" build "$SERVICE"

echo "Restarting service: $SERVICE"
# Use --no-deps to avoid bringing up unrelated services
"${COMPOSE_CMD[@]}" up -d --no-deps --force-recreate "$SERVICE"

echo "Service '$SERVICE' rebuilt and restarted. To follow logs run: ${COMPOSE_CMD[*]} logs -f --tail=200 $SERVICE"
