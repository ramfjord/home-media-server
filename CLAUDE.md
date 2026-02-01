# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a personal media server automation project for managing a home entertainment system using Docker containers and systemd services. The system orchestrates several services:

- **Downloading**: Radarr (movies), Sonarr (TV shows), Prowlarr (indexer management), qBittorrent (torrent client)
- **Streaming**: Plex Media Server
- **VPN**: WireGuard gateway for privacy-sensitive services
- **Monitoring**: Prometheus + Alertmanager for alerting and health monitoring

The key architectural pattern is **dynamic configuration generation via ERB templating**, where:
- `services.yml` defines all services and their properties
- `config.local.yml` provides local overrides
- `render.rb` (a Ruby script) processes `.erb` template files using these configs
- Generated files are tracked in `.gitignore` and deployed to the system

## Common Commands

### Build and Generate Configurations
```bash
make all          # Generate all .erb files (docker-compose.yml, prometheus configs, etc.)
make clean        # Remove all generated files
```

### Validate Configurations
```bash
make check        # Validate prometheus.yml and alertmanager.yml syntax
```

### Deploy to System
```bash
sudo make deploy       # Deploy and reload prometheus, alertmanager, and systemd configs
sudo make deploy-compose  # Symlink docker-compose.yml to /opt/mediaserver
```

### Manage .gitignore
```bash
make gitignore    # Update .gitignore with auto-generated files (runs as part of `make all`)
```

## Configuration

### Primary Configuration File: `services.yml`
This YAML file defines all services and their properties. Each service entry includes:
- `name`: Service identifier (used in docker-compose, container names)
- `partof`: Grouping category (downloading, streaming, vpn, monitoring)
- `desc`: Human-readable description
- `port`: Exposed port (used to expose VPN-dependent services through WireGuard)
- `image`: Docker image reference
- `is_vpn_gateway`: Boolean indicating this is the VPN gateway (WireGuard)
- `uses_vpn`: Boolean indicating service should route through VPN gateway
- `volumes`: List of volume mounts (supports `${install_base}` and `${media_path}` variable substitution)
- `unit`: Optional systemd unit name (for host-based services like Plex)
- `healthz`: Optional HTTP healthcheck path

### Local Configuration: `config.local.yml`
Override defaults set in `services.yml`. Common overrides:
- `install_base`: Base directory for service configs (default: `/opt/mediaserver`)
- `media_path`: Directory for media files (default: `/data`)
- `vpn_user`: User running VPN services (default: `media-vpn`)
- `media_group`: Group for shared media access (default: `media`)

**Note**: `config.local.yml` is git-ignored and not committed.

## Architecture and File Structure

### Templates and Generation

The `render.rb` script processes all `.erb` files:

1. **`docker-compose.yml.erb`** → **`docker-compose.yml`**
   - Generates docker-compose service definitions
   - Uses variables: `vpn_gateway`, `vpn_services`, other services from `services.yml`
   - WireGuard is the network gateway; VPN-using services attach via `network_mode: "service:wireguard"`
   - Port mappings are exposed only through WireGuard

2. **Prometheus configs**:
   - `prometheus/prometheus.yml.erb` → `prometheus/prometheus.yml`
   - `prometheus/scrape_configs/*.yaml.erb` → `prometheus/scrape_configs/*.yaml`
   - `prometheus/rules/*.yaml.erb` → `prometheus/rules/*.yaml`
   - Uses service metadata (names, ports, unit names) to configure scrape targets and alert rules

3. **Alertmanager configs**:
   - `alertmanager/alertmanager.yml`
   - `alertmanager/templates/*` (alert notification templates)

4. **Systemd user services**:
   - `systemd/user/media-stack.service.erb` → deployed to `$HOME/.config/systemd/user/`
   - Runs docker-compose as a systemd user service

### Template Variables Available in ERB Files

When rendering `.erb` files via `render.rb`, these variables are available:
- `services`: Array of all service definitions
- `service`: Single service (if `SERVICE_NAME` env var is set)
- `vpn_gateway`: The service with `is_vpn_gateway: true`
- `vpn_services`: Array of services with `uses_vpn: true`
- `install_base`: Base install directory (from config)
- `media_path`: Media directory path (from config)

## Installation and Deployment

The `install.sh` script is the primary deployment mechanism:

1. Validates prerequisites (root access, `config.local.yml`)
2. Installs system packages (docker, prometheus, yq, ruby)
3. Creates users and groups
4. Sets up directory structure with proper permissions
5. Generates and deploys all configurations via `make`
6. Enables systemd services

To deploy: `sudo ./install.sh`

## Development Workflow

1. **Modify service definitions**: Edit `services.yml`
2. **Set local overrides**: Edit `config.local.yml` (e.g., custom `install_base`)
3. **Update templates**: Edit `.erb` files to generate new/modified configs
4. **Generate and test**: Run `make all` and `make check` to validate
5. **Deploy**: Run `sudo make deploy` (or full `sudo ./install.sh` for first setup)

## Monitoring

- **Prometheus**: Scrapes metrics from node exporters, systemd exporter, and service health checks
- **Alertmanager**: Sends alerts based on Prometheus rules
- **Blackbox exporter**: Probes service health via HTTP endpoints

Alert rules and scrape configs are defined in `.yaml.erb` files in `prometheus/rules/` and `prometheus/scrape_configs/`.
