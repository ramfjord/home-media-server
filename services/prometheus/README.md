# Prometheus

Prometheus collects and stores metrics on how the server is running,
for use in graphs and alerts. Alongside logs and traces, metrics are
one of the key pillars of observability.

`scrape_configs/` is how Prometheus pulls metrics from other services
— each file describes a target (or a class of targets) to poll. To
add a service to scraping, mark it `scrape_target: true` in its
`service.yml` and `scrape_configs/scrape_configs.yaml.elp` picks it
up automatically; no new file needed for the common case.

`rules/` does two jobs: recording rules pre-compute labels and
derived series so dashboards stay fast, and alerting rules define the
conditions under which Alertmanager should fire (e.g. "this service
has been down for 5 minutes"). Each file groups related rules by
subject.

## More

- Upstream: <https://github.com/prometheus/prometheus>
- Docs: <https://prometheus.io/docs/>
