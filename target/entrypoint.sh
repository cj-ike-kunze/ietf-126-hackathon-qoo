#!/bin/sh
set -e

HTTP_PORT="${HTTP_PORT:-8000}"
IPERF_PORT="${IPERF_PORT:-5201}"
QUIC_ADDR="${QUIC_ADDR:-:4433}"

mkdir -p /var/www
echo "target ok" > /var/www/index.html
# /var/www/dash/manifest.mpd is baked into the image at build time (see Dockerfile)

python3 -m http.server "$HTTP_PORT" --directory /var/www &
QUIC_ADDR="$QUIC_ADDR" QUIC_ROOT="/var/www" /app/quicserve &

exec iperf3 -s -p "$IPERF_PORT"
