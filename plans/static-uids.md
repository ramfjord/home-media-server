# Static UID/GID plan

## Why

Today user IDs are runtime-resolved: `make_users.sh` `useradd`s each service
without specifying a UID, then `lib/mediaserver/config.rb#user_id` shells out
to `id -u <name>` at render time. This means:

- UIDs differ between machines (bad for NFS, backup restores, host migrations).
- `render.rb` requires the users to already exist before configs can be
  generated correctly.
- We have no record of which UIDs have been used historically, so reusing a
  retired service's name on NFS-mounted data is a footgun.

Goal: every service has a stable, statically-assigned UID/GID that is part of
the repo, allocated once and never reused.

## Design

### UID range

Pick a safe block outside distro defaults and outside the typical
`SYS_UID_MIN`/`UID_MIN` ranges:

- Range: **`64000`–`64999`** (well below the `65534` `nobody` sentinel,
  above systemd-dynamic and distro system ranges).
- Same range used for matching GIDs (per-service group). Shared groups like
  `mediaserver` get a fixed GID at the top of the range (e.g. `64999`).

### Manifest

New file `uids.yml` at repo root — the source of truth. Append-only:

```yaml
# DO NOT REUSE entries. Removing a service does NOT free its UID.
# Add new services at the next free id; never recycle.
range: [64000, 64999]
groups:
  mediaserver: 64999
users:
  radarr:    { uid: 64000, gid: 64000, retired: false }
  sonarr:    { uid: 64001, gid: 64001, retired: false }
  prowlarr:  { uid: 64002, gid: 64002, retired: false }
  # ...
  # When a service is removed: keep the entry, set retired: true.
```

### Wiring

1. `services/<name>/service.yml` no longer needs anything new — the manifest
   is keyed by `name`. (Optionally allow a `uid:` override in `service.yml`
   that must match the manifest, validated.)
2. `lib/mediaserver/validator.rb`:
   - Every dockerized service in `services.yml` MUST have a non-retired entry
     in `uids.yml`.
   - Every non-retired manifest entry MUST have a matching service directory
     (catches "service deleted but UID record kept" — they should be marked
     retired, not removed).
   - UIDs/GIDs unique; all within `range`.
3. `lib/mediaserver/config.rb`:
   - Load `uids.yml` once.
   - `ProjectService#user_id` / `#group_ids` return manifest values, no shell
     out. Drop `getent` / `id -u`.
4. `script/make_users.sh`:
   - Read `uids.yml`.
   - `groupadd --gid <gid> <name>` and `useradd --uid <uid> --gid <gid> ...`.
   - If the user already exists with a different UID, fail loudly (do not
     silently mutate — operator must reconcile, since files on disk are owned
     by the old UID).
5. Optional: a `make check-uids` target that diffs manifest vs. services dir
   and prints services lacking UIDs / retired entries with live dirs.

## Migration

The current host's UIDs are outside the target range, but we only run one
host today. **Defer the renumbering to the NixOS cutover** (`plans/nixos-target.md`)
rather than doing a `chown` pass on the live Debian box:

1. **Now (Debian host):** land the manifest, validator, and `script/make_users.sh`
   plumbing, but seed manifest values with the *current live UIDs* from the
   running host. Render-time shellouts go away; on-disk ownership is
   undisturbed. The manifest range comment can note "legacy UIDs — to be
   renumbered at NixOS cutover."
2. **At NixOS cutover:** rewrite the manifest to the clean `64000+` range as
   part of the same change that emits Nix `users.users.<svc>` blocks. The
   cutover already involves a fresh install / fresh filesystems plan, so do
   the `chown -R` on `${install_base}/config/<svc>` and service-owned media
   paths once, in that window, against the new system.
3. **After cutover:** manifest is the only source of UIDs going forward;
   future services allocate from the clean range. Retired entries from the
   legacy era stay in the file marked `retired: true, legacy: true` so we
   never accidentally hand a fresh service a UID that once owned bytes on
   disk.

## Out of scope

- Changing the `mediaserver` shared-group model.
- Rootless docker / userns remapping (separate concern; static UIDs make it
  easier later).
- The `wireguard` special case (no user today) — leave as-is unless we decide
  it needs one.
