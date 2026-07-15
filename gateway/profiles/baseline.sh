#!/bin/sh
# baseline: no impairment, both directions
. "$(dirname "$0")/common.sh"
LAN_IFACE="${LAN_IFACE:-eth0}"
WAN_IFACE="${WAN_IFACE:-eth1}"
reset_lan_ifaces
reset_iface "$WAN_IFACE"
