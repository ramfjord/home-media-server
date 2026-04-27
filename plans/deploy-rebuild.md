# Deploy mechanism rebuild

Rebuild `make install` around a single rendered shell script that runs
on the target host, with explicit uid overrides in YAML so the rendered
compose's `user:` matches the target host's actual uids.

Picks up where `plans/crashloop-recovery.md` left off after that branch
exposed every joint of the existing rsync-and-chown deploy as fragile.
Sequenced **after** crashloop-recovery merges; uses crashloop-recovery's
recovered fatlaptop state (16 service trees chowned to laptop uids) as
its starting point.

## Goal

After this branch ships:

1. `make install TARGET=fatlaptop` is safe and idempotent. No
   crashloop on every other deploy.
2. The deploy script is a *rendered* artifact — a flat sequence of
   `chown` + `rsync` + `systemctl` calls, auditable by `cat
   config/deploy.sh`. All flow control that depends on service data
   lives in ERB; bash handles only `set -euo pipefail`, args, and
   subprocess invocation.
3. The rendered compose's `user:` field uses the **target host's**
   uid, not the rendering host's. Sourced from explicit YAML override
   in `config.local.yml` (fatlaptop-specific, gitignored).
4. Local target support is dropped. Only remote (`TARGET=<ssh-alias>`)
   is supported. Local install can be reintroduced when a use case
   appears; the laptop is not running these services.
5. No `--user 942 vs host file 1504` mismatch ever again, because
   the renderer derives both from the same source.

## Context — why this exists

`plans/crashloop-recovery.md` shipped four commits (audit, freeze
guard, recovery, systemd-status, host/ skeleton). The remaining
work in that plan (host/ files for core_pattern, docker log
rotation, disk-pressure alarm, cleanup) was scoped to *defenses*
against the next disk-fill event. During execution, two things
became clear:

- **The defenses are the wrong target.** The actual incident's
  cause was a deploy-mechanism bug (laptop renders compose with
  laptop uids; rsync chowns target files to target uids; container
  forced to laptop uid hits target-owned files; permission denied;
  abort; SIGABRT; cores fill the overlay). Hardening core_pattern
  and adding stricter disk alerts treats symptoms.
- **The existing rule `VolumeFillingUp` should have fired.** The
  audit found it disabled-by-condition (75% used, no `for:`). It
  didn't notify discord during the incident. The right fix is
  finding out *why* discord didn't get notified, not adding more
  rules.

So the remaining scope of crashloop-recovery is just *cleanup*
(delete handoff doc, prune saved cores). The architectural work —
making `make install` correct — moves to this plan.

## Design decisions reached during discussion

### One: deploy is a rendered shell script, runs on the target

Laptop renders `config/` (per-service configs), `config/systemd/`
(units), and `config/deploy.sh` (the install script). Then:

```make
install: check
	rsync -av --rsync-path="sudo rsync" --delete \
	  config/ $(TARGET):/opt/mediaserver/staging/
	rsync -av --rsync-path="sudo rsync" \
	  certs/  $(TARGET):/opt/mediaserver/staging/certs/
	ssh $(TARGET) sudo bash /opt/mediaserver/staging/deploy.sh
```

The script sees everything as local paths under
`/opt/mediaserver/staging/`. Its body is rsync + chown + systemctl
calls only. No ssh-prefix logic, no `--rsync-path="sudo rsync"`,
no remote-vs-local branching.

### Two: all flow control in ERB, none in bash

The user (Thomas) explicitly proposed and we converged on:

> Could we put essentially all flow control in the ERB layer?
> Unless we are doing a bash test naturally, i.e. checking if a
> file exist? But conditional on service properties could be in
> ERB?

ERB owns:
- Service iteration
- Per-service chown decisions (does this service have a `user_id`?
  emit chown; else preserve ownership)
- Special-case for certs (chown to caddy by name)
- `install_base` lookup from globals

Bash owns:
- `set -euo pipefail`
- The rsync subprocess invocation
- daemon-reload
- File-existence runtime checks (none needed today)

Result: `cat config/deploy.sh` is a flat, readable list of what
will happen on the target. No service dispatch at runtime; it's
all resolved at render time.

### Three: explicit uid override in YAML

`lib/mediaserver/config.rb#user_id` currently shells out to `id -u
<name>` on the *rendering host*. With remote-deploy shipping
rendering to the laptop and laptop/fatlaptop having disjoint uids,
the rendered compose forces the wrong uid for every service.

Fix: a `service_user_ids:` map in `config.local.yml` (the
host-specific override file, gitignored). Each entry is
`<service-name>: <uid>`. The renderer checks the map first; falls
back to `id -u <name>` if not present.

Concretely on fatlaptop's `config.local.yml`:

```yaml
service_user_ids:
  qbittorrent: 1504
  sonarr: 1502
  radarr: 1501
  prowlarr: 1503
  jellyfin: 992
  homer: 1505
  caddy: 993
  grafana: 472
  prometheus: 113
  alertmanager: 1508
  qbittorrent-exporter: 984
  exportarr-sonarr: 985
  exportarr-radarr: 986
  cadvisor: 1509
  blackbox-exporter: 1507
  otelcol: 995
```

Then:
- Rendered `user:` uses fatlaptop's uid (matches files post-deploy)
- Deploy script chowns `<svc>:mediaserver` (resolves on target)
- Container forces same uid → owner access, no group-trickery
- `ls -l` on fatlaptop shows `<svc> mediaserver`, clean

This is essentially `plans/static-uids.md`'s mechanism with a
narrower scope: just the override map, no manifest range, no
renumber. Forward-compatible: when static-uids ships, it reads
the same kind of map (or supersedes this).

### Four: chown-by-name, not by uid, in the deploy script

The deploy script runs on the target. `chown qbittorrent:mediaserver`
resolves at runtime to fatlaptop's qbittorrent (1504) and
mediaserver (1002). With the YAML override in place, fatlaptop's
qbittorrent uid (1504) matches what compose forces (1504, from
the override). Files owned by 1504, container runs as 1504,
clean.

For services without a target-side user (vaultwarden has none
on fatlaptop), the script falls through to a no-chown rsync
preserving ownership. ERB gates this: `<%- if svc.user_id -%>`
chooses chown vs. no-chown branch.

### Five: certs handled explicitly

Certs live at `/opt/mediaserver/certs/`, used only by caddy.
Caddy needs to read `*.key` (default mode 600). Deploy script
chowns the certs dir to `caddy:mediaserver` and applies
`--chmod=D750,F640`, so caddy owner-reads the key directly.

### Six: drop local target support

`make install TARGET=local` is removed. The laptop doesn't run
these services; supporting both modes was duplicating logic
without payoff. If local install ever matters, reintroduce as
its own commit.

## Related plans

- `plans/crashloop-recovery.md` — predecessor. Provides the
  recovered fatlaptop state and the audit data this plan builds
  on. Its remaining cleanup commits ship before this branch
  starts.
- `plans/static-uids.md` — the proper fix. This plan is a narrow
  precursor: explicit uids in YAML *for one host*. Static-uids
  generalizes to a manifest with a clean range, validation,
  retired-uid tracking. When static-uids ships, the
  `service_user_ids:` map gets either renamed or replaced;
  forward-compatible.
- `plans/deploy-preview.md` — synergy. The "rsync-then-diff
  before merge" idea this plan touches on (staging dir → live)
  is half of what deploy-preview prescribes. After this branch,
  deploy-preview just adds the diff step between staging and
  live, before deploy.sh's rsync-into-live actually runs.
- `plans/per-service-health.md`, `plans/health-rules-quickfix.md`
  — orthogonal. They concern alerting; this concerns deploy.
  Both can ship in parallel.
- `plans/lisp-render.md` — orthogonal. The Lisp rewrite
  consumes the same template; the deploy.sh.erb here ports
  cleanly to ELP at cutover time.
- `plans/nixos-target.md` — strong synergy. The "target = bundle"
  framing this plan establishes (config + certs + systemd +
  deploy.sh, all rendered into a bundle) is the same shape NixOS
  needs. NixOS becomes a second renderer + a different deploy.sh
  that calls `nixos-rebuild`. After this plan, the multi-target
  refactor is much smaller — just adding a second emitter.

## Commits

1. ✅ **Add `user_id:` field + renderer-side hard-required validation** —
   `service.user_id` now reads `@definition['user_id']` directly
   (post deep_merge), no shell-out. Per-host overrides go in
   `config.local.yml`'s existing `service_overrides:` mechanism
   (same shape as the jellyfin nvidia override, not a separate
   `service_user_ids:` block). Renderer raises if a dockerized
   service has no `user_id` defined; opt-out via `user_id: false`
   for services that legitimately should not have a `user:` field
   in compose (wireguard runs as root for NET_ADMIN; vaultwarden
   has no host user).
   *Verify:* `make all` produces compose files with fatlaptop's
   uids (qbit 1504, caddy 993, jellyfin 992). `make test` passes
   after refreshing goldens to reflect the new shape (fixtures
   declare explicit `user_id` to exercise both the number and
   `false` code paths).
   **Decisions:**
   - User pushed back on the original `service_user_ids:` top-level field — wanted to reuse the existing `service_overrides:` mechanism for architectural consistency. Done that way.
   - Validation strictness: renderer raises (with a helpful message naming the service and the two fix-it locations) when a dockerized service has no resolved `user_id`. Soft fallback to `id -u` removed — the host-shellout was the original incident's bug, no point preserving it.
   - `user_id: false` as opt-out sentinel. Applied to `services/wireguard/service.yml` (replacing the in-code `if name == 'wireguard'` special case) and `services/vaultwarden/service.yml`.
   - Fixture services updated: fx-wireguard gets `user_id: false`, the other four get sentinel uids 99001–99004 (above any real-uid range, so goldens cover both branches without colliding with deploy data).
   - The dropped wireguard hardcode in `ProjectService#user_id` is a small purity win — service-shape concerns now live in service.yml, not in code.

2. **Caddy certs bind-mount fix** — Add
   `${install_base}/certs:/etc/caddy/certs:ro` to caddy's
   `service.yml` volumes. (Already drafted in working tree;
   ship it here.) Without this, the cert files exist on the
   host but never reach the container.
   *Verify:* `make all` and `grep certs config/caddy/docker-compose.yml`
   shows the mount. Caddy will come up clean once deployed.

3. **Add `deploy.sh.erb` + `make install` rebuild** — New
   top-level template (already drafted). Renders to
   `config/deploy.sh`. Loops `services.select(&:dockerized?)`,
   emits `chown <name>:mediaserver --chmod=Dg+s,Fg+w` rsync
   per service, special-cases certs, finishes with systemd
   units + daemon-reload. Makefile `install:` becomes:
   `rsync config/ + certs/ to staging; ssh sudo bash
   $STAGING/deploy.sh`. Drop `install-systemd:` (subsumed).
   Drop `TARGET=local` support.
   *Verify:* `make install TARGET=fatlaptop` exits 0. Followed
   by `TARGET=fatlaptop make systemd-status` 30s later: 17 of
   18 services `active` (vaultwarden + the 17 user-having
   services; exportarr-radarr/sonarr already had broken api
   keys before this branch — see *Out of scope* below).
   Specifically caddy flips from `inactive` to `active` thanks
   to the certs mount.

4. **Drop the deploy-freeze guard** — The 6-line `@if [
   "$(TARGET)" != "local" ]` early-exit added in
   `plans/crashloop-recovery.md` commit 2 is now obsolete.
   Remove. The freeze served its purpose; the install is now
   safe.
   *Verify:* `make install TARGET=fatlaptop` runs through;
   the freeze message no longer appears.

## Status of working-tree changes (as of this writing)

Pre-existing on the branch but not yet committed; will be
absorbed into the commits above:

- **`services/caddy/service.yml`** — modified, adds the certs
  bind-mount. Belongs in commit 2.
- **`deploy.sh.erb`** — top-level, drafted. Belongs in commit 3.
- **`config.local.yml`** — gitignored, contains api keys
  scp'd from fatlaptop. Will gain the `service_user_ids:`
  block in commit 1 (also gitignored — fatlaptop-specific).
- **`host/etc/sysctl.d/60-no-coredumps.conf`** — drafted for
  crashloop-recovery commit 6 (core_pattern). User decided
  to drop core_pattern work entirely. **Delete this file**
  before commit 1; it's not part of any planned commit.

Decisions about earlier crashloop-recovery work:

- **Commit 5 (host/ skeleton + install-host-config.sh)** —
  shipped in crashloop-recovery but its consumers (commits 6
  and 7 — core_pattern, log rotation) are now abandoned.
  Discussion: leave it merged for now, as a small piece of
  scaffolding; revisit at NixOS cutover. Not blocking.
- **Crashloop-recovery commits 6 (core_pattern), 7 (docker
  log rotation), 8 (disk-pressure alarm)**: dropped. Reasons:
  - core_pattern: discarding all cores is overcorrection;
    the chown fix prevents the crashloop in the first place.
  - log rotation: separate concern, unrelated to this incident,
    can ship as its own small plan later.
  - disk-pressure alarm: existing `VolumeFillingUp` already
    covers this; investigate why it didn't notify discord
    rather than adding more rules.
- **Crashloop-recovery commit 9 (cleanup)** — still wanted.
  Delete `fatlaptop-docker-disk-handoff.md`. Prune
  `/media/qbittorrent-cores/` once stack stable for a few
  days. Should ship before this plan starts as the close-out
  of crashloop-recovery.

## Out of scope (Future plans)

- **Fix exportarr-radarr / exportarr-sonarr.** Both fail
  because their compose's command lacks the `--api-key`
  argument. Not a deploy-mechanism issue; a renderer
  template gap. Small fix as its own commit (or part of
  per-service-health when it ships).
- **Investigate why `VolumeFillingUp` didn't notify discord.**
  Targeted diagnostic, not a content-change. Probably
  Prometheus crashed on disk-fill and lost alert state, or
  the discord webhook is broken. One-shot fix.
- **Multi-target refactor.** Move `config/` rendering into
  `targets/debian-systemd/`, prepare `targets/nixos/` slot
  for the NixOS work. Big refactor; deserves its own plan.
  After this branch the deploy.sh is already a renderable
  artifact, so the refactor is mostly directory restructuring.
- **Static-uids proper.** `plans/static-uids.md` already
  drafted. Now critical-path-after-this-plan instead of
  critical-path-after-crashloop-recovery, since this plan
  delivers the override mechanism that static-uids
  generalizes.
- **Align laptop's user uids to fatlaptop's via usermod.**
  Discussed but not pursued — yaml override is simpler.
- **Local target support.** Reintroduce when there's a use
  case for running services on the laptop.
- **Disk-pressure alarm tuning + log rotation + core_pattern.**
  Each their own small plan if/when wanted.

## Open questions

- **Should `service_user_ids:` live in `config.local.yml` or
  `globals.yml`?** `config.local.yml` is fatlaptop-specific
  and gitignored, so secrets and host-specific stuff lives
  there. UIDs are host-specific. → `config.local.yml`.
  Alternate: a separate `uids.yml` per host. Defer to
  static-uids for the long-term answer.
- **What if a service is in the override but the target host
  has no such user?** rsync's `--chown=name:mediaserver` will
  fail at chown-name-resolution time. Validator could catch
  this if it could query the target host. For now: deploy
  fails loudly, operator fixes by either creating the user
  on target or removing from override.
- **Does the `service_user_ids:` interact with the renderer's
  `${var}` interpolation system?** No. The override is
  consumed by `service.user_id`, not by a `${...}` reference.
  No collision.
- **Drop the deploy-freeze guard in commit 3 or commit 4?**
  Doesn't really matter; commit 3 is when deploy becomes
  safe, commit 4 is the narrow "remove the dead code" move.
  Keep them separate for cleaner reviews.
