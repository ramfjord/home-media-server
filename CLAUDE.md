# CLAUDE.md

Personal media server using Docker containers and dynamic config generation.

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
make install          # rsync config/ to /opt/mediaserver/config/
make deploy-<service> # Stop service, run install, restart service
```

## Workflow

1. Edit `services.yml` and/or `config.local.yml`
2. `make all && make check` - Generate and validate configs
3. `make install` - Deploy to system
4. `make deploy-<service>` - Restart a specific service
