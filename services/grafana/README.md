# Grafana

Visualization layer for the stack: dashboards over Prometheus metrics
and Loki logs, plus the UI for browsing alerts. This is where you go
to see graphs of how the server is behaving.

`provisioning/` holds datasource and dashboard definitions that
Grafana loads on startup — so dashboards are version-controlled here
rather than clicked together in the UI and lost when the volume is
wiped.

## Auth: gated + anonymous Viewer, no stored secret

Grafana has **no `admin_password` in `config.local.yml`**. Three env
settings replace it:

- `gateway_auth: true` → Caddy fronts `/grafana` with Authelia
  forward-auth. Humans authenticate with the same SSO as everything
  else; there is no Grafana login of their own.
- `GF_AUTH_ANONYMOUS_ENABLED=true` + `ORG_ROLE=Viewer` → past
  Authelia, the request is an anonymous **Viewer**. Dashboards and
  datasource queries are read-only by everyone; nobody needs a Grafana
  account. `mcp-grafana` uses this same path over internal DNS
  (`--disable-write`, so Viewer is exactly its needed privilege — it
  no longer holds admin credentials).
- `GF_AUTH_DISABLE_LOGIN_FORM=true` → the built-in `admin` account
  still exists but cannot be logged into via the UI, so the unset
  default credential is not usable by anything that can reach
  `grafana:3000` on the internal network.

Trade made deliberately: Grafana leaves the "monitoring un-gated for
break-glass" set (Prometheus/Alertmanager stay in it). It's a UI, not
a break-glass surface — debugging a gateway incident is Prometheus +
`ssh journalctl -u caddy -u authelia`, not Grafana. Note Loki has no
UI of its own, so **log browsing is unavailable during a gateway
outage**; that is the accepted cost.

### Break-glass admin

No stored admin password means recovering real admin is a runbook
step, not a lookup:

```sh
ssh <host>
docker exec -it grafana grafana cli admin reset-admin-password <temp>
# then, to actually log in, temporarily flip GF_AUTH_DISABLE_LOGIN_FORM
# to false (service_overrides.grafana) + redeploy, or use the HTTP API
# with the reset password. Revert the override afterwards.
```

You rarely need this: datasources and dashboards are provisioned
as code, so day-to-day there is nothing to do in the UI as admin.

## More

- Upstream: <https://github.com/grafana/grafana>
- Docs: <https://grafana.com/docs/grafana/latest/>
