# host/

Host-level config files that target `/etc/` on a deploy host.
Installed by `script/install-host-config.sh <target>`, separate from
`make install` (which handles per-service config under
`/opt/mediaserver/`).

Layout mirrors the on-host paths under `/etc/`:

- `etc/sysctl.d/*.conf` → `/etc/sysctl.d/`, reload via `sysctl --system`
- `etc/docker/daemon.json` → `/etc/docker/`, reload via `systemctl restart docker`

Files here are intentionally Debian-specific. At the NixOS cutover
(`plans/nixos-target.md`) they become Nix module config and this
directory goes away.
