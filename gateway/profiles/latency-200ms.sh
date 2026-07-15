#!/bin/sh
# latency-200ms: satellite / bad mobile - 200ms round-trip total, split
# symmetrically (100ms each way) across both interfaces.
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem delay 100ms 5ms
apply_netem "$WAN_IFACE" delay 100ms 5ms
