# mcp-grafana

Official Grafana MCP server. Exposes Grafana's API — and, transitively,
whichever Prometheus/Loki datasources Grafana is configured against —
as MCP tools. Paired with [`mcpo`](../mcpo/) which translates its SSE
protocol into the OpenAPI surface Open WebUI's tool-servers feature
consumes.

Speaks SSE on container port `8000`. Not published to the host; only
mcpo on the `mediaserver` network reaches it.

## More

- Upstream: <https://github.com/grafana/mcp-grafana>

## Auth

Basic auth against the Grafana admin user
(`service_overrides.grafana.admin_username` / `admin_password`). For a
hardened setup, swap to a service-account token: create one in Grafana
UI → Administration → Service accounts, then replace the
`GRAFANA_USERNAME`/`GRAFANA_PASSWORD` env vars in `service.yml.elp`
with `GRAFANA_SERVICE_ACCOUNT_TOKEN`.

## Capabilities

mcp-grafana ships tools for: dashboard search/CRUD, datasource listing,
PromQL queries (any Prometheus datasource), LogQL queries (any Loki
datasource), alert-rule inspection, and incident/oncall lookups. The
"is service X healthy?" question typically becomes one or two PromQL
calls plus an alert-rule read.
