#!/usr/bin/env bash
set -euo pipefail

script_name="$(basename "$0")"

if [ "${1:-}" = "" ]; then
  cat >&2 <<EOF
Usage: $script_name <target>
Runs continuous ping to <target> from the browser container until killed.
EOF
  exit 2
fi

TARGET="$1"
shift || true

if [ -t 1 ]; then
  exec docker compose exec browser ping "$TARGET" "$@"
else
  exec docker compose exec -T browser ping "$TARGET" "$@"
fi
