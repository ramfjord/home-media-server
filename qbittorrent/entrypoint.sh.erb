#!/bin/bash
set -e

# Get wireguard's IP on the mediaserver network
WIREGUARD_IP=$(getent hosts wireguard | awk '{ print $1 }')

if [ -z "$WIREGUARD_IP" ]; then
  echo "Error: Could not resolve wireguard hostname"
  exit 1
fi

echo "Found wireguard at $WIREGUARD_IP"

# Add default route through wireguard for all outbound traffic
# This ensures all traffic from qbittorrent goes through the VPN
ip route add default via "$WIREGUARD_IP" metric 10 || ip route replace default via "$WIREGUARD_IP" metric 10

# Verify route was added
ip route show

echo "Routing configured, starting qbittorrent..."

# Start the original qbittorrent entrypoint
exec /init "$@"
