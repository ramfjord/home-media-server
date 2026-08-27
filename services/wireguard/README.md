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
handshakes — no torrent identity. Endpoint rotation is real, not
theoretical: the provider hostname resolves to a different address
within minutes, so pinning `Endpoint` to a literal IP is not an option.

## What the killswitch cannot cover: DNS

The killswitch drops `eth0` egress from inside the shared netns. Docker's
embedded resolver at `127.0.0.11` is not subject to it — dockerd forwards
those queries from **outside** the namespace, so no `OUTPUT` rule inside
can stop them. A container with a default-DROP `OUTPUT` policy and no
`wg0` interface at all still resolves names, exiting via the host
resolver and the home IP.

So `tunnel-up` does **not**, by itself, imply every packet exits via the
VPN. DNS containment rests on two things instead:

1. **`DNS =` in `wg0.conf`.** wg-quick registers it with openresolv as an
   *exclusive* record, which pins `/etc/resolv.conf` to the provider's
   internal resolver — reachable only through the tunnel. This is why
   dropping the `DNS =` directive is not an option: `/etc/resolv.conf`
   would stay at `127.0.0.11` permanently, turning a closed window into a
   standing leak of every tracker lookup.
2. **The consumers' `ExecStartPre` health gate.** Between container init
   and wg-quick applying the record, `/etc/resolv.conf` is still
   `127.0.0.11`. VPN consumers block on wireguard reporting *healthy*, so
   they never run inside that window.

The `lo` pinhole exists to let that bootstrap resolution happen. It is
not a bootstrap-only concession — it is the permanent shape of the
embedded resolver, which the killswitch has no reach over.

## Healthcheck

Asserts a **fresh wg0 handshake** (< 180s), not `ping 1.1.1.1` —
reachability false-greened (eth0 path pre-killswitch) and false-redded
(provider drops ICMP through the tunnel). With the killswitch, a fresh
handshake is the egress guarantee **for routed traffic**: eth0 egress is
dropped, so tunnel-up ⟺ routed packets exit via the VPN. It does not
cover DNS (see above). VPN consumers gate on this via their
`ExecStartPre` (`use_vpn` in `__service__.service.elp`), so a dead
tunnel holds qBittorrent down rather than launching it onto a leaky
path — and that same gate is what keeps them out of the window where
`/etc/resolv.conf` still points at the embedded resolver.

## Metrics

WireGuard emits none itself; [wireguard-exporter](../wireguard-exporter/)
(in this netns) exposes handshake + per-peer transfer, feeding the VPN
Containment dashboard and the `WireGuardTunnelStale` alert. It proves
the tunnel is alive and carrying the payload — *not* the absence of a
leak. Routed-traffic containment is the killswitch's structural job;
DNS containment is the `DNS =` record's. Neither is a metric.

## More

- Project: <https://www.wireguard.com/>
- Upstream (image): <https://github.com/linuxserver/docker-wireguard>
