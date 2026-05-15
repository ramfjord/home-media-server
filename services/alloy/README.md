# Alloy

Grafana Alloy is a telemetry collector. Here it reads the host's
systemd journal and ships log lines to Loki, and emits per-unit error
counters that Prometheus scrapes — so dashboards and alerts can react
to logs without Prometheus having to read logs directly.

`config.alloy` is the pipeline definition: which inputs to read, how to
relabel, and where to send the result.

## More

- Upstream: <https://github.com/grafana/alloy>
- Docs: <https://grafana.com/docs/alloy/latest/>
