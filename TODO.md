# Deferred follow-ups

Things discussed during the per-service restructure that aren't in scope for
the current phases. Roughly ordered by expected payoff.

## Larger follow-up plans

- [NixOS as a render target](plans/nixos-target.md) — emit NixOS config
  instead of Debian systemd + compose. Motivated by the kernel-upgrade
  incident and portable hardware migration. Depends on Phases 3 and 5 of
  the restructure.

## Validation (extend `lib/mediaserver/validator.rb`)

- **Port conflicts.** Detect duplicate host-side ports across services,
  including the list caddy publishes on behalf of VPN services. Today you
  find out by `docker compose up` failing at bind time.
- **`use_vpn: true` requires a wireguard service** to exist and to be
  dockerized. A typo in `use_vpn` silently breaks network routing.
- **Unknown groups.** `groups: [mediaserver]` resolves via `getent` at
  render time and silently drops unknown names (`group_ids.compact`). Warn
  if a referenced group doesn't resolve on the host.
- **Volume path sanity.** Warn when a `docker_config.volumes` entry's host
  path doesn't start with `${install_base}` or `${media_path}` — most
  real volumes do, and surprises usually mean a typo.
- **Duplicate `container_name`** in raw `docker_config` that conflicts with
  the implicit `container_name: <service.name>` set by the compose template.
- **VPN service without a caddy proxy entry.** Post-split, VPN services
  aren't reachable on the `mediaserver` bridge — they need caddy to expose
  them. Catch adds that forget to update caddy.

## Runtime quality-of-life

- **Homer hot-reload via `/refresh`** instead of container restart on
  aggregator changes. Homer supports it; today the path watcher bounces the
  container whenever any service is added/removed.
- **`make smoke`** target: after `make install-systemd`, curl each service's
  declared `healthz` and fail if any is unreachable. Cheap, catches "started
  but wedged" cases.
- **PR-time rendered-config diff** using a synthesized fixture input (no
  real certs / secrets / host-specific paths). Useful even for a solo PR
  workflow — shows the effect of a change without checking rendered config
  into git.

## Plumbing

- **`render.rb --list-make`** emitting make-friendly variable assignments
  (`ALL_SERVICES := ...` etc.) so the Makefile stops shelling out to `yq`.
  Needed once per-service directories land in Phase 3.
- **`render.rb --list-services`** or similar for generic scripting use.
- **Path-unit dep tracking.** After Phase 3, files added inside a service
  directory must re-trigger re-render of that service's `.path` unit. The
  `.make.services` cache doesn't cover this today; a per-service make
  fragment regenerated on file-add is the likely fix.
