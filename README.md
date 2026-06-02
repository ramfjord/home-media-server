# Home Media Server

A templated self-hosted media server stack — Jellyfin + the arr suite + first-class monitoring — generated from per-service YAML manifests by a Lisp template engine and deployed as systemd units to a single Debian host. Caddy fronts everything under one cert, Prometheus + Grafana + Loki are wired in by default, alerts go to Discord, and `make install` does the deploy.

The arr ↔ qBittorrent ↔ Prowlarr API integration is declared in YAML and reconciled by a sidecar — no clicking through Settings → Download Clients → Add per app.

**Looking for a stack to copy and run as-is?** [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas) is more battle-tested for that.

**Looking for a reference architecture** for templated, observability-first home infrastructure? Read on.

> **Setting it up?** See [docs/installation.md](docs/installation.md) for prerequisites, the dev container, deploy target setup, and remote access.

## Philosophy

- **Configuration as Code**: each service lives in `services/<name>/` (a `service.yml.elp` plus any `.elp` templates it owns). `config.local.yml` covers per-host overrides.
- **Templated everything**: a Lisp-based renderer (`bin/render`, sources under `lisp/`) turns the per-service definitions into Prometheus configs, Caddy routes, per-service `docker-compose.yml` files, systemd units, and Homer dashboard entries. Templates use ELP, an ERB-style Common Lisp template engine vendored at `elp/`.
- **Systemd-native**: every service is a systemd unit on a shared `mediaserver-network`. A `.path` watcher hot-reloads each service when its config changes; `mediaserver.target` brings the whole stack up or down.
- **Observability built-in**: every service is scraped by Prometheus directly; Alloy ships journald logs to Loki; alerts route via Alertmanager → Discord.

## Architecture: render → stage → deploy

A change goes through four stages, and **what each stage can see** is the constraint that determines what kind of fact belongs where:

1. **Build the service manifest.** `bin/build-service-config` reads every `services/*/service.yml.elp`, layers `config.local.yml` on top of built-in defaults, and computes derived fields (`compose_file`, `dockerized`, `config_files`, …) into `services/manifest.yaml`. Each `service.yml.elp` is read in isolation — at this stage a service can't reference another service's fields. (The `.elp` suffix is purely an editor signal: these files are parsed as YAML with `<%= %>` tags carried verbatim into the manifest, then resolved in stage 2 with full cross-service scope.)
2. **Render templates → `config/`.** `make all` runs `bin/render` against `services/manifest.yaml` for every `.elp` under `services/` (per-service templates, excluding `service.yml.elp` which is input data) and `targets/debian/` (singletons + `__service__` fanout templates). Static files in `services/` and `targets/debian/` are rsynced through unchanged. The full manifest is in scope here, so templates *can* see other services — this is where cross-service config (Caddy routes, Prometheus scrape configs, Homer entries) gets assembled. Two manifest files are emitted alongside the output: `config/.manifest` and `config/systemd/.mediaserver.manifest`, listing every shipped file.
3. **Sync local → target staging.** `make sync` rsyncs `config/` to `$TARGET:/opt/mediaserver/staging/` with `--delete`. Staging is fully owned by the deploy and rebuilt every time, so deleting is safe. Nothing user-facing has moved yet.
4. **Stage → prod on the target.** `make install` runs `make deploy` on the target: it diffs the freshly-shipped `.manifest` against the previously-installed one to compute exactly which files this deploy removes, rsyncs staging into the live install dirs (`/opt/mediaserver/config/`, `/etc/systemd/system/`, and `/etc/`) **without** `--delete`, then explicitly `rm`s the diffed-out files and runs `daemon-reload`. Path units pick up changes under `/opt/mediaserver/config/`; per-file rules under `/etc/` fire targeted reloads (e.g. `/etc/docker/daemon.json` triggers a docker restart + container recreate) only when content actually changed.

Two consequences worth keeping in mind:

- **Where a fact can live** follows from stage 1 vs. stage 2. Anything that needs to know about other services has to be computed in a template (stage 2) or as a derived field in `lisp/src/derive.lisp` (stage 1, but with the full set in scope) — not in raw `service.yml.elp`.
- **Removal requires `make clean`** before deploy. Stages 1–2 are incremental; if you delete a service or template, stale rendered files still sit in `config/` until you clean. They'd then ship to staging (good — the new manifest wouldn't list them), but only stage 4's manifest diff actually removes them from prod, and the diff is only correct if `config/` was regenerated from scratch. (See [CONTRIBUTING.md](CONTRIBUTING.md#removing-a-service-or-template).)

Derived fields and the manifest are also useful debugging surface: when a value looks wrong in a rendered file, `services/manifest.yaml` is the single place to confirm what the renderer actually saw.

## Services

The table below is a map of what's in the repo. Day-to-day, you don't need it — once the stack is up, the **Homer dashboard** at `http://<host>/` is the entry point: it lists every running service, its URL, and its health, so that's where you go to actually use the thing.

Detailed setup notes for individual services live in their own folders under `services/<name>/README.md` where applicable.

Every web UI is reached at `https://<tailnet-fqdn>/<path>`, with caddy fronting the lot under one cert. Plain `/` lands on the Homer dashboard.

| Service | Group | Path | Description |
|---|---|---|---|
| [Radarr](services/radarr/) | downloading | `/radarr` | Movie discovery and management |
| [Sonarr](services/sonarr/) | downloading | `/sonarr` | TV show discovery and management |
| [Prowlarr](services/prowlarr/) | downloading | `/prowlarr` | Indexer manager feeding Radarr/Sonarr |
| [qBittorrent](services/qbittorrent/) | downloading | `/qbittorrent` | Torrent client (shares WireGuard's netns) |
| [Jellyfin](services/jellyfin/) | streaming | `/jellyfin` | Media server with optional GPU transcoding |
| [Plex](services/plex/) | streaming | `:32400` | Media server, internet-reachable for remote TV clients (plex.tv remote access) |
| [Vaultwarden](services/vaultwarden/) | security | `/vaultwarden` | Self-hosted Bitwarden-compatible password manager |
| [Authelia](services/authelia/) | security | `:9091` | Single sign-on / forward-auth portal for the gated web UIs |
| [Ollama](services/ollama/) | llm | — | Local LLM server (HTTP API on `:11434`, optional GPU) |
| [Open WebUI](services/open-webui/) | llm | `:8002` | Chat UI for Ollama |
| [mcp-grafana](services/mcp-grafana/) | llm | — | Grafana MCP server (dashboards + PromQL + LogQL tools for the LLM) |
| [mcpo](services/mcpo/) | llm | — | MCP→OpenAPI bridge so Open WebUI can call mcp-grafana |
| [Prometheus](services/prometheus/) | monitoring | `/prometheus` | Metrics storage and alerting |
| [Grafana](services/grafana/) | monitoring | `/grafana` | Dashboards and visualization |
| [Alertmanager](services/alertmanager/) | monitoring | `/alertmanager` | Alert routing (Discord webhook + SMTP) |
| [Loki](services/loki/) | monitoring | — | Log aggregation backend (queried via Grafana) |
| [Alloy](services/alloy/) | monitoring | — | Ships journald → Loki + per-unit error metrics to Prometheus |
| [cAdvisor](services/cadvisor/) | monitoring | `/cadvisor` | Container metrics |
| [node-exporter](services/node-exporter/) | monitoring | — | Host (OS-level) metrics |
| [Blackbox Exporter](services/blackbox-exporter/) | monitoring | `/blackbox-exporter` | HTTP/TCP endpoint probes |
| [exportarr-radarr](services/exportarr-radarr/) | monitoring | — | Radarr metrics exporter |
| [exportarr-sonarr](services/exportarr-sonarr/) | monitoring | — | Sonarr metrics exporter |
| [qbittorrent-exporter](services/qbittorrent-exporter/) | monitoring | — | qBittorrent metrics exporter |
| [wireguard-exporter](services/wireguard-exporter/) | monitoring | — | WireGuard tunnel metrics (handshake, per-peer transfer) |
| [Homer](services/homer/) | dashboard | `/` | Service-discovery landing page |
| [Caddy](services/caddy/) | dashboard | — | TLS terminator + reverse proxy for everything above |
| [api-config](services/api-config/) | dashboard | — | Reconciles Servarr/qBittorrent API config from declared YAML |
| [SMTP](services/smtp/) | infra | — | Postfix relay forwarding outbound mail to upstream provider |
| [WireGuard](services/wireguard/) | vpn | — | VPN tunnel; Radarr/Sonarr/Prowlarr/qBittorrent share its netns via `network_mode: container:wireguard` |

## Networking

Two distinct VPNs:

- **WireGuard** (container) — routes the downloading stack through an external VPN provider for privacy on their outbound traffic.
- **Tailscale** (host) — encrypted remote access to the box from personal devices. No internet-facing ports.

Caddy is the single HTTPS front door — it terminates TLS for every service and reverse-proxies them under their `/<name>` path. The cert (issued by `tailscale cert` for the host's tailnet FQDN) is renewed automatically by a systemd timer; see [docs/installation.md](docs/installation.md).

## Storage

- **Hardlinks**: arr apps configured for hardlink moves to avoid duplicate storage.
- **GPU**: Jellyfin can use NVIDIA via `service_overrides` (see `services/jellyfin/README.md`).
- **Persistent data**: lives under `$install_base/config/` (git-ignored).

## More

- [CONTRIBUTING.md](CONTRIBUTING.md) — template conventions, debugging, full make-target list.
- [docs/vs-docker-compose-nas.md](docs/vs-docker-compose-nas.md) — comparison with [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas).

## License

No specific license — adapt freely.
