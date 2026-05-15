# Grafana

Visualization layer for the stack: dashboards over Prometheus metrics
and Loki logs, plus the UI for browsing alerts. This is where you go
to see graphs of how the server is behaving.

`provisioning/` holds datasource and dashboard definitions that
Grafana loads on startup — so dashboards are version-controlled here
rather than clicked together in the UI and lost when the volume is
wiped.

## More

- Upstream: <https://github.com/grafana/grafana>
- Docs: <https://grafana.com/docs/grafana/latest/>
