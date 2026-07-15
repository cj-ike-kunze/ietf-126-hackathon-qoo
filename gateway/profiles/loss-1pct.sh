#!/bin/sh
# loss-1pct: mild loss - downstream (LAN_IFACE, host-facing) only, by
# design (loss profiles are one-directional; see CHEATSHEET.md)
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem loss 1%
reset_iface "$WAN_IFACE"
