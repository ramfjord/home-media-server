# Remote deploy to fatlaptop

**Status: shipped 2026-04-25 on `remote-deploy` branch.**

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

## Shape (as shipped)

A `TARGET` variable selects where install actions land:

- `TARGET=local` (default): rsync and side-effecting commands run on
  this host.
- `TARGET=fatlaptop` (or any ssh host alias): `rsync` over ssh,
  `ssh fatlaptop sudo systemctl …`, etc.

Three primitives in the Makefile:

```make
TARGET ?= local
-include Makefile.local
RSYNC_DEST = $(if $(filter local,$(TARGET)),,$(TARGET):)
REMOTE     = $(if $(filter local,$(TARGET)),,ssh $(TARGET))
```

`Makefile.local` is git-ignored — drop `TARGET := fatlaptop` in there
to default the deploy target without typing it on every invocation.
Command-line `TARGET=…` still overrides.

Every side-effecting `rsync`/`systemctl`/`chown` is routed through
those primitives. `rsync` uses `--rsync-path="sudo rsync"` so it runs
as root on the target (needed to write into per-service dirs owned by
service users). systemctl on the remote uses `ssh host sudo systemctl`.

## Commits (as shipped)

1. **Add TARGET variable for remote deploy via rsync+ssh** — Introduce
   `TARGET`, `RSYNC_DEST`, `REMOTE`. Route the `install` target's
   rsync destinations and chown loop through them.
2. **Route systemd targets through `$(REMOTE)`; simplify install-systemd**
   — `install-systemd` reduced to files + `daemon-reload` only (no
   more enable/start at install time). Moved enable of
   `mediaserver-network`, `mediaserver.target`, and path units into
   `systemd-enable`. Path-unit enable/disable now batch into one
   `systemctl` call (one ssh round-trip instead of ~25). Routed
   `systemd-{start,stop,restart,status,enable,disable}` through
   `$(REMOTE)`. Unit-file rsync uses `--rsync-path="sudo rsync"`.
3. **Add `deploy-<svc>` target** — Pattern rule that ran `install` then
   restarted the service. Superseded by next commit.
4. **Rename `deploy-<svc>` → `restart-<svc>`; drop install dep** —
   Realized that with path units active, `make install` *is* the
   deploy verb — rsync writes the file, path unit fires, service
   reloads. So `deploy-<svc>` was misnamed. Renamed to
   `restart-<svc>` (force-restart only). Use `make install
   restart-foo` when both are wanted.
5. **`Makefile.local` for default TARGET; update docs** — Picked the
   git-ignored Makefile shim over a `render.rb --get target` extension.
   Updated CLAUDE.md and README.

Then a series of commits that emerged during real-world testing on
fatlaptop:

6. **`--rsync-path="sudo rsync"` for the install rsync** — First
   real run hit `Permission denied` writing into per-service dirs
   owned by service users from prior chowns. Mirrors what we already
   did for unit-file rsync.
7. **Tighten install ownership/perms to survive path-unit reload race**
   — Added `--no-owner --no-group` (existing files keep their
   chown-set ownership) and `chmod g+s` on service dirs (new files
   inherit `mediaserver` group). Wrapped the post-rsync loop in
   `sudo sh -c` so install no longer requires the outer make
   invocation to already be root.
8. **Stop recursing setgid into runtime data dirs** — `find … -exec
   chmod g+s` was walking thousands of dirs in `jellyfin/metadata/`
   etc. and erroring out on container-namespaced UIDs. setgid
   propagates: setting it once on the top-level service dir is enough.
9. **Per-service rsync with `--chown`; drop post-rsync chown loop** —
   The pre-existing recursive `chown -R` was also walking runtime
   data and producing the same kind of `Operation not permitted`
   spam. Restructured `install` to loop per service, each rsync
   with `--chown=<svc>:mediaserver` and `--chmod=Dg+s`. Eliminates
   the post-rsync chown step entirely. Bonus: no chown race window
   for new files. Cost: ~20 ssh round-trips per install, mitigated
   with ssh ControlMaster.

## Lessons learned

- **Path units already redeploy on file change.** This is the deploy
  verb. The original plan's "Phase 4: deploy-<svc>" framing was
  wrong — install + path units handles it. `restart-<svc>` is just
  the force-restart override for the wedged-service case.
- **Recursive chown into runtime data dirs is a pre-existing bad
  idea**, not a new problem introduced by remote deploy. Local install
  was either failing silently or being run as a user who didn't notice.
  Remote install made the noise visible. The fix (per-service rsync
  with `--chown`) is structurally cleaner regardless of remote vs local.
- **Setgid propagates.** Don't recursively chmod g+s into existing
  trees; just set it on the top-level dir and new subdirs inherit it.
- **`install-systemd` was doing too much.** Conflating "put files in
  place" with "enable units" made the target awkward over ssh and
  fragile when path units were already half-enabled. Splitting the
  responsibilities — `install-systemd` for files, `systemd-enable`
  for wiring — also fixed a nagging local pain point.

## Prerequisites on fatlaptop (manual, one-time)

Out of repo, but documented here so the plan is self-contained:

- ssh from laptop → `fatlaptop` works without password (key auth).
- User on fatlaptop has passwordless `sudo` for `rsync` and
  `systemctl` at minimum. (Currently has it generally.)
- Docker, the `mediaserver` group + per-service users exist (see
  `plans/static-uids.md`).
- `script/make_users.sh` has been run on fatlaptop.
- ssh ControlMaster recommended in `~/.ssh/config` to amortize the
  per-service ssh round-trips:
  ```
  Host fatlaptop
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 60s
  ```

## Risks / open questions

- **UID/GID drift.** `chown` runs on the target via `--chown=`, so as
  long as fatlaptop has the right users it's fine. Still amplifies the
  case for `plans/static-uids.md` — pin those numerics before this
  gets heavy use, otherwise a future restore-from-backup on a
  different host will surprise.
- **Secrets.** `certs/` is rsynced. Acceptable for now (Tailscale +
  ssh transport).
- **Concurrent edits.** If someone is also running `make install`
  directly on fatlaptop, two sources of truth. Mitigation: stop
  checking out the repo on fatlaptop now that remote deploy works.
- **`make check` on laptop vs target.** `docker compose config` and
  `systemd-analyze verify` run on the laptop against rendered files.
  If laptop and fatlaptop have meaningfully different docker / systemd
  versions, validation could pass locally and fail remotely. Not yet
  bitten; if it does, add a `check-remote` target.
- **`certs/` rsync still runs as a single batch with implicit
  ownership** — not migrated to the per-service `--chown` pattern.
  Worked fine in testing because caddy was the only consumer and
  permissions held. Worth revisiting if other services start needing
  certs or if cert-key permissions get strict.

## Related plans

- `plans/nixos-target.md` — sequencing analysis preserved below.
- `plans/static-uids.md` — remote `chown` on the target makes the
  static-UID manifest more valuable; that plan already defers
  *renumbering* to the NixOS cutover but lands the manifest +
  validator on Debian first. Independent of this plan.

## Sequencing vs the NixOS plan

The NixOS plan's install verb is `nixos-rebuild switch --target-host
fatlaptop`, which subsumes ssh transport + remote activation + per-unit
restart in one command. Now that this plan has shipped:

- **`TARGET=` knob**: reusable. Under NixOS the same variable just
  routes to `nixos-rebuild --target-host $(TARGET)` instead of
  `rsync + ssh systemctl`.
- **Per-service rsync + ssh systemctl plumbing**: largely throwaway
  once NixOS lands, since `nixos-rebuild` handles unit installation
  and per-changed-unit restart automatically. Earned its keep in the
  months between.
- **`restart-<svc>`**: still useful as a Makefile entry point under
  NixOS.
- **`Makefile.local` + docs**: applies to both targets.

The NixOS critical path is `plans/nixos-target.md` Phase A
(hand-write `configuration.nix` on a NixOS VM with two services +
wireguard, prove the pattern holds). Remote deploy is *not* on
NixOS's critical path; the VM prototype is.
