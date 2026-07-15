#!/bin/sh
# Setup for the WireGuard fallback on hosts (macOS Docker Desktop)
# that can't route into Docker bridge networks at all. Establishes a tunnel
# scoped ONLY to the gateway container - traffic to wan-net (target) still
# flows through gateway's existing tc/netem impairment, it's just reached
# via the tunnel instead of a direct bridge route. Does nothing to affect
# Linux hosts, which should keep using setup-routing.sh directly.
#
# Usage: ./setup-mac-wireguard.sh [--force-recreate]
set -e

usage() {
    cat <<'EOF'
Usage: ./scripts/setup-mac-wireguard.sh [--force-recreate]

Options:
  --force-recreate  Delete existing host+gateway WireGuard keys and regenerate
                    everything from scratch before writing qoo-gateway.conf.
EOF
}

FORCE_RECREATE="${WG_FORCE_RECREATE:-0}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force-recreate|--fresh)
            FORCE_RECREATE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WG_LOCAL_DIR="$REPO_DIR/.wg-mac"
WG_CONF="$WG_LOCAL_DIR/qoo-gateway.conf"

if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    echo "*** wireguard-tools not found. Install with: brew install wireguard-tools ***" >&2
    exit 1
fi

mkdir -p "$WG_LOCAL_DIR"
chmod 700 "$WG_LOCAL_DIR"

if [ "$FORCE_RECREATE" = "1" ]; then
    echo "Forcing fresh WireGuard keys and config..."
    rm -f "$WG_LOCAL_DIR/host_private.key" "$WG_LOCAL_DIR/host_public.key" "$WG_CONF"
    rm -f "$REPO_DIR/data/wg-keys/private.key" "$REPO_DIR/data/wg-keys/public.key"
fi

if [ ! -f "$WG_LOCAL_DIR/host_private.key" ]; then
    echo "Generating host WireGuard keypair..."
    umask 077
    wg genkey > "$WG_LOCAL_DIR/host_private.key"
    wg pubkey < "$WG_LOCAL_DIR/host_private.key" > "$WG_LOCAL_DIR/host_public.key"
fi
HOST_PRIVATE_KEY="$(cat "$WG_LOCAL_DIR/host_private.key")"
HOST_PUBLIC_KEY="$(cat "$WG_LOCAL_DIR/host_public.key")"

cd "$REPO_DIR"

echo "Starting gateway to generate its WireGuard keypair..."
WG_ENABLE=true docker compose up -d --force-recreate gateway
sleep 2

GATEWAY_PUBLIC_KEY="$(docker compose exec -T gateway cat /etc/wireguard/public.key)"
if [ -z "$GATEWAY_PUBLIC_KEY" ]; then
    echo "*** Could not read gateway's public key. Check: docker compose logs gateway ***" >&2
    exit 1
fi
echo "Gateway public key: $GATEWAY_PUBLIC_KEY"
echo "Host public key:    $HOST_PUBLIC_KEY"

echo "Restarting gateway with the host's public key as its WireGuard peer..."
WG_ENABLE=true WG_PEER_PUBLIC_KEY="$HOST_PUBLIC_KEY" docker compose up -d --force-recreate gateway
sleep 2

cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $HOST_PRIVATE_KEY
Address = 10.99.99.2/32

[Peer]
PublicKey = $GATEWAY_PUBLIC_KEY
Endpoint = 127.0.0.1:51820
AllowedIPs = 172.29.0.0/24, 10.99.99.1/32
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONF"

echo ""
echo "=== Setup complete ==="
echo "Wrote $WG_CONF"
echo ""
echo "Bring the tunnel up:"
echo "  sudo wg-quick up $WG_CONF"
echo ""
echo "Test (should reach target through the gateway's impairment, not bypass it):"
echo "  ping 172.29.0.20"
echo ""
echo "Tear down when done:"
echo "  sudo wg-quick down $WG_CONF"
