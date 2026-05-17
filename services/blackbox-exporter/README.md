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

## More

- Upstream: <https://github.com/prometheus/blackbox_exporter>
