#!/bin/sh
# combined-bad: realistic bad conditions - 100ms round-trip delay (split
# symmetrically, 50ms each way) + 2% loss downstream only (loss profiles
# are one-directional; see CHEATSHEET.md)
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem delay 50ms 10ms distribution normal loss 2%
apply_netem "$WAN_IFACE" delay 50ms 10ms distribution normal
