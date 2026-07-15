#!/bin/sh
set -e

# Docker does not guarantee network-to-interface-index order matches the
# order networks are listed under a service in docker-compose.yml - it has
# been observed to assign eth0 to wan-net and eth1 to lan-net here, the
# opposite of the naive "lan-net listed first -> eth0" assumption. Detect by
# actual subnet membership (via the kernel's own routing decision) instead
# of hardcoding eth0/eth1, so this can't silently regress again. Still
# overridable by setting LAN_IFACE/WAN_IFACE explicitly.
detect_iface_for() {
    ip route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

LAN_IFACE="${LAN_IFACE:-$(detect_iface_for 172.28.0.1)}"
WAN_IFACE="${WAN_IFACE:-$(detect_iface_for 172.29.0.1)}"
: "${LAN_IFACE:=eth0}"
: "${WAN_IFACE:=eth1}"
EXTRA_LAN_IFACES="${EXTRA_LAN_IFACES:-}"
echo "Detected LAN_IFACE=$LAN_IFACE WAN_IFACE=$WAN_IFACE"

PCAP_DIR="${PCAP_DIR:-/pcap}"
WG_ENABLE="${WG_ENABLE:-false}"
LAN_GW="${LAN_GW:-172.28.0.1}"
WAN_GW="${WAN_GW:-172.29.0.1}"
WG_FWMARK="${WG_FWMARK:-0x1}"
WG_ROUTE_TABLE="${WG_ROUTE_TABLE:-51820}"

# Profile scripts and api.py both need these (profile scripts now shape BOTH
# interfaces - see gateway/profiles/common.sh). Export unconditionally so a
# WG_ENABLE-driven reassignment to wg0 below is visible to child processes.
export LAN_IFACE
export WAN_IFACE
export EXTRA_LAN_IFACES

mkdir -p "$PCAP_DIR"

# Optional: WireGuard tunnel so a macOS host (which can't route into Docker
# bridge networks at all - see CHEATSHEET.md) can reach the gateway without
# bypassing impairment. Off by default - zero effect on Linux hosts, which
# reach the gateway's real bridge IP directly via setup-routing.sh instead.
if [ "$WG_ENABLE" = "true" ]; then
    WG_DIR="${WG_DIR:-/etc/wireguard}"
    WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
    WG_SERVER_TUNNEL_IP="${WG_SERVER_TUNNEL_IP:-10.99.99.1}"
    WG_PEER_TUNNEL_IP="${WG_PEER_TUNNEL_IP:-10.99.99.2}"

    mkdir -p "$WG_DIR"
    if [ ! -f "$WG_DIR/private.key" ]; then
        umask 077
        wg genkey > "$WG_DIR/private.key"
        wg pubkey < "$WG_DIR/private.key" > "$WG_DIR/public.key"
    fi

    echo "=== WireGuard gateway public key (for host peer config): $(cat "$WG_DIR/public.key") ==="

    if [ -n "$WG_PEER_PUBLIC_KEY" ]; then
        ip link add wg0 type wireguard
        ip address add "$WG_SERVER_TUNNEL_IP/24" dev wg0
        wg set wg0 listen-port "$WG_LISTEN_PORT" private-key "$WG_DIR/private.key" \
            peer "$WG_PEER_PUBLIC_KEY" allowed-ips "$WG_PEER_TUNNEL_IP/32"
        ip link set wg0 up

        EXTRA_LAN_IFACES="$LAN_IFACE ${EXTRA_LAN_IFACES:-}"
        # Physical LAN iface also carries wg0 UDP transport; mark it so profile
        # helpers can exempt WG transport from double-delay.
        WG_CARRIER_IFACE="$LAN_IFACE"
        LAN_IFACE="wg0"

        export LAN_IFACE
        export EXTRA_LAN_IFACES
        export WG_CARRIER_IFACE
        export WG_LISTEN_PORT

        echo "WireGuard up on wg0 ($WG_SERVER_TUNNEL_IP) - LAN_IFACE overridden to wg0, WG_CARRIER_IFACE=$WG_CARRIER_IFACE"
    else
        echo "WG_ENABLE=true but WG_PEER_PUBLIC_KEY not set yet - skipping wg0 setup for now."
        echo "Run scripts/setup-mac-wireguard.sh, then restart gateway."
    fi
fi

# Keep browser internet traffic on WAN_IFACE for full bidirectional shaping,
# but route WireGuard transport packets via LAN_GW so the macOS host tunnel
# stays reachable even when gateway's default route points to wan-net.
WAN_IFACE_NOW="$(detect_iface_for "$WAN_GW")"
[ -n "$WAN_IFACE_NOW" ] && WAN_IFACE="$WAN_IFACE_NOW"
if [ -n "$WG_CARRIER_IFACE" ]; then
    LAN_IFACE_NOW="$(detect_iface_for "$LAN_GW")"
    [ -n "$LAN_IFACE_NOW" ] && WG_CARRIER_IFACE="$LAN_IFACE_NOW"
    wg set wg0 fwmark "$WG_FWMARK"
    ip route replace default via "$LAN_GW" dev "$WG_CARRIER_IFACE" table "$WG_ROUTE_TABLE"
    ip rule del fwmark "$WG_FWMARK" table "$WG_ROUTE_TABLE" 2>/dev/null || true
    ip rule add fwmark "$WG_FWMARK" table "$WG_ROUTE_TABLE"
fi
ip route replace default via "$WAN_GW" dev "$WAN_IFACE"

# Enable forwarding between LAN and WAN interfaces (also set via compose
# sysctls: fallback for runtimes that keep /proc/sys read-only here).
(echo 1 > /proc/sys/net/ipv4/ip_forward) 2>/dev/null || true
iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
iptables -A FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
iptables -A FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
for iface in $EXTRA_LAN_IFACES; do
    [ -z "$iface" ] && continue
    iptables -A FORWARD -i "$iface" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT
done

# Load baseline impairment profile (reads LAN_IFACE/WAN_IFACE from env).
/app/profiles/baseline.sh

# Capture target-bound traffic only for collector.
TARGET_IP="${TARGET_IP:-172.29.0.20}"
tcpdump -i "$LAN_IFACE" -w "$PCAP_DIR/capture.pcap" -U host "$TARGET_IP" &

exec waitress-serve --listen=0.0.0.0:9000 api:app
