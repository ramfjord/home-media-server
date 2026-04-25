# Remote deploy to fatlaptop

Make `make install` target a remote host (fatlaptop over Tailscale) from
this laptop, instead of always deploying to the local machine. Precursor
to the NixOS target plan (`plans/nixos-target.md`): both efforts need a
clean split between "render artifacts" and "apply to host X", so doing
this first means the NixOS work can reuse the same target abstraction.

## Why now

- Editing on laptop, running on fatlaptop is the actual workflow. Today
  it requires `git push` → ssh → pull → `make install` on the box.
- NixOS plan assumes `nixos-rebuild switch --target-host`. Introducing a
  `TARGET=` knob now lets the NixOS templates slot in later without
  redesigning the deploy flow.
- Forces us to surface every implicit "this runs on the box where the
  files already are" assumption in the Makefile (chown, systemctl,
  docker compose reloads, path-unit triggers).

## Non-goals

- Not building a config-management tool. No agent, no pull model, no
  drift detection. Push from laptop, run commands over ssh.
- Not changing the rendered output. `config/` on disk is identical
  whether the target is local or remote.
- Not replacing local install. `TARGET=local` (default) keeps current
  behavior so nothing breaks for direct-on-server use.

## Shape

A `TARGET` variable selects where install actions land:

- `TARGET=local` (default): current behavior — local `rsync`, local
  `sudo systemctl`, local `chown`.
- `TARGET=fatlaptop` (or any ssh host alias): `rsync` over ssh, remote
  `ssh fatlaptop sudo systemctl …`, remote chown.

Two primitives wrap every side-effecting command:

```make
RSYNC_DEST = $(if $(filter local,$(TARGET)),,$(TARGET):)
REMOTE     = $(if $(filter local,$(TARGET)),,ssh $(TARGET))
```

Then install rules become:

```make
install: check
	rsync -av --exclude='systemd/' config/ $(RSYNC_DEST)/opt/mediaserver/config/
	rsync -av certs/ $(RSYNC_DEST)/opt/mediaserver/certs/
	$(REMOTE) sh -c '...chown loop...'
```

Same pattern for `install-systemd`, `systemd-{start,stop,restart,status}`,
`systemd-{enable,disable}`. No new install code paths — just every
`sudo` and every `rsync` destination routed through these two vars.

## Phases

### Phase 1 — Prerequisites on fatlaptop (manual, one-time)

Out of repo, but documented here so the plan is self-contained:

- ssh from laptop → `fatlaptop` works without password (key auth).
- User on fatlaptop has passwordless `sudo` for `systemctl`,
  `rsync`, `chown`, `mkdir` under `/opt/mediaserver` and
  `/etc/systemd/system`. Or: deploy user owns `/opt/mediaserver`
  outright and only systemd commands need sudo.
- Docker, ruby (for any host-side scripts? — currently none), and the
  `mediaserver` group + per-service users exist (see
  `plans/static-uids.md`; remote deploy makes the static UID plan more
  urgent because `chown svc:mediaserver` must resolve to the same
  numeric IDs on both hosts if any tooling ever runs on the laptop
  side as those users — for now, chown only runs on the target, so
  local-vs-remote UID drift doesn't bite).
- `script/make_users.sh` has been run on fatlaptop.

**Validation**: `ssh fatlaptop sudo systemctl status mediaserver.target`
returns without prompting. `ssh fatlaptop ls /opt/mediaserver` works.

### Phase 2 — `TARGET` variable + rsync redirection

Smallest change that proves the model. No systemd yet.

- Add `TARGET ?= local` near the top of the Makefile.
- Define `RSYNC_DEST` and `REMOTE` as above.
- Rewrite the two `rsync` lines in `install:` to use `$(RSYNC_DEST)`.
- Wrap the `chown` loop in `$(REMOTE) sh -c '…'` (always — when
  `REMOTE` is empty it's just `sh -c '…'` locally, equivalent to today).

**Validation**:
- `make install` (no TARGET) — diff `/opt/mediaserver/config/` before/after,
  byte-identical to pre-change behavior.
- `TARGET=fatlaptop make install` — `config/` and `certs/` land on
  fatlaptop; `ssh fatlaptop ls /opt/mediaserver/config/` shows expected
  tree; chown applied.
- Nothing systemd-related touched yet, so services on fatlaptop keep
  running their old config until they reload (or until Phase 3 lands).

**Rollback**: revert the commit. `make install` falls back to the
hard-coded local rsync.

### Phase 3 — Remote systemd

- `install-systemd`: route `mkdir`, `rsync` of unit files, `daemon-reload`,
  `enable --now mediaserver-network.service`, `enable mediaserver.target`,
  `start` of path units through `$(REMOTE)`.
- `systemd-{start,stop,restart,status,enable,disable}`: prefix with
  `$(REMOTE)`.
- One subtlety: the path-unit start loop uses `$(notdir …)` of make
  variables resolved on the laptop — that's fine, the *names* are the
  same on both hosts; only the `systemctl` invocation moves.
- Another subtlety: `systemd-analyze verify` in `make check` runs
  locally against `config/systemd/*.service`. That's a static check on
  the rendered file, no host dependency, leave it alone.

**Validation**:
- `TARGET=fatlaptop make install-systemd` from laptop.
- `ssh fatlaptop systemctl status mediaserver.target` shows active.
- Edit a service's config locally, `TARGET=fatlaptop make install`,
  observe the path unit on fatlaptop trigger the reload (journalctl on
  fatlaptop).

### Phase 4 — Per-service `deploy-<svc>` targets (if not already remote-clean)

`CLAUDE.md` documents `make deploy-<service>` but I didn't find it in
the current Makefile — either stale doc or the target is generated
elsewhere. Audit; if it exists, route its `systemctl restart` through
`$(REMOTE)`. If it doesn't, add it as part of this work since
restarting a single service remotely is the most common dev-loop
action.

**Validation**: `TARGET=fatlaptop make deploy-radarr` restarts only
Radarr on fatlaptop, no other services bounce.

### Phase 5 — Default target + docs

- Decide whether `TARGET` defaults to `local` (safer, current
  behavior) or `fatlaptop` (matches actual usage). Probably keep
  `local` as default and set `TARGET=fatlaptop` in `config.local.yml`
  equivalent — but `config.local.yml` is read by Ruby, not make.
  Options:
  1. Leave default `local`, type `TARGET=fatlaptop` every time (or
     shell alias).
  2. Read `target` from `config.local.yml` via a tiny make shim
     (`TARGET ?= $(shell ./render.rb --get target 2>/dev/null || echo local)`).
  3. Add a `.envrc` / Makefile.local that's git-ignored and sets
     `TARGET`.
  Pick (2) if the render.rb extension is small; otherwise (3).
- Update `CLAUDE.md` "Commands" section to mention `TARGET=`.
- Update `README.md` if it documents install.

**Validation**: fresh clone, follow README, deploy to fatlaptop end to
end without reading the Makefile.

## Risks / open questions

- **UID/GID drift.** `chown svc:mediaserver` runs on the target, so as
  long as fatlaptop has the right users it's fine. But this plan
  amplifies the case for `plans/static-uids.md` — pin those numerics
  before this gets heavy use, otherwise a future restore-from-backup
  on a different host will surprise.
- **Secrets.** `certs/` is rsynced. Confirm it's not currently picking
  up anything that shouldn't leave the laptop, and that ssh transport
  is acceptable (it is — Tailscale-encrypted plus ssh).
- **Concurrent edits.** If someone is also running `make install`
  directly on fatlaptop (e.g., from a checkout there), two sources of
  truth. Mitigation: stop checking out the repo on fatlaptop once
  remote deploy works; the box becomes a deploy target only.
- **`make check` on laptop vs target.** `docker compose config` and
  `systemd-analyze verify` run on the laptop against rendered files.
  If laptop and fatlaptop have meaningfully different docker / systemd
  versions, validation could pass locally and fail remotely. Accept
  for now; if it bites, add a `check-remote` target that runs the
  same validators over ssh against the staged files.

## Related plans

- `plans/nixos-target.md` — sequencing detail below. tl;dr: this plan's
  Phases 1–2 are reusable harness; Phase 3 is largely throwaway once
  NixOS lands.
- `plans/static-uids.md` — remote `chown` on the target makes the
  static-UID manifest more valuable. That plan already defers the
  *renumbering* to the NixOS cutover but lands the manifest + validator
  on Debian first; that landing is independent of this plan and useful
  either way. No hard ordering between the two.

## Sequencing vs the NixOS plan

The NixOS plan's install verb is `nixos-rebuild switch --target-host
fatlaptop`, which subsumes ssh transport + remote activation + per-unit
restart in one command. That changes which phases of *this* plan have
lasting value:

- **Phase 1 (ssh / sudo prereqs on fatlaptop)** — needed by both. Pure
  prerequisite, do regardless.
- **Phase 2 (`TARGET=` var + `RSYNC_DEST`/`REMOTE` in Makefile)** —
  reusable. Under NixOS the same `TARGET` knob just routes to
  `nixos-rebuild --target-host $(TARGET)` instead of `rsync + ssh
  systemctl`. The ergonomics — "I edit here, it runs there" — are
  the same; only the verb under the hood changes.
- **Phase 3 (route every `systemctl` and unit-file `rsync` through
  `$(REMOTE)`)** — **largely throwaway once NixOS lands.** NixOS
  handles daemon-reload, unit installation, and per-changed-unit
  restart automatically. If the NixOS cutover is imminent, this phase
  is yak-shaving; if NixOS slips by months, it pays for itself in
  daily workflow.
- **Phase 4 (`deploy-<svc>`)** — semantics shift under NixOS to "one
  `nixos-rebuild switch` restarts whichever units' inputs changed."
  Still useful as a Makefile entry point either way.
- **Phase 5 (default + docs)** — applies to both targets.

### Decision: do all five phases

As of 2026-04-25 the user is deferring apt upgrades on fatlaptop for at
least 6 months following the last kernel-upgrade incident, and is
prioritizing a separate Lisp rewrite project ahead of the NixOS
transition. That removes the "before next apt upgrade" deadline that
would otherwise make NixOS urgent and pull Phase 3 of this plan into
the throwaway column.

With NixOS effectively slipping months out, all five phases of this
plan earn their keep:

- Phase 3 (`systemctl`-over-ssh plumbing) pays for itself across every
  edit-here-deploy-there cycle for the duration of the deferral.
- When the NixOS cutover eventually happens, some of Phase 3 gets
  deleted. That's fine — it earned its keep in the months between.
- Phases 1, 2, 4, 5 carry over to the NixOS target unchanged.

If the situation changes (apt freeze ends early, hardware incident
forces NixOS forward, Lisp project wraps), revisit: the alternative
path is to stop after Phase 2, jump to `plans/nixos-target.md` Phase A,
and let `nixos-rebuild --target-host` subsume Phase 3.

### What NixOS Phase A actually gates

Worth naming explicitly: `plans/nixos-target.md` Phase A is "hand-write
`configuration.nix` on a NixOS VM with two services + wireguard, prove
the pattern holds, exit if it doesn't." That's the real lead time on
NixOS — multi-day at minimum, longer if podman netns edge cases bite
(see that plan's risks). Remote deploy is *not* on NixOS's critical
path; the VM prototype is. If "before the next apt upgrade" is the
deadline, the highest-leverage move is starting Phase A in parallel
with (or before) remote-deploy Phase 2, not after.
