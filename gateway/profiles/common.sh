# Shared helpers for profile scripts. Sourced, not executed directly.
#
# Gateway sits between LAN_IFACE (host-facing) and WAN_IFACE (target-facing).
# Any packet crossing gateway is, at some point, EGRESS on one of these two
# real interfaces - host->target packets egress via WAN_IFACE, target->host
# packets egress via LAN_IFACE. So symmetric round-trip shaping doesn't need
# ingress redirection (IFB) at all: apply half the delay on each interface's
# egress and a full round trip picks up the full configured value. (IFB
# isn't available on this Docker Desktop kernel anyway - confirmed can't
# create an ifb-type link here.)

reset_iface() {
    iface="$1"
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root pfifo_fast
}

apply_netem() {
    iface="$1"
    shift
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root netem "$@"
}

# Same shaping as apply_netem, but exempts WireGuard transport packets on the
# listen port. Needed on WG_CARRIER_IFACE so wg0 payload is not delayed again
# when re-encapsulated out of that physical interface.
apply_netem_wg_exempt() {
    iface="$1"
    port="$2"
    shift 2
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$iface" parent 1:1 netem "$@"
    tc qdisc add dev "$iface" parent 1:2 pfifo_fast
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip sport "$port" 0xffff flowid 1:2
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip dport "$port" 0xffff flowid 1:2
}

lan_ifaces() {
    echo "$LAN_IFACE"
    for iface in $EXTRA_LAN_IFACES; do
        [ -n "$iface" ] && [ "$iface" != "$LAN_IFACE" ] && echo "$iface"
    done
}

reset_lan_ifaces() {
    lan_ifaces | while IFS= read -r iface; do
        [ -n "$iface" ] && reset_iface "$iface"
    done
}

apply_lan_netem() {
    lan_ifaces | while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        if [ -n "$WG_CARRIER_IFACE" ] && [ "$iface" = "$WG_CARRIER_IFACE" ]; then
            apply_netem_wg_exempt "$iface" "${WG_LISTEN_PORT:-51820}" "$@"
        else
            apply_netem "$iface" "$@"
        fi
    done
}

# Same shaping as apply_netem, but exempts WireGuard transport packets on the
# listen port. Needed on WG_CARRIER_IFACE so wg0 payload is not delayed again
# when re-encapsulated out of that physical interface.
apply_netem_wg_exempt() {
    iface="$1"
    port="$2"
    shift 2
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$iface" parent 1:1 netem "$@"
    tc qdisc add dev "$iface" parent 1:2 pfifo_fast
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip sport "$port" 0xffff flowid 1:2
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip dport "$port" 0xffff flowid 1:2
}

lan_ifaces() {
    echo "$LAN_IFACE"
    for iface in $EXTRA_LAN_IFACES; do
        [ -n "$iface" ] && [ "$iface" != "$LAN_IFACE" ] && echo "$iface"
    done
}

reset_lan_ifaces() {
    lan_ifaces | while IFS= read -r iface; do
        [ -n "$iface" ] && reset_iface "$iface"
    done
}

apply_lan_netem() {
    lan_ifaces | while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        if [ -n "$WG_CARRIER_IFACE" ] && [ "$iface" = "$WG_CARRIER_IFACE" ]; then
            apply_netem_wg_exempt "$iface" "${WG_LISTEN_PORT:-51820}" "$@"
        else
            apply_netem "$iface" "$@"
        fi
    done
}

# Same shaping as apply_netem, but exempts WireGuard transport packets on the
# listen port. Needed on WG_CARRIER_IFACE so wg0 payload is not delayed again
# when re-encapsulated out of that physical interface.
apply_netem_wg_exempt() {
    iface="$1"
    port="$2"
    shift 2
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$iface" parent 1:1 netem "$@"
    tc qdisc add dev "$iface" parent 1:2 pfifo_fast
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip sport "$port" 0xffff flowid 1:2
    tc filter add dev "$iface" parent 1:0 protocol ip prio 1 u32 match ip dport "$port" 0xffff flowid 1:2
}

lan_ifaces() {
    echo "$LAN_IFACE"
    for iface in $EXTRA_LAN_IFACES; do
        [ -n "$iface" ] && [ "$iface" != "$LAN_IFACE" ] && echo "$iface"
    done
}

reset_lan_ifaces() {
    lan_ifaces | while IFS= read -r iface; do
        [ -n "$iface" ] && reset_iface "$iface"
    done
}

apply_lan_netem() {
    lan_ifaces | while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        if [ -n "$WG_CARRIER_IFACE" ] && [ "$iface" = "$WG_CARRIER_IFACE" ]; then
            apply_netem_wg_exempt "$iface" "${WG_LISTEN_PORT:-51820}" "$@"
        else
            apply_netem "$iface" "$@"
        fi
    done
}
