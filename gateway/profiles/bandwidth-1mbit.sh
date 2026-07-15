#!/bin/sh
# bandwidth-1mbit: severely constrained downstream throughput (e.g.
# congested mobile) - downstream (LAN_IFACE) only, real links are usually
# asymmetric (down >> up) so this matches that intuition
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
apply_lan_netem rate 1mbit
reset_iface "$WAN_IFACE"
