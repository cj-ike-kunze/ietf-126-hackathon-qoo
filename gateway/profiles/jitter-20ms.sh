#!/bin/sh
# jitter-20ms: mobile network variability - 50ms round-trip base delay,
# 20ms round-trip jitter, split symmetrically (25ms/10ms each way). Note:
# splitting jitter across two independent qdiscs isn't a mathematically
# exact variance split, but is a fine approximation for demo purposes.
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem delay 25ms 10ms distribution normal
apply_netem "$WAN_IFACE" delay 25ms 10ms distribution normal
