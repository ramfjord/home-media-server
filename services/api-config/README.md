# api-config

Reconciles the HTTP-API-driven config of the *arr apps and qBittorrent
to match what's declared in YAML — so settings like "Radarr's download
client is qBittorrent at this URL with this password" live in version
control instead of being clicked through each app's web UI.

Runs as a oneshot on deploy: reads `upstreams.yaml` (which services to
talk to) and `resources.yaml` (what state they should be in), makes the
HTTP calls, and exits.

## Auth-exempt by topology (why it's on mediaserver-network)

api-config sits on `mediaserver-network` and reaches each upstream by
its **`internal_url`** — `http://<name>:<port>` for bridge services,
`http://wireguard:<port>` for VPN-netns ones (the wireguard container
holds their netns and is itself on mediaserver-network, so it's the
same address caddy reverse-proxies to). It deliberately does **not**
go through caddy.

This is load-bearing for the auth gateway. caddy's `forward_auth`
gates the *whole* caddy site for a gated service, so if api-config
reached upstreams via their public URL, gating any of them would 302
api-config to the Authelia portal (httpx doesn't follow redirects →
the reconcile step fails). Going direct bypasses the gate entirely
(forward_auth is caddy-only), so **api-config stays auth-exempt
without any per-path bypass** — that's the whole reason a gated arr /
qBittorrent / Open WebUI doesn't break its reconcile. It was
previously `network_mode: host` + public-URL-through-caddy for
uniformity; the gateway invalidated that calculus. `configure.py`
treats `base_url` as an opaque HTTP base (no TLS pinning), so plain
http to a docker-DNS name needs no cert/FQDN — the host-net rationale
left with it.

## Concurrency model

Each upstream is an independent flow: a coroutine with its own
`httpx.AsyncClient` (isolated cookie jar) that runs healthcheck →
steps → upserts → posts strictly in sequence. All flows run
concurrently, so total runtime is ~max(flow), not sum(flow) — one
unreachable upstream burns its retry budget alongside the others, not
serialized ahead of them. This keeps a few slow/down upstreams from
stacking past the unit's `TimeoutStartSec` (the prior serial design's
failure mode: the oneshot getting killed mid-reconcile, then
`ExecStartPost` no-op'ing on the failed unit until `reset-failed`).

Logs are one line per event, prefixed `[<upstream>]`; reconstruct a
single flow with `grep '\[radarr\]'`. A request that exhausts its
retry budget logs an explicit `ERROR gave up after N attempts / Ns`.

## Failure visibility & attribution

Every line reaches Grafana regardless of outcome: container stdout →
journald under `api-config.service` → Alloy → Loki. configure.py
prefixes a `<N>` syslog level so journald `PRIORITY` is accurate, and
Alloy lifts the `[<upstream>]` prefix into a **`config_target`** label
(service stays `api-config`). Two failure classes, deliberately
attributed differently:

- **Per-upstream reconcile failure** (radarr's PUT 500s after
  retries): exits 0 — the unit does **not** fail. The `[radarr] ERROR
  …` line carries `config_target=radarr`; **`ApiConfigReconcileFailed`**
  `label_replace`s that to `service=radarr`, so Alertmanager threads it
  with radarr's own alerts and the per-service Grafana dashboard's
  "api-config reconcile — radarr" panel shows the relevant lines next
  to radarr's logs. The reconcile engine is fine; *radarr* is the
  problem, so radarr is what's paged.
- **Engine error** (flow-firewall caught an unexpected exception,
  bad `upstreams.yaml`): exits non-zero → unit `failed` →
  `SystemdUnitFailed` + `ServiceLogErrors`, both under
  `service=api-config` (`config_target=api-config`). The reconcile
  engine itself is down.

A failed **healthcheck** is a by-design *skip*, not a failure: its
give-up line carries the `healthcheck:` token and is dropped
pre-counter via `log_metric_exclude_regex` (see `service.yml.elp`), so
it never pages — an unreachable upstream is covered by its own
`TargetDown`/Blackbox — but it still shows in the panel.

## More

- Upstream: <https://github.com/ramfjord/api-config>
