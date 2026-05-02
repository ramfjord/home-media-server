# Home Media Server

Yet another self-hosted media server, with a focus on **observability, flexibility, and Infrastructure-as-Code**. Hobby project — see [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas) for a more battle-tested alternative.

> **Setting it up?** See [docs/installation.md](docs/installation.md) for prerequisites, the dev container, deploy target setup, and remote access.

## Philosophy

- **Configuration as Code**: each service lives in `services/<name>/` (a `service.yml` plus any `.elp` templates it owns). `globals.yml` and `config.local.yml` cover the rest.
- **Templated everything**: a Lisp-based renderer (`bin/render`, sources under `lisp/`) turns the per-service definitions into Prometheus configs, Caddy routes, per-service `docker-compose.yml` files, systemd units, and Homer dashboard entries. Templates use ELP, an ERB-style Common Lisp template engine vendored at `elp/`.
- **Systemd-native**: every service is a systemd unit on a shared `mediaserver-network`. A `.path` watcher hot-reloads each service when its config changes; `mediaserver.target` brings the whole stack up or down.
- **Vendor-agnostic monitoring**: OpenTelemetry Collector sits in front of Prometheus/Grafana so the backend can be swapped without restructuring.

## Services

The table below is a map of what's in the repo. Day-to-day, you don't need it — once the stack is up, the **Homer dashboard** at `http://<host>/` is the entry point: it lists every running service, its URL, and its health, so that's where you go to actually use the thing.

Detailed setup notes for individual services live in their own folders under `services/<name>/README.md` where applicable.

| Service | Group | Port | Description |
|---|---|---|---|
| [Radarr](services/radarr/) | downloading | 7878 | Movie discovery and management |
| [Sonarr](services/sonarr/) | downloading | 8989 | TV show discovery and management |
| [Prowlarr](services/prowlarr/) | downloading | 9696 | Indexer manager feeding Radarr/Sonarr |
| [qBittorrent](services/qbittorrent/) | downloading | 8080 | Torrent client (shares WireGuard's netns) |
| [Jellyfin](services/jellyfin/) | streaming | 8096 | Media server with optional GPU transcoding |
| [Vaultwarden](services/vaultwarden/) | security | 8000 | Self-hosted Bitwarden-compatible password manager |
| [Prometheus](services/prometheus/) | monitoring | 9090 | Metrics storage and alerting |
| [OpenTelemetry Collector](services/otelcol/) | monitoring | 8888 | Metrics aggregation hub |
| [Grafana](services/grafana/) | monitoring | 3000 | Dashboards and visualization |
| [Alertmanager](services/alertmanager/) | monitoring | 9093 | Alert routing |
| [cAdvisor](services/cadvisor/) | monitoring | 8081 | Container metrics |
| [node-exporter](services/node-exporter/) | monitoring | 9100 | Host (OS-level) metrics |
| [Blackbox Exporter](services/blackbox-exporter/) | monitoring | 9115 | HTTP/TCP endpoint probes |
| [exportarr-radarr](services/exportarr-radarr/) | monitoring | — | Radarr metrics exporter |
| [exportarr-sonarr](services/exportarr-sonarr/) | monitoring | — | Sonarr metrics exporter |
| [qbittorrent-exporter](services/qbittorrent-exporter/) | monitoring | — | qBittorrent metrics exporter |
| [Homer](services/homer/) | dashboard | 80 | Service-discovery landing page |
| [Caddy](services/caddy/) | dashboard | — | Reverse proxy bridging WireGuard-isolated services and HTTPS for Vaultwarden |
| [WireGuard](services/wireguard/) | vpn | — | VPN tunnel; Radarr/Sonarr/Prowlarr/qBittorrent share its netns via `network_mode: container:wireguard` |

## Networking

Two distinct VPNs:

- **WireGuard** (container) — routes the downloading stack through an external VPN provider for privacy on their outbound traffic.
- **Tailscale** (host) — encrypted remote access to the box from personal devices. No internet-facing ports.

Caddy bridges the two and terminates HTTPS for the few services that require it (e.g. Vaultwarden).

## Storage

- **Hardlinks**: arr apps configured for hardlink moves to avoid duplicate storage.
- **GPU**: Jellyfin can use NVIDIA via `service_overrides` (see `services/jellyfin/README.md`).
- **Persistent data**: lives under `$install_base/config/` (git-ignored).

## More

- [CONTRIBUTING.md](CONTRIBUTING.md) — template conventions, debugging, full make-target list.
- [docs/vs-docker-compose-nas.md](docs/vs-docker-compose-nas.md) — comparison with [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas).

## License

No specific license — adapt freely.
