# Home Media Server

Yet another self-hosted media server setup using Docker Compose, but with a focus on **observability, flexibility, and Infrastructure-as-Code principles**. This is a hobby project with opinionated choices different from similar projects like [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas).

## Philosophy

Rather than providing a rigid, production-optimized setup, this project prioritizes:

- **Configuration as Code**: All service definitions live in `services.yml` — edit one file, regenerate all container configs
- **Monitoring First**: Comprehensive monitoring and alerting stack built-in from the start, designed for experimentation
- **Flexible Observability**: Uses OpenTelemetry Collector as the foundation, allowing you to try different monitoring backends without restructuring everything
- **Dynamic Configuration**: `.erb` templates generate Prometheus configs, Docker Compose files, and service dashboards from a single source of truth

## Services

All services are defined in **`services.yml`** and organized by objective:

### Downloading (Media Acquisition)

- **Radarr** — Movie discovery and management
- **Sonarr** — TV show discovery and management  
- **Prowlarr** — Indexer management and aggregation
- **qBittorrent** — Torrent client (runs through WireGuard VPN)
- **Caddy** — Reverse proxy for VPN services

### Streaming (Media Playback)

- **Plex** — Media server (systemd service, non-Docker)
- **Jellyfin** — Alternative media streaming with GPU acceleration support

### Monitoring & Observability

- **Prometheus** — Metrics collection and time-series database
- **OpenTelemetry Collector** — Metrics aggregation layer (enables experimentation with different backends)
- **Grafana** — Dashboards and visualization
- **Alertmanager** — Alert routing and management
- **cAdvisor** — Container metrics exporter
- **Blackbox Exporter** — HTTP/TCP endpoint probing
- **Exportarr** (Radarr/Sonarr/qBittorrent) — Application-specific metrics exporters

### Dashboard

- **Homer** — Service discovery dashboard (visit `http://host:80` to see all services)
- **WireGuard** — VPN container for secure access

## Getting Started

### Prerequisites

- Docker and Docker Compose V2
- Linux host with `make`, `ruby`, and standard utilities
- A VPN subscription (for routing qBittorrent and indexer traffic)
- Optional: Tailscale for remote access

### Configuration

1. **Review defaults** in `services.yml`
2. **Override** in `config.local.yml`:

   ```yaml
   hostname: myserver.local
   media_path: /mnt/media
   install_base: /opt/mediaserver
   radarr_apikey: "your-key"
   sonarr_apikey: "your-key"
   ```

### Commands

```bash
make all              # Render all .erb templates → config/
make check            # Validate Prometheus, Alertmanager, Docker Compose configs
make install          # rsync config/ to /opt/mediaserver/config/
make deploy-<service> # Stop, reinstall, and restart a specific service
make clean            # Remove generated config/
```

### Workflow

1. Edit `services.yml` or `config.local.yml`
2. Run `make all && make check` to validate
3. Run `make install` to deploy
4. Run `make deploy-plex` (or another service) to restart if needed

## Design Decisions

### vs. docker-compose-nas

**If you don't enjoy configuring and debugging infrastructure**, [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas) is a much more mature, battle-tested solution and is strongly recommended. It just works.

**Similarities**: Both use the "arr" stack (Radarr, Sonarr, Prowlarr) with qBittorrent, WireGuard VPN, and media streaming.

**Key Differences**:

| Aspect | This Project | docker-compose-nas |
|--------|--------------|-------------------|
| **Service Management** | Systemd units per service + Docker | Pure Docker Compose |
| **VPN Isolation** | All download/indexing traffic protected (Radarr, Sonarr, Prowlarr, qBittorrent) | All download/indexing traffic protected (Radarr, Sonarr, Prowlarr, qBittorrent) |
| **Remote Access** | Tailscale (private, encrypted) | Internet-facing (with Traefik + Let's Encrypt) |
| **Streaming** | Plex + Jellyfin option | Jellyfin focused |
| **Reverse Proxy** | Caddy (routes WireGuard-isolated services) | Traefik (internet ingress) |
| **Monitoring** | Metrics + dashboards (Prometheus, Grafana, Alertmanager) | Live dashboard only, no historical metrics |
| **Config Management** | ERB templates + single YAML source | Individual docker-compose files |
| **Observability Layer** | OpenTelemetry Collector (vendor-agnostic) | None |

### Monitoring Philosophy

Rather than shipping with Prometheus as the final destination, we use **OpenTelemetry Collector** as the hub. This allows:

- **Easy backend swaps**: Point metrics to Prometheus, Grafana Cloud, Datadog, New Relic, etc.
- **Vendor independence**: Change decisions without rebuilding the entire stack
- **Experimentation**: Test new monitoring tools without breaking existing alerts

Currently configured to export to local Prometheus and Grafana, but try other backends if interested.

## Storage & Performance

- **Hardlinks**: All "arr" apps are configured for hardlink moves to avoid duplicate storage
- **GPU Acceleration**: Jellyfin supports NVIDIA GPU for transcoding (configure device mappings in `config.local.yml`)
- **Persistent Data**: Prometheus and Grafana data stored in `config/` (git-ignored)

## Architecture: Networking & VPN

This setup uses VPNs in two distinct ways:

- **WireGuard** container: Routes Radarr, Sonarr, Prowlarr, and qBittorrent through a VPN tunnel for privacy/anonymity on their external traffic
- **Caddy** reverse proxy: Required to expose these WireGuard-routed services (which live on the VPN network interface) to the rest of your services
- **Tailscale**: Provides secure remote access to your entire server — access the Homer dashboard and all services from anywhere without exposing ports to the internet. Traffic is encrypted end-to-end.

Notably, **HTTPS is not needed** on Caddy since all remote access goes through Tailscale's encrypted tunnel.

## Contributing

This is a hobby project, but improvements and additions are welcome. Some potential extensions:

- Lidarr (music management)
- FlareSolverr (bypass Cloudflare)
- AdGuard Home (DNS filtering)
- Additional exporters (system, network, etc.)

## License

No specific license — feel free to adapt for your own use.
