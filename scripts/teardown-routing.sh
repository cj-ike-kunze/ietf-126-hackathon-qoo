#!/bin/sh
# Reverts the route added by setup-routing.sh.
# Usage: ./teardown-routing.sh [target-ip-or-cidr] [gateway-ip]
set -e

TARGET="${1:-${TARGET:-172.29.0.20}}"
GATEWAY_IP="${2:-${GATEWAY_IP:-172.28.0.10}}"

OS="$(uname -s)"

case "$OS" in
    Darwin)
        echo "macOS detected: removing route $TARGET via $GATEWAY_IP"
        sudo route delete "$TARGET" "$GATEWAY_IP"
        ;;
    Linux)
        echo "Linux detected: removing route $TARGET via $GATEWAY_IP"
        sudo ip route del "$TARGET" via "$GATEWAY_IP"
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

echo "Route removed."
