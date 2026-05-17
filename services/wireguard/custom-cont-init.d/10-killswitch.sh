#!/bin/sh
# VPN killswitch for the shared netns.
#
# Every service with use_vpn shares THIS container's netns, which holds
# both wg0 (the tunnel) and eth0 (the docker bridge -> host -> home IP).
# wg-quick's policy routing alone is not a backstop: it is torn down and
# rebuilt on every tunnel/container lifecycle event, and this image's
# wg-quick installs no netfilter killswitch. Anything not routed into wg0
# during such a window exits via eth0's default route = the home IP.
#
# This runs at container init -- BEFORE the wg-quick service -- so the
# fail-closed posture is in place from the first packet, with no
# startup-race window. Default-DROP OUTPUT, pinholed for exactly what
# must work:
#   - lo            : loopback (arrs hit qbit here; docker embedded DNS
#                      at 127.0.0.11 used to bootstrap-resolve the wg
#                      endpoint before wg-quick swaps resolv.conf)
#   - wg0           : the tunnel itself (all post-handshake egress)
#   - docker subnet : caddy -> wireguard:8080 (Authelia browser path),
#                      api-config, exporters -- the mediaserver-network
#                      peers; derived from eth0's connected route
#   - udp/<port>    : the wg handshake to the provider endpoint. Scoped
#                      to the configured port, NOT a fixed IP, so it
#                      survives endpoint rotation. Carries only encrypted
#                      handshakes, no torrent identity -- accepted seam.
#   - ESTABLISHED   : return path for inbound WebUI/api connections.
#
# Fails closed and loud: if iptables or the endpoint port can't be
# resolved, init aborts and the container does not come up unprotected.
set -eu

DOCKER_NET="$(ip -o -4 route show dev eth0 scope link 2>/dev/null | awk 'NR==1{print $1}')"
EP_PORT="$(awk -F: 'tolower($0) ~ /^[[:space:]]*endpoint/ {print $NF}' /config/*.conf 2>/dev/null | tr -dc 0-9 | head -c5)"

[ -n "$DOCKER_NET" ] || { echo "[killswitch] FATAL: could not derive docker subnet from eth0" >&2; exit 1; }
[ -n "$EP_PORT" ]    || { echo "[killswitch] FATAL: could not parse Endpoint port from /config/*.conf" >&2; exit 1; }

apply() {  # $1 = iptables | ip6tables
  "$1" -F OUTPUT
  "$1" -P OUTPUT DROP
  "$1" -A OUTPUT -o lo  -j ACCEPT
  "$1" -A OUTPUT -o wg0 -j ACCEPT
  "$1" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

apply iptables
# IPv4-only pinholes (docker bridge + wg handshake are v4 here):
iptables -A OUTPUT -d "$DOCKER_NET" -j ACCEPT
iptables -A OUTPUT -p udp --dport "$EP_PORT" -j ACCEPT

# Netns has no IPv6 default route today; default-DROP v6 closes that
# path if the docker network ever gains IPv6. lo/wg0/ESTABLISHED only.
apply ip6tables

echo "[killswitch] OUTPUT default DROP; allowed: lo, wg0, ${DOCKER_NET}, udp/${EP_PORT}, established" >&2
