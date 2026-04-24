# CLAUDE.md

Personal media server using Docker containers and dynamic config generation.

## Network Architecture

Two separate VPN networks:
- **WireGuard/AirVPN** ("The VPN"): Traditional VPN for internet privacy/anonymity
- **Tailscale** ("the tailnet"): Mesh VPN connecting personal devices/servers (fatlaptop, etc.)

Services run on Tailscale. Caddy bridges both networks when needed, exposing ingress from WireGuard to Tailscale services.

## Overview

Services defined in `services.yml`: downloading (Radarr, Sonarr, Prowlarr, qBittorrent), streaming (Plex), monitoring (Prometheus, Alertmanager, Grafana), and dashboard (Homer). All configs are generated from `.erb` templates via `render.rb` and placed in `config/` (git-ignored).

## Configuration

**`services.yml`**: Service definitions with properties:
- `name`, `partof` (objective), `desc`, `port`, `docker_config` (image, volumes, etc.)
- `unit` (systemd unit for non-Docker services like Plex)
- `healthz` (HTTP healthcheck path)

**`config.local.yml`**: Optional overrides for `install_base` (/opt/mediaserver), `media_path` (/data), `hostname`, etc.

## Commands

```bash
make all              # Render all .erb files → config/
make clean            # Remove config/
make check            # Validate prometheus, alertmanager, docker-compose syntax
make install          # Runs make check && make all, then rsync config/ and certs/ to /opt/mediaserver/
```

**Note:** `make install` automatically runs `make check` and `make all`, so you typically only need `make install` rather than running them separately.

## Workflow

1. Edit `services.yml` and/or `config.local.yml`
2. `make all && make check` - Generate and validate configs
3. `make install` - Deploy to system
4. `make deploy-<service>` - Restart a specific service
