#!/bin/sh
set -e

HTTP_PORT="${HTTP_PORT:-8000}"
IPERF_PORT="${IPERF_PORT:-5201}"
QUIC_ADDR="${QUIC_ADDR:-:4433}"
NETWORKQUALITY_PORT="${NETWORKQUALITY_PORT:-4043}"
NETWORKQUALITY_PUBLIC_NAME="${NETWORKQUALITY_PUBLIC_NAME:-172.29.0.20}"

mkdir -p /var/www
echo "target ok" > /var/www/index.html
# /var/www/dash/manifest.mpd is baked into the image at build time (see Dockerfile)

python3 -m http.server "$HTTP_PORT" --directory /var/www &
QUIC_ADDR="$QUIC_ADDR" QUIC_ROOT="/var/www" /app/quicserve &
/app/networkqualityd \
	-listen-addr 0.0.0.0 \
	-public-port "$NETWORKQUALITY_PORT" \
	-public-name "$NETWORKQUALITY_PUBLIC_NAME" \
	-config-name "$NETWORKQUALITY_PUBLIC_NAME" \
	-cert-file /app/certs/cert.pem \
	-key-file /app/certs/key.pem &

exec iperf3 -s -p "$IPERF_PORT"
