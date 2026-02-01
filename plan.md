# Mediaserver Monitoring Install Script Plan

## Overview

Create an install script for Debian that sets up:
- User-based systemd units for VPN/downloading services
- Docker-based VPN services (wireguard, radarr, sonarr, prowlarr, qbittorrent)
- Native Plex via apt package (uses system service as-is)
- Prometheus + Alertmanager + exporters via apt
- Configurable media path via gitignored config file

## Architecture

### Users & Services

| User | Services | Type |
|------|----------|------|
| `media-vpn` | wireguard, radarr, sonarr, prowlarr, qbittorrent | Docker containers via user systemd units |
| `plex` (pkg-created) | plexmediaserver | System service from apt package |
| (system) | prometheus, alertmanager, node-exporter, blackbox-exporter | apt packages, system services |

### Service Dependencies

```
docker.service (system)
       │
       ▼
media-stack.service (user: media-vpn)
       │
       └─► docker-compose handles internal ordering:
           wireguard → radarr, sonarr, prowlarr, qbittorrent

plexmediaserver.service (system, from apt package)
```

## Files to Create/Modify

### New Files

1. **`config.local.yml.example`** - Example config (tracked in git)
   ```yaml
   # Copy to config.local.yml and customize
   install_base: /opt/mediaserver
   media_path: /media

   vpn_user: media-vpn
   media_group: media
   ```

   This creates:
   - `/opt/mediaserver/config/{wireguard,radarr,sonarr,prowlarr,qbittorrent}/`
   - `/opt/mediaserver/docker-compose.yml` (symlink to generated file)

2. **`install.sh`** - Main install script with phases:
   - Parse config.local.yml (require it exists)
   - Install apt packages (docker, prometheus, alertmanager, exporters, plex repo)
   - Create media-vpn user and media group
   - Enable lingering for media-vpn user
   - Setup directory structure with proper ownership
   - Generate configs via `make all`
   - Deploy user systemd units
   - Deploy prometheus/alertmanager configs
   - Print next steps

3. **`lib/install_helpers.sh`** - Shared shell functions

4. **`systemd/user/media-stack.service`** - Single user-level unit for the docker stack
   ```ini
   [Unit]
   Description=Media Stack (VPN + Arrs + Torrent)

   [Service]
   Type=simple
   Restart=on-failure
   RestartSec=10
   ExecStartPre=/bin/sh -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
   ExecStart=/usr/bin/docker compose -f /opt/mediaserver/docker-compose.yml up
   ExecStop=/usr/bin/docker compose -f /opt/mediaserver/docker-compose.yml down

   [Install]
   WantedBy=default.target
   ```

   Service dependencies (wireguard → arrs/qbittorrent) handled by docker-compose `depends_on`.


### Files to Modify

1. **`services.yml`**
   - Remove deluge service (replaced by qbittorrent in Docker)
   - Update qbittorrent to be docker-based with `uses_vpn: true`
   - Remove native `unit:` fields for docker services
   - No per-service systemd config needed; single media-stack.service handles all

2. **`render.rb`**
   - Load `config.local.yml` if present, merge over services.yml defaults
   - Expose new variables: `media_path`, `users`, `media_group`
   - Add binding for user template variables

3. **`Makefile`**
   - Add `config.local.yml` as dependency where needed
   - Add targets: `install`, `deploy-user-unit`
   - Update `deploy` target for user unit (single media-stack.service)
   - `deploy` symlinks `docker-compose.yml` to `/opt/mediaserver/docker-compose.yml`

4. **`docker-compose.yml.erb`**
   - Add qbittorrent service with `network_mode: "service:wireguard"`
   - Use `media_path` variable for volume mounts

5. **`.gitignore`**
   - Add `config.local.yml`

## Install Script Phases

```bash
#!/bin/bash
set -euo pipefail

# Phase 1: Validate prerequisites
- Check running as root or with sudo
- Check config.local.yml exists
- Parse config values with yq

# Phase 2: Install system packages
sudo apt update
sudo apt install -y \
    docker.io docker-compose-plugin \
    prometheus prometheus-alertmanager \
    prometheus-node-exporter prometheus-blackbox-exporter \
    yq ruby

# Add Plex repo and install
curl https://downloads.plex.tv/plex-keys/PlexSign.key | sudo gpg --dearmor -o /usr/share/keyrings/plex.gpg
echo "deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" | \
    sudo tee /etc/apt/sources.list.d/plexmediaserver.list
sudo apt update && sudo apt install -y plexmediaserver

# Phase 3: Create users and groups
sudo groupadd -f media
sudo useradd --system --create-home --shell /usr/sbin/nologin -g media media-vpn
sudo usermod -aG docker media-vpn
sudo usermod -aG media plex  # add plex user to media group for shared access
sudo loginctl enable-linger media-vpn

# Phase 4: Setup directories
sudo mkdir -p $MEDIA_PATH/{downloads,movies,tv,music}
sudo chown -R root:media $MEDIA_PATH
sudo chmod -R 775 $MEDIA_PATH

sudo mkdir -p /opt/mediaserver/config/{wireguard,radarr,sonarr,prowlarr,qbittorrent}
sudo chown -R root:media /opt/mediaserver
sudo chmod -R 775 /opt/mediaserver

# Phase 5: Generate and deploy configs
make clean && make all
# Deploy user units to ~/.config/systemd/user/
# Deploy prometheus/alertmanager to /etc/

# Phase 6: Enable services
sudo -u media-vpn XDG_RUNTIME_DIR=/run/user/$(id -u media-vpn) \
    systemctl --user enable media-stack

# Plex uses system service from apt package (already enabled by default)
sudo systemctl enable plexmediaserver
```

## Updated services.yml Structure

```yaml
objectives:
  - downloading
  - streaming
  - monitoring

# Defaults (can be overridden in config.local.yml)
config_base: /config
compose_file: ./docker-compose.yml
media_path: /media

services:
- name: wireguard
  partof: vpn
  desc: VPN gateway
  image: lscr.io/linuxserver/wireguard:latest
  is_vpn_gateway: true

- name: radarr
  partof: downloading
  desc: find movies
  port: 7878
  image: lscr.io/linuxserver/radarr:latest
  uses_vpn: true

- name: sonarr
  partof: downloading
  desc: find new shows
  port: 8989
  image: lscr.io/linuxserver/sonarr:latest
  uses_vpn: true

- name: prowlarr
  partof: downloading
  desc: indexer manager
  port: 9696
  image: lscr.io/linuxserver/prowlarr:latest
  uses_vpn: true

- name: qbittorrent
  partof: downloading
  desc: torrent client
  port: 8080
  image: lscr.io/linuxserver/qbittorrent:latest
  uses_vpn: true

- name: plex
  partof: streaming
  desc: media streaming
  port: 32400
  healthz: /web/index.html
  unit: plexmediaserver  # system service from apt package
```

## Prometheus Scrape Config Updates

The prometheus scrape configs need to handle:
- Native Plex (systemd unit monitoring via systemd-exporter)
- Docker services (container health + HTTP probes)
- All exporters running as system services

## Verification Steps

1. **After install script runs:**
   ```bash
   # Check user created
   id media-vpn

   # Check lingering enabled
   ls /var/lib/systemd/linger/

   # Check docker access
   sudo -u media-vpn docker ps

   # Check plex system service
   systemctl status plexmediaserver
   ```

2. **Check user services:**
   ```bash
   sudo -u media-vpn XDG_RUNTIME_DIR=/run/user/$(id -u media-vpn) \
       systemctl --user status media-stack
   ```

3. **Check monitoring:**
   ```bash
   curl -s localhost:9090/-/healthy  # prometheus
   curl -s localhost:9093/-/healthy  # alertmanager
   curl -s localhost:9100/metrics    # node-exporter
   ```

4. **Check VPN connectivity:**
   ```bash
   # From inside wireguard container
   sudo -u media-vpn docker exec wireguard curl ifconfig.me
   ```

## Notes

- **NVIDIA GPU for Plex**: Native install avoids Docker GPU passthrough complexity
- **User systemd units**: Require `loginctl enable-linger` to run at boot without login
- **XDG_RUNTIME_DIR**: Must be set when running `systemctl --user` as another user
- **Docker socket access**: Users in `docker` group can manage containers
