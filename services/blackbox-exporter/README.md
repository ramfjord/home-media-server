# Blackbox Exporter

Probes HTTP/TCP/ICMP endpoints from the outside and exposes the results
as Prometheus metrics — answering "is this URL reachable, and how fast
does it respond?" without the target needing to expose metrics itself.
Used here to monitor service liveness and certificate expiry.

Probe **definitions** (`blackbox.yml` — the modules) render here and
are read by this container. **Targets** and per-target module come from
Prometheus's `scrape_configs`; the two couple only by module name.
`blackbox.yml.elp` stays in this tree (not prometheus's) so this
service's `.path` watcher reloads it — a watcher only sees
`config/<its-own-name>/`.

## `public_probe_*` failures across many services at once

The `public_probe_*` jobs resolve the tailnet FQDN from inside this
container, so they depend on container DNS reaching Tailscale MagicDNS.
Docker binds a container's upstream resolvers when the container
**starts**, from `/etc/resolv.conf` as it reads at that instant, and
never revisits them. tailscaled reports `Started` roughly 11s before it
writes that file, so on a cold boot any container starting inside the
gap inherits the ISP's resolvers and can never resolve the FQDN — every
`public_probe_*` fails while the services themselves are healthy.

The signature is `lookup <fqdn> on 127.0.0.11:53: no such host` in this
container's log (and caddy's). Confirm with:

```sh
docker exec blackbox-exporter cat /etc/resolv.conf | grep -i ExtServers
```

`tailscale-dns-ready.service` closes the race by holding
`docker.service` until the MagicDNS nameserver is actually in
`/etc/resolv.conf`, so containers cannot start inside the gap. It is
bounded at 60s and docker only `Wants=` it, so a Tailscale failure
delays the boot rather than blocking it — and the failed unit pages via
`SystemdUnitFailed` instead of degrading silently.

Setting `dns` in `/etc/docker/daemon.json` is the obvious alternative
and does not work: it takes wireguard down. See the rationale in
`targets/debian/etc/docker/daemon.json.elp`.

A container that started before the gate existed keeps its old resolvers
until it is recreated.

The `internal_probe_*` jobs are unaffected — they use container names,
resolved by Docker's embedded resolver.

## More

- Upstream: <https://github.com/prometheus/blackbox_exporter>
