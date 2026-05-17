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

## More

- Project: <https://www.wireguard.com/>
- Upstream (image): <https://github.com/linuxserver/docker-wireguard>
