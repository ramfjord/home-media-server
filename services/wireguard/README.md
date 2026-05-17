# WireGuard

VPN tunnel to an external VPN provider. The downloading stack
(Radarr, Sonarr, Prowlarr, qBittorrent) joins this container's
network namespace via `network_mode: container:wireguard`, so all of
their outbound traffic exits through the VPN provider rather than the
home IP.

Distinct from Tailscale (which runs on the host for remote *access*);
WireGuard here is purely about masking outbound downloader traffic.

## Killswitch

`custom-cont-init.d/10-killswitch.sh` installs a default-DROP `OUTPUT`
policy in the shared netns at container init — *before* `wg-quick`, so
there is no startup-race window. wg-quick's policy routing is not a
backstop (rebuilt every tunnel/container lifecycle event; this image
installs no netfilter killswitch of its own), so without this any such
window leaks downloader traffic out `eth0` → the home IP, independent
of qBittorrent's own `wg0` pin.

Pinholes: `lo`, `wg0`, the docker subnet (caddy/api-config/exporters
on mediaserver-network — derived from eth0's connected route), and
UDP to the configured endpoint **port** (not a fixed IP, so endpoint
rotation survives). Fails closed and loud — if iptables or the port
can't be resolved, the container does not come up unprotected.

Accepted seam: UDP egress on the endpoint port is open to any IP
(required for endpoint rotation). It carries only encrypted WireGuard
handshakes — no torrent identity.

## Healthcheck

Asserts a **fresh wg0 handshake** (< 180s), not `ping 1.1.1.1` —
reachability false-greened (eth0 path pre-killswitch) and false-redded
(provider drops ICMP through the tunnel). With the killswitch, a fresh
handshake *is* the egress guarantee: eth0 egress is dropped, so
tunnel-up ⟺ exiting via the VPN. VPN consumers gate on this via their
`ExecStartPre` (`use_vpn` in `__service__.service.elp`), so a dead
tunnel holds qBittorrent down rather than launching it onto a leaky
path.

## More

- Project: <https://www.wireguard.com/>
- Upstream (image): <https://github.com/linuxserver/docker-wireguard>
