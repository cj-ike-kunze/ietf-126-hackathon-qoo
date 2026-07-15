#!/bin/sh
# bandwidth-5mbit: constrained downstream throughput (e.g. slow broadband)
# - downstream (LAN_IFACE) only
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem rate 5mbit
reset_iface "$WAN_IFACE"
