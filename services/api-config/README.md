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

## Failure visibility

Logs reach Grafana regardless of outcome: container stdout → journald
under `api-config.service` → Alloy relabels to `service=api-config` →
Loki, greppable in the per-service logs panel (filter the single-line
`[<upstream>] ERROR …` records).

Alerting depends on the unit *failing*. `ServiceLogErrors` can't see
this: its `level` comes from journald priority, and a container
streamed through `docker compose` lands at priority *info* whatever the
text says. So the signal is the exit code — the unit runs
`docker compose run --rm` (not `up`, which swallows the container's
exit code), so any `configure.py` non-zero exit (≥1 reconcile failure)
puts the unit in `failed` → `SystemdUnitFailed` (`for: 5m`) → Discord.
Granularity is per-run ("this reconcile failed"), not per-line.

## More

- Upstream: <https://github.com/ramfjord/api-config>
