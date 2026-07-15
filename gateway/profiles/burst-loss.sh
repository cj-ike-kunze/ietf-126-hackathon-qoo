#!/bin/sh
# burst-loss: realistic burst loss (Gilbert model) - downstream
# (LAN_IFACE, host-facing) only, by design (loss profiles are
# one-directional; see CHEATSHEET.md)
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem loss gemodel 5% 10% 90% 80%
reset_iface "$WAN_IFACE"
