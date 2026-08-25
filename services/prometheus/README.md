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
| `SystemdUnitFailed` | **inert** — node-exporter runs without `--collector.systemd`, so `node_systemd_unit_state` does not exist and this can never fire | [mediaserver.yaml.elp](rules/mediaserver.yaml.elp) |
| `VolumeFillingUp` | `predict_linear` on 24h of `node_filesystem_avail_bytes` projects exhaustion within 5d (won't fire on full-but-stable) | [mediaserver.yaml.elp](rules/mediaserver.yaml.elp) |
| `ServiceLogErrors` | journald error rate for a unit exceeds threshold | [journal.yaml.elp](rules/journal.yaml.elp) |
| `Prometheus*` / `Blackbox*Reload*` | self-monitoring: crashloop, config reload failure | [rules.yaml.elp](rules/rules.yaml.elp) |
| `WireGuardTunnelStale` | no WireGuard handshake in >3m for 5m — tunnel dead, containment now on the killswitch alone (does **not** mean a leak; the killswitch fails closed) | [vpn.yaml.elp](rules/vpn.yaml.elp) |
| `StackStarting` / `ServiceStarting` | **never page** — markers routed to a `null` receiver that Alertmanager uses as inhibition sources to mute restart noise (see [services/alertmanager/README.md](../alertmanager/README.md#settle-windows-muting-restart-noise)) | [settle.yaml.elp](rules/settle.yaml.elp) |

`ServiceLogErrors` counts journald error lines; unit-less kernel noise
buckets under `service=alloy`. Per-host noise (e.g. a flaky NIC) can be
dropped from the counter — without losing it from Loki — via a service's
`log_metric_exclude_regex`; see
[services/alloy/README.md](../alloy/README.md#excluding-log-noise-from-the-error-counter).

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
([blackbox.yml.elp](../blackbox-exporter/blackbox.yml.elp)) for
un-gated services, which
has **no body assertion and no `valid_status_codes` override** —
`probe_success` means only "response was 2xx." (Gated services use
`http_gated` instead — see "Gated services" below.)

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

### Gated services: `http_gated`, where 401 is healthy

A `gateway_protected` service answers an *unauthenticated* public
probe with the auth gateway's challenge, not the service's 2xx.
Authelia returns **401** to a non-browser client (the probe sends no
`Accept: text/html`, so it gets 401, not the browser 302). Under
plain `http_basic` that 401 reads as failure → `BlackboxProbeFailed`
critical → pages, even though the gate working *is* the healthy
state. (This bit prod: gating radarr/sonarr/prowlarr without making
the probe gating-aware paged on every probe.)

So `public_probe_<svc>` selects its module on the derived
`gateway_protected` flag (no service names in the template):
gated → **`http_gated`** (`valid_status_codes:[401]`,
`no_follow_redirects`), un-gated → `http_basic` (2xx). For a gated
service this is *stronger* than the 2xx check: 401 = gate enforced
(healthy); a 200 = gate failed **open** (probe_success=0, pages —
exactly what you want); 5xx/connection-refused = caddy/upstream down
(pages). `internal_probe_<svc>` stays `http_basic` — it bypasses
caddy, so the gate never sees it and it must still be 2xx.

## More

- Upstream: <https://github.com/prometheus/prometheus>
- Docs: <https://prometheus.io/docs/>
- Blackbox module config reference:
  <https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md>
