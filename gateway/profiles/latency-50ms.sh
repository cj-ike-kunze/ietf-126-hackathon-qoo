#!/bin/sh
# latency-50ms: intercontinental path - 50ms round-trip total, split
# symmetrically (25ms each way) across both interfaces so a simple ping
# shows the full labeled value regardless of direction.
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem delay 25ms 2.5ms
apply_netem "$WAN_IFACE" delay 25ms 2.5ms
