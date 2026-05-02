# Home Media Server

Yet another self-hosted media server, with a focus on **observability, flexibility, and Infrastructure-as-Code**. Hobby project — see [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas) for a more battle-tested alternative.

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

## Getting Started

### Prerequisites

- **An old gaming laptop** (or any spare machine) to run your media server on, with Linux installed. Once it's set up, you won't interact with it much — it can live in your closet plugged into ethernet. Needs Docker + Docker Compose V2 installed.
- **A WireGuard VPN subscription** (Mullvad, ProtonVPN, etc.) so the downloading stack tunnels through it. See [services/wireguard/README.md](services/wireguard/) for setup.
- **Docker on a control machine** — the laptop/desktop you'll use to deploy from. Windows, macOS, or Linux all work; the rest of the build tooling (SBCL, qlot, etc.) runs inside a dev container, so Docker is the only thing you install on this machine. See [Run via the dev container](#run-via-the-dev-container) below.
- **Recommended: [Tailscale](https://tailscale.com/)** on the server and on any device you want to reach it from. See [Remote access](#remote-access) below.

If you'd rather skip the dev container and install the build tools natively on your control machine, the root `Dockerfile` is the canonical list of what to install (SBCL, libyaml, qlot, plus rsync/ssh for `make install`). Faster inner loop; one more thing to maintain.

### Run via the dev container

Lets you do everything from a Windows or macOS machine with only Docker installed, deploying to your Linux server over SSH.

```bash
docker compose run --rm dev
```

First run pulls the prebuilt image from `ghcr.io/ramfjord/home-media-server-dev` (~30 seconds); subsequent runs are instant. You're dropped into a bash shell inside the container with the repo bind-mounted at `/workspace`. From there, the standard workflow works as documented below — `make install`, `make restart-<service>`, etc.

**SSH keys.** The container needs to reach your `TARGET` over SSH. By default it bind-mounts your host's `~/.ssh` read-only.

- **Linux/macOS**: works out of the box.
- **Windows (WSL2 shell)**: works out of the box if your repo and SSH keys live inside WSL.
- **Windows (PowerShell)**: set `SSH_DIR` in a `.env` file at the repo root, e.g. `SSH_DIR=C:\Users\<you>\.ssh`.

**File ownership.** The container runs as UID/GID `1000:1000` by default. If your host UID differs (`id -u`), create a `.env` file at the repo root with `UID=...` / `GID=...` so files written to the workspace stay owned by you. (No-op on Windows.)

`./.devhome/` (gitignored) holds in-container shell history, vim state, qlot caches, etc., and persists across `docker compose run` invocations.

### Configure

1. Copy `config.local.yml.example` → `config.local.yml` and set at least `hostname`, `media_path`, and `install_base`.
2. Override any service field via `service_overrides:` (deep-merged into that service's `service.yml`).
3. See `services/wireguard/README.md` for one-time VPN setup, and `services/radarr/README.md` for the API-key bootstrap.

### Commands

```bash
make install           # check + render + rsync to $install_base, path units pick up changes
make restart-<service> # force-restart one service (no install)
make clean             # remove generated config/
```

Drive the stack via systemd (locally or via `make systemd-{start,stop,status,enable,disable}`):

```bash
systemctl start mediaserver.target
systemctl stop  mediaserver.target
systemctl status <service>
```

Editing files under `$install_base/config/<service>/` triggers a reload via that service's `.path` watcher — no manual restart needed.

### Deploy target

`TARGET` is mandatory — `make install` and the systemd targets always act on a remote host over ssh (typically across Tailscale). Set it inline:

```bash
TARGET=myhost make install
```

Or persist it in a git-ignored `Makefile.local`:

```make
TARGET := myhost
```

The target host needs passwordless sudo for `rsync` and `systemctl`, and `script/install-host-config.sh <target>` must have been run against it to lay down `/etc/sysctl.d/` and `/etc/docker/daemon.json`.

### Day-to-day workflow

1. Edit `services/<name>/service.yml`, its templates, or `config.local.yml`
2. `make install`
3. Affected services hot-reload via path units; use `make restart-<service>` to force a bounce.

## Remote access

The deploy target has no internet-facing ports — by design. To reach it from outside your home network (or even from the couch without thinking about local IPs), install [Tailscale](https://tailscale.com/) on the server and on every device you want to connect from — phone, laptop, work computer. Each device gets a stable hostname on a private encrypted network; once installed, your server is reachable at that hostname from any of them, anywhere, with no port forwarding or DNS setup.

The free plan covers up to 100 devices, which is plenty for personal use.

The same tailnet is what your control machine uses to reach the deploy target via `make install` — set `TARGET=<your-server-tailscale-name>` in `Makefile.local` and SSH/rsync just work.

## Storage

- **Hardlinks**: arr apps configured for hardlink moves to avoid duplicate storage.
- **GPU**: Jellyfin can use NVIDIA via `service_overrides` (see `services/jellyfin/README.md`).
- **Persistent data**: lives under `$install_base/config/` (git-ignored).

## More

- [CONTRIBUTING.md](CONTRIBUTING.md) — template conventions, debugging, full make-target list.
- [docs/vs-docker-compose-nas.md](docs/vs-docker-compose-nas.md) — comparison with [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas).

## License

No specific license — adapt freely.
