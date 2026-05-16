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
conditions under which Alertmanager should fire. Prometheus loads
every `rules/*.yaml`. Each file groups related rules by subject.

## Alerts we rely on

This is the load-bearing set — what actually pages, and (just as
important) **what it cannot see**. Keep this current when rules
change; it's the fast-reference both for humans and for agents
deciding "would a regression here be caught?"

| Alert | Fires when | Source |
|---|---|---|
| `TargetDown` | `up == 0` for 5m — Prometheus can't scrape a target at all | [rules.yaml.elp](rules/rules.yaml.elp) |
| `BlackboxProbeFailed` | `probe_success == 0` for 5m — an HTTP probe came back non-2xx | [blackbox.yaml.elp](rules/blackbox.yaml.elp) |
| `BlackboxSslCertificate*` | tailnet cert <20d / <3d / expired | [blackbox.yaml.elp](rules/blackbox.yaml.elp) |
| `SystemdUnitFailed` | a unit stays in `failed` state for ≥5m (level-triggered, not edge — sub-5m flaps don't page) | [mediaserver.yaml.elp](rules/mediaserver.yaml.elp) |
| `VolumeFillingUp` | `predict_linear` on 6h of `node_filesystem_avail_bytes` projects exhaustion within 5d (won't fire on full-but-stable) | [mediaserver.yaml.elp](rules/mediaserver.yaml.elp) |
| `ServiceLogErrors` | journald error rate for a unit exceeds threshold | [journal.yaml.elp](rules/journal.yaml.elp) |
| `Prometheus*` / `Blackbox*Reload*` | self-monitoring: crashloop, config reload failure | [rules.yaml.elp](rules/rules.yaml.elp) |

### The two probe layers

Both built by [scrape_configs.yaml.elp](scrape_configs/scrape_configs.yaml.elp):

- **`internal_probe_<svc>`** — blackbox hits the container directly
  over docker DNS at its `healthz` path. Confirms "the container is
  up and serving." Bypasses caddy entirely. Emitted for every
  dockerized, non-host-networked service with a `healthz`.
- **`public_probe_<svc>`** — blackbox hits the service's
  `public_url` (the caddy-fronted URL Homer's tile links to).
  *Intended* to confirm caddy routing + TLS + auth end-to-end.
  Emitted for every `displayable` service.

### Routing-regression coverage (formerly a blind spot)

`public_probe_<svc>` uses the `http_basic` blackbox module
([blackbox.yml.elp](blackbox.yml.elp)), which has **no body
assertion and no `valid_status_codes` override** — `probe_success`
means only "response was 2xx."

This *used* to be a silent blind spot: Homer was the catch-all at
`/` and, being an SPA, answered **HTTP 200 for any path**. A caddy
matcher/ordering regression that dropped `/radarr` fell through to
Homer's 200, so `public_probe_radarr` stayed green and nothing
fired.

**Closed** in [Caddyfile.elp](../caddy/Caddyfile.elp): Homer is now a
normal path-routed service at `/homer` (no catch-all). Bare `/`
308-redirects to `/homer/` for bookmark convenience, but any path
that matches no service handle hits an explicit terminal
`handle { error 404 }`. (Caddy's *implicit* default for an unhandled
request is an empty 200 — that's why the explicit 404 is required;
removing the catch-all alone would not have closed this.)

Net coverage now: a broken service route → no matching handle →
404 → `probe_success=0` → `BlackboxProbeFailed` after 5m. Homer
itself is also properly probe-covered for the first time (it was the
catch-all before, so its own probe was meaningless). `public_probe`
catches: caddy down, upstream dead (502/503), TLS expiry,
qBittorrent host-header 400, **and now broken/missing routes**. It
still cannot catch a route that points at the *wrong* live 2xx
upstream — body assertion would be needed for that, deferred as
low-value. Note there is intentionally **no golden test covering the
production `Caddyfile.elp`** (the golden suite exercises the render
engine against synthetic fixtures only); the blackbox 404 path is
now the regression detector for caddy routing.

## More

- Upstream: <https://github.com/prometheus/prometheus>
- Docs: <https://prometheus.io/docs/>
- Blackbox module config reference:
  <https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md>
