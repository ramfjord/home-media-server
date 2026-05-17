# wireguard-exporter

Exposes the WireGuard tunnel as Prometheus metrics — per-peer
`wireguard_{sent,received}_bytes_total` and
`wireguard_latest_handshake_seconds`. WireGuard otherwise emits *no*
metrics; before this, the only tunnel signal was cAdvisor's netns
byte counters (which can't distinguish tunnel transport from a leak).

Runs in wireguard's netns (`use_vpn`) because it reads the tunnel via
`wg show all dump` — wg0 isn't reachable over the bridge. Subject to
the killswitch like any netns peer; unaffected because `wg show` is a
local netlink call and its scrape responses ride the docker-subnet
pinhole.

## What it does and does not prove

It proves the tunnel is **alive and carrying the payload** (fresh
handshake, transfer rising). It does **not** prove the absence of a
parallel leak — traffic can flow on wg0 *and* leak on eth0 at once.
The no-leak guarantee is structural: the killswitch
(`services/wireguard/README.md`), verified directly at deploy. This
exporter feeds the VPN dashboard and the `WireGuardTunnelStale` alert
(early warning that containment now rests solely on the killswitch).

## Pinning

Image is pinned (`:3.6.6`), not `:latest` — single-maintainer
upstream. Bump deliberately; the metric surface is stable, so churn
is low. The image ships a broken default `CMD ["-a"]` (the binary's
`-a/--prepend_sudo` now requires a `true|false` value), so
`service.yml.elp` overrides `command:` with `-a false`; re-check that
override still applies on any pin bump. Freshness is computed in PromQL as
`time() - wireguard_latest_handshake_seconds`, so no dependency on
the optional `wireguard_latest_handshake_delay_seconds` (`-d true`).

## More

- Upstream: <https://github.com/MindFlavor/prometheus_wireguard_exporter>
