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
make all               # Render all .erb files → config/
make clean             # Remove config/
make check             # Validate prometheus, alertmanager, docker-compose syntax
make test              # Run unit tests + golden renderer tests (test/golden_test.rb)
make install           # check + render + rsync config/ and certs/ to $install_base; path units pick up changes
make install-systemd   # rsync unit files + daemon-reload (does NOT enable/start)
make systemd-enable    # enable mediaserver-network, mediaserver.target, and all path units
make systemd-{start,stop,restart,status,disable}
make restart-<service> # force-restart one service (no install)
```

**Note:** `make install` automatically runs `make check` and `make all`. With path units enabled, `make install` is the deploy verb — file changes trigger reload automatically.

### Remote target

`TARGET=local` (default) deploys to this host. `TARGET=<ssh-host>` deploys over ssh — rsync goes to the host, side-effecting commands (`systemctl`, `chown`) run remotely. Persist with a git-ignored `Makefile.local`:

```make
TARGET := fatlaptop
```

## ELP template style

Stack adjacent close-paren-only tags onto a single tag, Lisp-style: prefer `<%- )) -%>` over two consecutive `<%- ) -%>` lines (and `))) ` for three, etc.). The trim semantics are the same and the rendered output is byte-identical, but it reads as the Lisp form it actually is rather than as HTML-like standalone tags.

## Workflow

1. Edit `services/<name>/service.yml`, templates, and/or `config.local.yml`
2. `make install` - Validate, render, deploy; affected services hot-reload via path units
3. `make restart-<service>` - Force-restart if needed (e.g. wedged service)
