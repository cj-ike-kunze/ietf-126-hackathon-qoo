#!/bin/sh
# Routes host traffic for TARGET through the gateway container's GATEWAY_IP.
# Usage: ./setup-routing.sh [target-ip-or-cidr] [gateway-ip]
set -e

TARGET="${1:-${TARGET:-172.29.0.20}}"
GATEWAY_IP="${2:-${GATEWAY_IP:-172.28.0.10}}"

OS="$(uname -s)"

case "$OS" in
    Darwin)
        echo "macOS detected: adding route $TARGET via $GATEWAY_IP"
        sudo route add "$TARGET" "$GATEWAY_IP"
        ;;
    Linux)
        echo "Linux detected: adding route $TARGET via $GATEWAY_IP"
        sudo ip route add "$TARGET" via "$GATEWAY_IP"
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

echo "Route added. Run teardown-routing.sh to revert."
