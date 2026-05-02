# Installation

## Prerequisites

- **An old gaming laptop** (or any spare machine) to run your media server on, with Linux installed. Once it's set up, you won't interact with it much — it can live in your closet plugged into ethernet. Needs Docker + Docker Compose V2 installed.
- **A WireGuard VPN subscription** (Mullvad, ProtonVPN, etc.) so the downloading stack tunnels through it. See [services/wireguard/README.md](../services/wireguard/) for setup.
- **Docker on a control machine** — the laptop/desktop you'll use to deploy from. Windows, macOS, or Linux all work; the rest of the build tooling (SBCL, qlot, etc.) runs inside a dev container, so Docker is the only thing you install on this machine. See [Run via the dev container](#run-via-the-dev-container) below.
- **Recommended: [Tailscale](https://tailscale.com/)** on the server and on any device you want to reach it from. See [Remote access](#remote-access) below.

If you'd rather skip the dev container and install the build tools natively on your control machine, the root `Dockerfile` is the canonical list of what to install (SBCL, libyaml, qlot, plus rsync/ssh for `make install`). Faster inner loop; one more thing to maintain.

## Run via the dev container

Lets you do everything from a Windows or macOS machine with only Docker installed, deploying to your Linux server over SSH.

On your control machine, clone the repo and drop into the dev shell:

```bash
git clone https://github.com/ramfjord/home-media-server.git
cd home-media-server
docker compose run --rm dev
```

First run pulls the prebuilt image from `ghcr.io/ramfjord/home-media-server-dev` (~30 seconds); subsequent runs are instant. You're dropped into a bash shell inside the container with the repo bind-mounted at the same absolute path it has on the host — so `pwd` reads identically on both sides, and paths in error messages and tooling line up. From there, the standard workflow works as documented below — `make install`, `make restart-<service>`, etc.

For subsequent shells while the container is up, Docker Desktop's GUI has an "Exec" button on each running container that opens a terminal directly — no need to retype the compose command.

**SSH keys.** The container reaches your `TARGET` over SSH using your host's `~/.ssh`, mounted read-only. If your SSH directory lives somewhere else (common on Windows), set `SSH_DIR` in a `.env` file at the repo root, e.g. `SSH_DIR=C:\Users\<you>\.ssh`.

`./.devhome/` (gitignored) holds in-container shell history, vim state, qlot caches, etc., and persists across `docker compose run` invocations.

## Configure

1. Copy `config.local.yml.example` → `config.local.yml` and set at least `hostname`, `media_path`, and `install_base`.
2. Override any service field via `service_overrides:` (deep-merged into that service's `service.yml`).
3. See [services/wireguard/README.md](../services/wireguard/) for one-time VPN setup, and [services/radarr/README.md](../services/radarr/) for the API-key bootstrap.

## Commands

```bash
make install           # check + render + rsync to $install_base, path units pick up changes
make restart-<service> # force-restart one service (no install)
make clean             # remove generated config/
```

Drive the stack via systemd (locally or via `make systemctl-{start,stop,status,enable,disable}`):

```bash
systemctl start mediaserver.target
systemctl stop  mediaserver.target
systemctl status <service>
```

Editing files under `$install_base/config/<service>/` triggers a reload via that service's `.path` watcher — no manual restart needed.

## Deploy target

`TARGET` is mandatory — `make install` and the systemd targets always act on a remote host over ssh (typically across Tailscale). Set it inline:

```bash
TARGET=myhost make install
```

Or persist it in a git-ignored `Makefile.local`:

```make
TARGET := myhost
```

Three things need to be true on the target before the first `make install`:

**Your SSH key is authorized.** From your control machine (or inside the dev container — your `~/.ssh` is already mounted):

```bash
ssh-copy-id <user>@<target>
```

**Passwordless sudo for that same user.** On the target, `sudo visudo` and add:

```
<user> ALL=(ALL) NOPASSWD: ALL
```

(Or scope tighter to `/usr/bin/rsync, /usr/bin/systemctl, /usr/bin/make` if you prefer.)

**`script/install-host-config.sh` has been run against it** — one-time, lays down `/etc/sysctl.d/` and `/etc/docker/daemon.json`:

```bash
script/install-host-config.sh <target>
```

## First install

Once everything above is in place — Linux + Docker on the server, SSH key authorized, passwordless sudo set up, `TARGET` set in `Makefile.local`, `config.local.yml` filled in — bring the stack up:

1. `make install` — renders configs and rsyncs them to the target.
2. `make systemctl-enable` — enables the mediaserver systemd network and target plus the per-service path watchers, and starts the network.
3. `make systemctl-start` — brings the whole stack up.
4. Open `http://<target>/` in a browser (use the Tailscale hostname if you set Tailscale up). The Homer dashboard lists every running service — click into Jellyfin, Radarr, etc. to start configuring them via their own UIs.

If a service doesn't show up or shows red on Homer, `make systemctl-status` gives a per-service active/inactive table.

## Day-to-day workflow

1. Edit `services/<name>/service.yml`, its templates, or `config.local.yml`
2. `make install`
3. Affected services hot-reload via path units; use `make restart-<service>` to force a bounce.

## Remote access

The deploy target has no internet-facing ports — by design. To reach it from outside your home network (or even from the couch without thinking about local IPs), install [Tailscale](https://tailscale.com/) on the server and on every device you want to connect from — phone, laptop, work computer. Each device gets a stable hostname on a private encrypted network; once installed, your server is reachable at that hostname from any of them, anywhere, with no port forwarding or DNS setup.

## Appendix: First-time setup

If you already have Linux on your server and Docker on your control machine, you can skip this section. Otherwise, here are the links — pick whichever distro/tool you like.

### Installing Linux on your old gaming laptop

Every service in this stack runs in Docker and is supervised by systemd, so the distro choice is open as long as it ships systemd (most mainstream desktop distros do — Ubuntu, Mint, Debian, Fedora, etc.). On the server itself you'll then need to install Docker, and probably [Tailscale](https://tailscale.com/) for remote access.

You'll need a USB stick (8GB or larger) to write the installer onto.

- [Ubuntu Desktop install guide](https://ubuntu.com/tutorials/install-ubuntu-desktop)
- [Linux Mint install guide](https://linuxmint-installation-guide.readthedocs.io/)
- [Debian install guide](https://www.debian.org/releases/stable/installmanual)
- [balenaEtcher](https://etcher.balena.io/) — cross-platform USB writer
- [Rufus](https://rufus.ie/) — Windows-only USB writer

### Installing Docker

- [Docker Desktop on Windows](https://docs.docker.com/desktop/install/windows-install/)
- [Docker Desktop on macOS](https://docs.docker.com/desktop/install/mac-install/)
- [Docker Engine on Linux](https://docs.docker.com/engine/install/) — for the server itself
