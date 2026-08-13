#!/bin/bash
#
# fix_bonds.sh — rapidly fixes bond MTU and LACP settings on Proxmox VE
# nodes. Sets jumbo frames on a bond and its slaves, both live and
# persistent in /etc/network/interfaces.
#
# Handy when you've got a cluster of Proxmox boxes that need sorting
# and you don't want to be clicking through the web UI on each one.
#
# AI assisted — human built and refined with Claude (Anthropic).
#
# Usage:
#   bash fix_bonds.sh [bond_name] [mtu] [config_file]
#
# Arguments (all optional, positional):
#   bond_name   — bond interface to update (default: bond1)
#   mtu         — MTU value to set (default: 9000)
#   config_file — path to interfaces file (default: /etc/network/interfaces)
#
# Examples:
#   bash fix_bonds.sh                      # defaults: bond1, 9000
#   bash fix_bonds.sh bond0               # different bond, still 9000
#   bash fix_bonds.sh bond1 1500          # reset back to standard MTU
#
# Run as root. Does an in-place edit of the config file so take a
# backup first if you've got owt important on there.
#

BOND_NAME="${1:-bond1}"
MTU_VALUE="${2:-9000}"
CONFIG_FILE="${3:-/etc/network/interfaces}"

# check sysfs for the slave list — if there's nowt there the bond's
# either missing or has no interfaces assigned
SLAVES=$(cat /sys/class/net/${BOND_NAME}/bonding/slaves 2>/dev/null)
if [ -z "$SLAVES" ]; then
    echo "Error: ${BOND_NAME} not found or has no slave interfaces assigned."
    exit 1
fi
echo "Found slave interfaces: ${SLAVES}"

# check the bond mode — if it's 802.3ad (LACP) we want fast rate so
# failover detection happens in seconds not minutes. slow is the default
# and it's proper sluggish at 30 second intervals. also make sure the
# hash policy is layer3+4 so traffic actually spreads across both links
# based on src/dst IP and port, not just MAC.
BOND_MODE=$(cat /sys/class/net/${BOND_NAME}/bonding/mode 2>/dev/null)
LACP_MODE=false
if echo "${BOND_MODE}" | grep -q "802.3ad"; then
    LACP_MODE=true
    LACP_RATE=$(cat /sys/class/net/${BOND_NAME}/bonding/lacp_rate 2>/dev/null)
    XMIT_HASH=$(cat /sys/class/net/${BOND_NAME}/bonding/xmit_hash_policy 2>/dev/null)
    echo "Bond mode is 802.3ad (LACP), current rate: ${LACP_RATE}, hash policy: ${XMIT_HASH}"
fi

echo "Updating ${CONFIG_FILE}..."

# two-pass sed per interface: strip any existing mtu line first, then
# add the new one. doing it in a single pass is a bit of a faff with
# sed's block syntax so this way's cleaner.
sed -i "/iface ${BOND_NAME} /,/^$/ { /^\s*mtu/d; }" "${CONFIG_FILE}"
sed -i "/iface ${BOND_NAME} /a\\    mtu ${MTU_VALUE}" "${CONFIG_FILE}"

# if we're running LACP, make sure fast rate and layer3+4 hashing are
# set — no point having a fancy bond if the switch takes half a minute
# to notice summat's gone, or all your traffic goes down one link
if [ "${LACP_MODE}" = true ]; then
    sed -i "/iface ${BOND_NAME} /,/^$/ { /^\s*bond-lacp-rate/d; }" "${CONFIG_FILE}"
    sed -i "/iface ${BOND_NAME} /a\\    bond-lacp-rate fast" "${CONFIG_FILE}"
    echo "Added bond-lacp-rate fast to ${BOND_NAME}"

    sed -i "/iface ${BOND_NAME} /,/^$/ { /^\s*bond-xmit-hash-policy/d; }" "${CONFIG_FILE}"
    sed -i "/iface ${BOND_NAME} /a\\    bond-xmit-hash-policy layer3+4" "${CONFIG_FILE}"
    echo "Added bond-xmit-hash-policy layer3+4 to ${BOND_NAME}"
fi

# same again for each slave — nowt fancy, just the same two-pass job
for slave in ${SLAVES}; do
    sed -i "/iface ${slave} /,/^$/ { /^\s*mtu/d; }" "${CONFIG_FILE}"
    sed -i "/iface ${slave} /a\\    mtu ${MTU_VALUE}" "${CONFIG_FILE}"
done

# reload networking to pick up the changes rather than faffing about
# with ip link on each interface individually
echo "Reloading networking service..."
systemctl reload networking

# right, let's have a look and make sure it's actually stuck
echo "----------------------------------------"
echo "Current MTU Status:"
echo "${BOND_NAME}: $(ip link show "${BOND_NAME}" | grep -o 'mtu [0-9]*')"
for slave in ${SLAVES}; do
    echo "  └─ ${slave}: $(ip link show "${slave}" | grep -o 'mtu [0-9]*')"
done

if [ "${LACP_MODE}" = true ]; then
    echo ""
    echo "LACP Status:"
    LACP_RATE_NOW=$(cat /sys/class/net/${BOND_NAME}/bonding/lacp_rate 2>/dev/null)
    XMIT_HASH_NOW=$(cat /sys/class/net/${BOND_NAME}/bonding/xmit_hash_policy 2>/dev/null)
    echo "${BOND_NAME}: lacp_rate ${LACP_RATE_NOW}, xmit_hash_policy ${XMIT_HASH_NOW}"
fi
