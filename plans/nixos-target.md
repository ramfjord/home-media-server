# NixOS as a render target

Rough plan. Not scheduled. Assumes the per-service restructure (`PLAN.md`)
has landed — in particular Phase 3 (per-service dirs) and Phase 5
(declarative `systemd:` shorthand), which make per-service Nix emission
straightforward.

## Why

Two concrete wins that the current Debian + systemd + docker-compose target
doesn't give us:

1. **Atomic kernel/driver rollback.** The Debian kernel-upgrade incident
   (ethernet + graphics borked until manual `linux-image-amd64` +
   dkms + grub dance) is exactly the class of failure NixOS generations +
   bootloader rollback eliminate. Boot previous generation, done.
2. **Portable hardware migration.** Same `services.yml` → different box
   with different GPU vendor, different NIC, different kernel. Swap a
   couple of `host.yml` lines, `nixos-rebuild switch`, go. No multi-day
   apt/dkms/driver rebuild.

Adjacent win: kernel version, firmware, GPU driver become part of the same
declarative config as the services themselves. One source of truth.

## Non-goals

- **Not** adopting NixOS as a platform beyond this stack. Only emitting
  enough surface-level Nix to define services, systemd units, containers,
  kernel, drivers, and filesystems.
- **Not** learning the module system deeply, writing custom modules, or
  packaging anything into nixpkgs. Templates emit "assembly-language" Nix:
  flat, mostly-literal `virtualisation.oci-containers.containers.<name>`
  and `systemd.services.<name>` attribute sets.
- **Not** replacing the Debian/systemd target. Both targets coexist during
  (and possibly after) transition. `services.yml` is shared; only the
  templates and install flow diverge.

## Shape

```
globals.yml                  # unchanged
hosts/
  <hostname>/
    hardware.nix             # from nixos-generate-config, per-machine, committed
    host.yml                 # GPU vendor, kernel pin, NIC names, etc. — templated inputs
services/
  <name>/
    service.yml              # unchanged
    service.nix.erb          # NEW: emits a .nix fragment
    docker-compose.yml.erb   # kept for Debian target
    service.service.erb      # kept for Debian target
lib/mediaserver/
  targets/
    debian.rb                # current behaviour
    nixos.rb                 # NEW
```

`render.rb --target nixos` selects the emitter. Default stays `debian`
until the NixOS target is proven.

## Emitted Nix (sketch)

Per-service fragment, templated from `service.yml`:

```nix
# config/nixos/services/radarr.nix — rendered
{ config, pkgs, ... }: {
  virtualisation.oci-containers.containers.radarr = {
    image = "lscr.io/linuxserver/radarr:latest";
    extraOptions = [ "--network=container:wireguard" ];
    volumes = [ "/opt/mediaserver/radarr:/config" "/data:/data" ];
  };
  systemd.services.podman-radarr = {
    bindsTo = [ "podman-wireguard.service" ];
    after   = [ "podman-wireguard.service" ];
  };
}
```

Top-level rendered `configuration.nix` imports `hardware.nix`, `host.yml`
-derived `host.nix`, and every `services/*.nix`. Templated from a single
aggregator ERB.

Host-level bits templated from `host.yml`:

- `boot.kernelPackages = pkgs.linuxPackages_<version>;`
- `hardware.<nvidia|amdgpu|...>` block selected by `gpu:` key
- `hardware.enableRedistributableFirmware = true;` + any explicit
  `hardware.firmware` additions
- `networking.hostName`, interface config if non-default

## Install flow

- Debian target today: `rsync config/ → /opt/mediaserver/config/` + per-service
  `systemctl restart`.
- NixOS target: `rsync config/nixos/ → /etc/nixos/` (or a flake input dir)
  + `sudo nixos-rebuild switch`. Per-service restarts happen automatically
  for units whose rendered inputs changed.
- `make deploy-<service>` becomes "render + rebuild" — a single
  `nixos-rebuild switch` is the unit of deploy. Less granular than today's
  per-service restart, but NixOS only restarts changed units, so the
  practical behaviour is similar.

## Phases

### Phase A — VM prototype, two services, no templating

Hand-write `configuration.nix` on a NixOS VM with two representative
services (one plain, one VPN-netns) and wireguard. Prove the pattern works
end-to-end *before* investing in templates:

- `virtualisation.oci-containers` handles container lifecycle.
- `--network=container:wireguard` works the same as in docker-compose.
- `systemd.services.podman-*.bindsTo` enforces VPN dependency correctly.
- Caddy (native nixpkgs service or container) reaches the VPN sidecar.

Exit criteria: two services up, VPN IP confirmed, killing wireguard takes
dependents down, rollback via generation selection works.

**Stop here if the pattern doesn't hold.** Everything downstream assumes
surface-level Nix is sufficient.

### Phase B — NixOS emitter in the library

- `lib/mediaserver/targets/nixos.rb`: takes `Config`, emits per-service
  `.nix` fragments + top-level `configuration.nix`.
- Per-service `service.nix.erb` templates under each `services/<name>/`.
- `render.rb --target nixos` wired up.
- Tests: rendered Nix fragments diff against golden files for a fixture.
- Makefile: `make all TARGET=nixos` writes to `config/nixos/`.

Debian target untouched. Can land incrementally; nothing installs yet.

### Phase C — Dual-boot real hardware, test migration story

- Dual-boot NixOS on the media server (separate disk if available, else
  shrink partition). `/data` mounted read-only initially.
- Install rendered config. Bring up services pointing at *copies* of the
  existing state dirs (Radarr DBs etc.) to avoid divergence.
- Exercise the failure modes that motivated this:
  - Pin an older kernel, `nixos-rebuild boot`, reboot, confirm.
  - Intentionally pick a broken kernel/driver combo, confirm rollback via
    GRUB generation selection works.
- Validate `make smoke` (from TODO.md) against the NixOS target.

### Phase D — Host abstraction + second machine

Only if Phases A–C succeed.

- `hosts/<name>/host.yml` schema: GPU, kernel, NIC, hostname, disk UUIDs.
- Templates consume `host.yml`.
- Bring up a second host (could be the eventual new hardware) from the same
  `services/` tree with a different `host.yml`. This is the real test of
  the portable-migration claim.

### Phase E — Cutover decision

Open question, deferred until Phases A–D land: do we keep Debian target as
an escape hatch, or delete it? Keeping both means ongoing template
duplication. Deleting means committing to NixOS for this stack.

## Risks / open questions

- **NVIDIA + newer kernels** occasionally lag in nixpkgs. Not NixOS's
  fault, but the pinning is explicit — which is the point, but means the
  upgrade workflow is "bump pin, test, rollback if bad" rather than
  "apt upgrade and hope."
- **State migration.** Radarr/Sonarr SQLite DBs, Plex library, qBittorrent
  session — all live outside the rendered config. A `rsync` job either
  way; NixOS doesn't change this, but dual-booting between Debian and
  NixOS against the same state dirs *will* cause corruption. Must copy
  state for Phase C.
- **Podman vs Docker.** `virtualisation.oci-containers` defaults to
  Podman on NixOS. Podman's `--network=container:<name>` works but has
  edge cases around netns lifecycle. If issues, `backend = "docker"` is
  a one-line switch.
- **Caddy DNS resolution** across containers: needs the shared
  `mediaserver` network still, same Phase 4 concern as the Debian target.
- **Synology NAS bits** (otelcol scraping, etc. per recent commits) —
  confirm those still work unchanged; they're separate from the render
  target.
- **`make deploy-<service>` semantics change.** One-button per-service
  restart becomes a full `nixos-rebuild switch`. Fast in practice but
  worth confirming the UX is acceptable before deleting the Debian target.

## Relationship to the restructure PLAN.md

- Phase 3 (per-service dirs) is a hard prerequisite — templates need to
  live per-service.
- Phase 5 (declarative `systemd:` shorthand) maps almost one-to-one onto
  NixOS's `systemd.services.<name>` module options. The abstraction we're
  building for the Debian target is the same abstraction the NixOS
  emitter consumes. This is the main argument for doing the restructure
  first: it makes the NixOS target cheap rather than a rewrite.
