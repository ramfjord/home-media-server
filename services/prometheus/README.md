# prometheus

Most metrics arrive via **otelcol**, not from Prometheus's own scraping. Otelcol
runs a `prometheusreceiver` that scrapes node-exporter, cadvisor, blackbox, the
*arr exporters, etc., and forwards everything to this Prometheus instance. You
can tell which series came through that path by the
`otel_scope_name="...prometheusreceiver"` label that gets stamped on them.

That's why the only entry under `scrape_configs/` is `prometheus_meta.yaml.elp`
— Prometheus only scrapes itself here. Everything else lives in
`services/otelcol/otelcol-config.yaml.elp`. If you want to add a new scrape
target, add it there, not here.

`rules/` and the alertmanager wiring are still owned by Prometheus and live in
this directory.
