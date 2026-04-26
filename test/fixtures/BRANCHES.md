# Renderer branch inventory

Source-of-truth checklist for golden-fixture coverage. Built from
`render.rb`, `lib/mediaserver/{config,renderer,validator}.rb`, the
`systemd/*.erb` host-side templates, and the per-service `*.erb`
templates under `services/*/`.

A branch is "covered" when at least one fixture surface causes the
renderer to take that branch and the resulting bytes are sealed in a
golden. Subsequent commits in `plans/pre-rewrite.md` tick items off as
fixtures grow.

The five fixture services (`fx-wireguard`, `fx-qbittorrent`,
`fx-caddy`, `fx-sonarr`, `fx-prometheus`) are referenced by short tag
in the "covered by" column.

## `ProjectService` public surface (`lib/mediaserver/config.rb`)

Every method is reachable from at least one template; goldens must
exercise each.

- [x] `name` — universal. Covered by every fixture.
- [x] `dockerized?` — `service.compose.yml.erb`, `mediaserver.target.erb`,
      `otelcol-config.yaml.erb`. Need at least one dockerized fixture
      (all five are).
- [ ] `unit` / `has_unit?` — `mediaserver.target.erb` via
      `reject(&:has_unit?)`, `otelcol-config.yaml.erb` via
      `has_key?("unit")`. **Intentional gap** (decided commit 2):
      keep the five-fixture scope per the plan. The `has_unit?=true`
      branch is exercised only by the real config via `make preview`.
- [~] `user_id` — `service.compose.yml.erb`. Returns `nil` for
      `wireguard` (hardcoded skip on the literal name), else shells
      out to `id -u <name>`. Goldens cover the shell-out branch (all
      five `fx-*` names are absent → empty string, which is truthy
      and thus emits `user: ''`). The hardcoded `name == 'wireguard'`
      skip is **not** hit (the fixture is `fx-wireguard`, not
      `wireguard`); that branch is covered only by the real config
      via `make preview`. To cover the
      "user_id is set" branch deterministically would require either
      injecting a stub or picking a name that is guaranteed to exist
      on every dev box (there is none). **Accept gap**; document in
      golden seed.
- [x] `partof` — `otelcol-config.yaml.erb`, `homer/config.yml.erb`,
      `alertmanager.yml.erb` (string literal in matchers, not via
      method). Cover via varied `partof:` values across fixtures.
- [x] `desc` — `service.service.erb`, `homer/config.yml.erb`.
- [x] `port` — `caddy/Caddyfile.erb`, `otelcol-config.yaml.erb`,
      `homer/config.yml.erb`, `service.compose.yml.erb` (port
      auto-mapping branch).
- [x] `healthz` — `otelcol-config.yaml.erb` (HTTP probe target). At
      least one fixture should set `healthz:`.
- [x] `docker_config` — `service.compose.yml.erb` (merged into
      service_config; `ports` key checked).
- [~] `groups` / `group_ids` — `service.compose.yml.erb`
      (`group_add`). Per plan §"Determinism guards", **no fixture
      sets `groups:`**, so `getent group` is never invoked. Branch
      "groups is empty → no group_add" is covered; branch "groups
      non-empty" is **intentionally uncovered** here (covered by
      `make preview`).
- [x] `[](key)` — `homer/config.yml.erb` (`s['name']`,
      `s['partof']`, etc.), `prometheus/rules/mediaserver.yaml.erb`
      (commented-out, but still parsed). Mostly equivalent to the
      named accessors; covered transitively.
- [x] `has_key?(key)` — `otelcol-config.yaml.erb`
      (`has_key?("unit")`).
- [x] `source_dir` — `systemd/service.path.erb` (Dir.glob),
      `render.rb --list-make` (file-presence test). Implicitly
      covered by anything that walks fixture files.
- [x] `use_vpn?` — `service.compose.yml.erb` (network_mode branch),
      `service.service.erb` (After/Wants wireguard.service),
      `caddy/Caddyfile.erb` (filter VPN services). Covered by
      fx-qbittorrent (true), fx-sonarr (true), fx-caddy / fx-prometheus
      (false), fx-wireguard (false-but-is-vpn-root).
- [x] `sighup_reload?` — `service.path.erb`, `service.service.erb`,
      `render.rb --list-make`. Cover via fx-caddy or fx-prometheus
      (set true on at least one).
- [x] `compose_file` — `service.compose.yml.erb` (no, that's the
      file *being* rendered), `service.service.erb`,
      `sighup-reload.service.erb`, `service-compose.path.erb`. Path
      derived from `install_base` → exercises the override path too.

## `Config` / globals surface

- [x] `DEFAULT_GLOBALS` defaults (`install_base`, `media_path`,
      `hostname`) — fixture `config.local.yml` should set
      **non-default** values for at least `install_base` and
      `hostname` to prove the override path; leave one default
      untouched to prove the default path.
- [x] `deep_merge!` — `Hash` recursion: covered by overriding a
      nested `docker_config` field on a fixture. `Array` union:
      covered by overriding `volumes` or `cap_add`. Scalar
      replacement: covered by overriding `port` or `desc`. Plan to
      hit all three via `service_overrides` on `fx-caddy`.
- [x] `expand_vars` — confirmed widely used: every dockerized
      `service.yml` interpolates `${install_base}` and/or
      `${media_path}`; `prometheus/service.yml` uses `${hostname}`.
      Custom keys (`${qbittorrent_username}`, `${qbittorrent_password}`)
      appear in `services/qbittorrent-exporter/service.yml`. Cover
      with fixtures: globals interpolation in volume mounts (all
      dockerized fixtures), plus one fixture with a custom var
      defined in fixture `config.local.yml`.
- [x] `service_overrides` — apply per-service deep-merge from
      `config.local.yml`. Fixture `config.local.yml` overrides one
      field on `fx-caddy` and `fx-sonarr`.
- [x] `order` field stable sort — fixture services should not all
      share the same order; vary so that lex-sort and order-sort
      produce different orderings (catches a regression from
      removing the sort).
- [x] `find(name)` — used implicitly when `SERVICE_NAME` is set on
      ERB rendering. The test runner exercises this when rendering
      per-service templates.

## `Validator` rules (`lib/mediaserver/validator.rb`)

These are negative branches — fixtures hit the success path; the
existing `test/validator_test.rb` covers the failure paths. Inventory
listed for completeness:

- name presence/string/non-empty
- name uniqueness across services
- `port` is integer or absent
- `docker_config` is a Hash
- `groups` is an Array
- `use_vpn` / `sighup_reload` are booleans

No additional fixture coverage required; these don't change rendered
output.

## Networking matrix (`systemd/service.compose.yml.erb`)

Five distinct shapes the renderer emits:

- [x] **VPN root** — `fx-wireguard`. `use_vpn?=false`, exposes ports
      that consumers will share. Hardcoded `user_id` skip.
- [x] **VPN consumer** — `fx-qbittorrent`, `fx-sonarr`. `use_vpn?=true`
      → `network_mode: container:wireguard`, no `networks` block.
- [x] **Plain tailnet** — `fx-prometheus`. `use_vpn?=false`,
      `port` set, no `ports:` in `docker_config` → renderer
      auto-emits `ports: ["9090:9090"]`.
- [x] **Multi-network bridge** — `fx-caddy`. `use_vpn?=false`,
      `docker_config` already supplies a `ports:` list → renderer
      must **not** add an auto-mapped port. Tests the
      `!docker_config.key?("ports")` short-circuit.
- [x] **Top-level `networks` block** — emitted unless `use_vpn?`.
      Covered transitively by every non-VPN-consumer fixture.

## Systemd-unit branches

`systemd/service.service.erb`:

- [x] `After=...wireguard.service` — only when `use_vpn?`.
- [x] `BindsTo=wireguard.service` block (lines 7–9, 16–18) — same.
- [x] `ExecReload` line — only when `sighup_reload?`.

`systemd/service-compose.path.erb` — straightforward, no branches.

`systemd/service.path.erb`:

- [x] `Unit=<svc>-reload.service` vs `<svc>.service` — depends on
      `sighup_reload?`. Cover via at least one sighup fixture
      (fx-caddy or fx-prometheus).

`systemd/sighup-reload.service.erb` — only rendered for sighup
services; covered if any fixture sets `sighup_reload: true`.

`systemd/service-compose-reload.service.erb` — no branches.

`systemd/mediaserver.target.erb`:

- [~] `dockerized.map` join — `services.select(&:dockerized?)`.
      All five fixtures are dockerized, so the *select* always
      returns the full list — the filtering branch is uncovered.
      Same intentional gap as `has_unit?` above.

## `render.rb --list-make` output

Driven entirely by `Config.load`; the four computed lists are:

- [x] `ALL_SERVICES` — all five fixture names.
- [x] `DOCKERIZED_SERVICES` — `select(&:dockerized?)`. Same as
      `ALL_SERVICES` if every fixture is dockerized.
- [x] `SYSTEMD_SERVICES` — `dockerized.reject(&:has_unit?)`. Same
      as above absent a `unit:` fixture.
- [x] `SIGHUP_SERVICES` — `select(&:sighup_reload?)`. Covers
      `sighup_reload?`.
- [x] `SERVICES_WITH_CONFIG` — services whose `source_dir` contains
      a non-`service.yml` file. Covered by `fx-caddy` (Caddyfile.erb)
      and `fx-prometheus` (prometheus.yml.erb); the other three are
      `service.yml`-only and must NOT appear in the list.

## `config_yaml[…]` lookups in templates

Real templates use:

- `config_yaml["snmp_username"]`, `["snmp_auth_password"]`,
  `["snmp_priv_password"]` — `services/prometheus/snmp.yml.erb`.
- `config_yaml["snmp_host"]` — `services/otelcol/otelcol-config.yaml.erb`
  (commented-out).

Pattern: arbitrary string lookup with `||` default. Cover with one
fixture template that does `<%= config_yaml["fx_label"] || "fallback" %>`,
exercising both the "key set in config.local" and "key missing → falls
through to default" paths via two goldens or a single template that
uses both.

## Renderer binding (`lib/mediaserver/renderer.rb`)

ERB templates have access to: `services`, `service` (when
`SERVICE_NAME` set), `install_base`, `media_path`, `hostname`,
`compose_file`, `config_yaml`. The fixture goldens must reference
each at least once across the suite.

- [x] `services` (collection) — homer, otelcol, caddy, mediaserver.target.
- [x] `service` (single) — service.compose.yml.erb, service.service.erb.
- [x] `install_base` — every dockerized service.yml, service.path.erb.
- [x] `media_path` — qbittorrent/sonarr/radarr/jellyfin volumes.
- [x] `hostname` — homer, prometheus, jellyfin.
- [x] `compose_file` — service.service.erb, service-compose.path.erb,
      sighup-reload.service.erb.
- [x] `config_yaml` — see prior section.

## Open follow-ups

- **Plex-shaped `unit:` fixture.** All five planned fixtures are
  dockerized, so `has_unit?`-true and the `mediaserver.target`
  filter both go uncovered by goldens. Options: (a) add a sixth
  `fx-plex`-style fixture, (b) accept the gap and rely on
  `make preview`. Decide in commit 2.
- **`groups` non-empty branch.** Plan §"Determinism guards"
  forbids `groups:` on fixtures (avoids `getent group` non-determinism).
  Same trade-off — covered only by `make preview`.
