# Restructuring Plan: Per-Service Isolation

## Goal

Editing one service's config should rebuild and restart only that service (plus aggregator-driven reloads for prometheus/homer/caddy, which are desired).

## Current pain

- Every ERB target depends on `services.yml`, so touching it re-renders everything.
- `docker-compose.yml` is a single rendered file; any service change bounces all services via the shared `-compose.path` watcher.

## Agreed shape

1. Pure-Ruby library loaded by `render.rb`, testable, home for structural validation now and port-conflict / cross-service validation later.
2. All service files loaded on every render. No top-level manifest — discover via `services/*/service.yml`.
3. Per-service directories: each service's ERBs and its `service.yml` under `services/<name>/`.
4. Per-service docker-compose files with a shared external bridge network `mediaserver`.
5. `mediaserver-network.service` systemd oneshot with `RemainAfterExit=yes`; dependents use `After=` / `Requires=` / `PartOf=`.
6. VPN services use `network_mode: container:wireguard` + `BindsTo=wireguard.service`.
7. Systemd relationships expressed in `service.yml` shorthand (`systemd: { requires:, binds_to:, after:, part_of: }`); raw `systemd_overrides:` as escape hatch rendered to `<svc>.service.d/override.conf`.

## Phases

### Phase 1 — Extract render logic into a library

Pure refactor. `render.rb` becomes a thin CLI. All loading/merging/expansion/`ProjectService` logic moves into `lib/mediaserver/`.

- `lib/mediaserver/config.rb`: `Config.load(root:)`, `ProjectService`, `deep_merge!`, `expand_vars`, `get_group_id`.
- `lib/mediaserver/renderer.rb`: encapsulates ERB binding.
- `render.rb`: parse env + argv, load config, render stdin.
- `test/config_test.rb`, `test/renderer_test.rb` — Minitest, stdlib only.
- Makefile: add `test:` target.

**Validation**: `make clean && make all` produces byte-identical output to a pre-refactor baseline. `make check` passes. Tests green.

**Rollback**: revert the commit.

### Phase 2 — Structural validation + TODO.md

- `Validator` in the library: unique names, name matches dir basename (deferred until Phase 3 lands), `port` integer or nil, `docker_config` shape, `unit` / `docker_config` legality.
- `TODO.md` with deferred items:
  - Port-conflict check across services (including caddy's published list).
  - `use_vpn: true` implies wireguard target exists.
  - `group_ids` warn on unknown groups.
  - Volume path prefix sanity.
  - Homer `/refresh` hot-reload (avoid homer container restart on aggregator change).
  - Cross-service preflight: duplicate `container_name`, VPN service without caddy proxy entry, etc.
  - `make smoke` post-install healthcheck walk using services' `healthz` paths.
  - PR-time rendered-config diff using a test input (no secrets).

**Validation**: `make all` green; failing fixture proves validation fires.

### Phase 3 — Per-service directories + glob discovery + narrowed Makefile deps

- New `globals.yml` (split from `services.yml`): `install_base`, `media_path`, `hostname`, `objectives`.
- New `services/` top-level. Move every existing service dir into it; extract each entry from `services.yml` into `services/<name>/service.yml`.
- Delete top-level `services.yml`.
- `Config.load` globs `services/*/service.yml`, merges `config.local.yml`, expands vars.
- `ProjectService#source_dir` → `services/<name>`.
- Makefile: `.make.services` driven by `render.rb --list-make` (keeps `yq` out of Make). `ERBS` glob shifts to `services/*/**/*.erb`; target paths still `config/<svc>/<file>` (installed layout unchanged). Narrowed pattern rule via `.SECONDEXPANSION` or per-service make fragments.
- Aggregator targets (`docker-compose.yml` until Phase 4, `prometheus.yml`, `homer/config.yml`, `caddy/Caddyfile`, `otelcol-config.yaml`, `prometheus/rules/mediaserver.yaml`) keep a wide dep on all `services/*/service.yml`.
- `systemd/service.path.erb`: `Dir.glob("#{service.source_dir}/**/*")`.
- **Also in this phase**: add `caddy` to `sighup_reload: true` (aggregator Caddyfile changes should reload caddy, not restart it).

**Validation**: byte-identical `config/` vs. Phase-2 baseline. `touch services/jellyfin/service.yml && make -n all` rebuilds only jellyfin targets + aggregators.

**Migration**: none. `make install` produces the same rendered tree.

### Phase 3.5 — Prototype `container:wireguard` in place

Before splitting compose, prove the VPN netns mechanism works with `container:wireguard` inside the existing single compose project.

- Edit qbittorrent's `docker_config` to `network_mode: "container:wireguard"` (still legal inside one project).
- Remove qbittorrent's `depends_on: wireguard` (same-project depends_on will go away in Phase 4; systemd will own ordering).
- `make all && make check && make install`; restart qbittorrent; confirm VPN IP via `curl ifconfig.me` and caddy reachability on port 8080.
- Kill wireguard; confirm qbittorrent needs a restart (container netns reference breaks) — this motivates `BindsTo=` in Phase 4.

**Rollback**: revert the two lines.

### Phase 4 — Split docker-compose + `mediaserver-network.service` + VPN migration (merged cutover)

Phase 4 and the old Phase 5 are merged: splitting compose invalidates `service:wireguard`, so all VPN services flip to `container:wireguard` in the same cutover.

- New `systemd/service.compose.yml.erb`: per-service compose template rendering `config/<svc>/docker-compose.yml` with `networks: mediaserver: external: true, name: mediaserver` (or `network_mode: container:wireguard` for VPN services).
- Delete top-level `docker-compose.yml.erb`.
- New `systemd/mediaserver-network.service` (static, no ERB):
  ```
  [Unit]
  Description=Docker bridge network for mediaserver
  After=docker.service
  Requires=docker.service
  [Service]
  Type=oneshot
  RemainAfterExit=yes
  ExecStart=/bin/sh -c '/usr/bin/docker network inspect mediaserver >/dev/null 2>&1 || /usr/bin/docker network create --driver bridge mediaserver'
  ExecStop=/usr/bin/docker network rm mediaserver
  [Install]
  WantedBy=multi-user.target
  ```
- `systemd/service.service.erb`:
  - `ExecStart=/usr/bin/docker compose -f <install_base>/config/<svc>/docker-compose.yml up <svc>`
  - `After=docker.service mediaserver-network.service`
  - `Requires=docker.service mediaserver-network.service`
  - `PartOf=mediaserver-network.service`
  - VPN services (`use_vpn?`) additionally: `BindsTo=wireguard.service`, `After=wireguard.service`.
- `systemd/service-compose.path.erb`: `PathChanged=<install_base>/config/<svc>/docker-compose.yml`.
- Makefile:
  - Per-service compose rule; `SYSTEMD_COMPOSE_TARGETS` folded into `all:`.
  - `check:` loops: `for f in config/*/docker-compose.yml; do docker compose -f "$f" config > /dev/null; done`.
  - `install-systemd` installs `mediaserver-network.service` and enables it before other services.

**Pre-cutover validation** (local, machine doesn't run the stack):
- `make clean && make all && make check` green.
- Manually inspect a sampling of per-service compose files for sane shape.
- Render diff vs. baseline — expected: compose split into N files; new path units; updated service units with `mediaserver-network`/`BindsTo` directives.

**Cutover validation** (on the real host, not on this machine):
1. Stop everything: `sudo systemctl stop <mediaserver units>`; `docker compose -f /opt/mediaserver/config/docker-compose.yml down` (kills the old project-scoped network).
2. `sudo systemctl enable --now mediaserver-network.service`; confirm `docker network inspect mediaserver` exists.
3. `make install && make install-systemd`.
4. `sudo systemctl daemon-reload && sudo systemctl start <units>`.
5. **Network-attachment check**: `docker network inspect mediaserver` must list every non-VPN service plus wireguard. The four VPN sidecars (radarr, sonarr, prowlarr, qbittorrent) must be *absent* (they share wireguard's netns). Any missing non-VPN container = forgotten `networks: [mediaserver]` in its compose file.
6. Hit each service's `healthz` path (future: `make smoke` target).
7. Restart wireguard; confirm VPN services stop and come back via `BindsTo=`.

**Rollback**: keep a pre-cutover `config/` tarball. If something breaks, `git revert` the cutover commit, `make install install-systemd`, restart.

### Phase 5 — Declarative systemd deps + drop-in override escape hatch

- `service.yml` schema:
  ```yaml
  systemd:
    requires: [mediaserver-network]
    binds_to: [wireguard]
    after: [wireguard]
    part_of: [mediaserver-network]
  systemd_overrides: |
    [Service]
    LimitNOFILE=65536
  ```
- `service.service.erb`: render `Requires=`/`After=`/`BindsTo=`/`PartOf=` from `service['systemd']` merged with defaults (`docker.service`, `mediaserver-network.service`).
- `systemd/service-override.conf.erb` → `config/systemd/<svc>.service.d/override.conf` when `systemd_overrides` present.
- Migrate Phase 4's hardcoded `Requires=mediaserver-network.service` / `PartOf=…` and VPN `BindsTo=wireguard.service` out of the template into each service's `systemd:` block. Base template becomes minimal.
- Makefile: derive override-file targets from `render.rb --list-make`.

**Validation**: rendered `.service` files diff identical for services without `systemd:` keys; additive for services that declare them. `systemd-analyze verify` passes on all units.

Can land independently of Phase 4; clean up is optional.

## `make install` backward compatibility

| Phase | Installed tree changes? | Cutover? |
|-------|-------------------------|----------|
| 1, 2, 3, 3.5 | No | No |
| 4 | Yes (compose split, new network unit, VPN netns via `container:`) | One-time |
| 5 | Additive `.service.d/` | `daemon-reload` only |

## Flagged complications

- `systemd/service.path.erb` uses `Dir.glob` at render time. Post-Phase-3, file additions inside a service dir must re-trigger the path unit's re-render. Handle via `.make.services.d/<svc>.mk` fragment regenerated when `$(shell find services/<svc> -type f)` changes.
- `render.rb` top-level `compose_file` global becomes service-specific post-Phase-4. Computed from `SERVICE_NAME` when set; aggregators shouldn't reference it.
- `config/%: %` fallback rule competes with the ERB rule. Pattern rule needs explicit `$(patsubst config/%,services/%,$@)` once sources move.
- Caddy continues to need DNS resolution for `wireguard` on the shared `mediaserver` network; confirm wireguard's Phase-4 compose file attaches it to `mediaserver`.
- VPN sidecars do *not* appear in `docker network inspect mediaserver` — they share wireguard's netns. This is correct, not a bug.
