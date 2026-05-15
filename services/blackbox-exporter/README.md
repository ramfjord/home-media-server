# Blackbox Exporter

Probes HTTP/TCP/ICMP endpoints from the outside and exposes the results
as Prometheus metrics — answering "is this URL reachable, and how fast
does it respond?" without the target needing to expose metrics itself.
Used here to monitor service liveness and certificate expiry.

Probe definitions (`blackbox.yml`) are rendered alongside Prometheus's
config; the targets to probe come from Prometheus's scrape configuration.

## More

- Upstream: <https://github.com/prometheus/blackbox_exporter>
