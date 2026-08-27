# Grafana

Visualization layer for the stack: dashboards over Prometheus metrics
and Loki logs, plus the UI for browsing alerts. This is where you go
to see graphs of how the server is behaving.

`provisioning/` holds datasource and dashboard definitions that
Grafana loads on startup — so dashboards are version-controlled here
rather than clicked together in the UI and lost when the volume is
wiped.

## Stack Health dashboard

`provisioning/dashboards/health.json.elp` (uid `stack-health`) is the
one-screen answer to "is anything broken". One row per service, sorted
by how many alert episodes it produced over the dashboard's time range.

- **Episodes** is `changes(ALERTS_FOR_STATE[$__range])`, not
  `count_over_time(ALERTS)`. It counts how many times an alert *started*,
  so an alert stuck for a day counts once rather than 288 times.
  Prometheus retention is 15d, so that is the longest usable range.
- `ServiceStarting` / `StackStarting` are excluded everywhere on this
  dashboard. They fire on every restart by design (they exist only as
  inhibition sources) and otherwise dominate every count.
- Rows are restricted to a service-name regex rendered from the
  manifest plus the host units that carry a `service` label
  (`docker`, `operating-system`, `mediaserver-network`,
  `tailscale-cert`, `tailscale-dns-ready`). Without it, `service` label
  values left behind by throwaway containers and removed services
  persist for the full retention window and render as blank rows.

**The columns do not cover the same services, and that is not a bug.**
`Unit` covers all 35 units; `Health` covers dockerized services but
reads `n/a` for the ~23 images that declare no HEALTHCHECK; `Up` covers
only scraped services (21); `Probe` only proxied web UIs (16). Blank
and `n/a` mean *not measured*, never *healthy* — do not read a row of
greens plus blanks as a clean bill of health.

Clicking a service name offers its logs (the Service dashboard), its
alert history in Prometheus, and its cAdvisor page. `Firing` links to
Alertmanager filtered to that service and to active alerts only
(`silenced=false&inhibited=false&muted=false&active=true`) — note that
an alert can be firing in Prometheus while inhibited or silenced in
Alertmanager, in which case that page is legitimately empty.

**Links leaving Grafana must be absolute**, and are built from the
target service's `public_url`. `GF_SERVER_SERVE_FROM_SUB_PATH=true`
makes Grafana's app sub-path `/grafana`, and Grafana prepends it to any
data link starting with `/` — so a relative `/alertmanager/…` resolves
to `/grafana/alertmanager/…` and 404s. Grafana-internal links are the
exception: `/d/service` is relative on purpose, because that prepend is
what makes it correct.

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
