# Crashloop recovery + UID alignment + containment

Recover fatlaptop from the qbittorrent crashloop incident of
2026-04-25/26, fix the underlying UID misalignment that caused it
across every linuxserver-image service, and add structural defenses
so the next crashy container can't fill the disk the same way.

Includes a disk-pressure alarm — the absence of which let this go
from "qbit is unhappy" to "every container 137'd from disk-full"
without warning.

**Branch is gated by a deploy freeze:** while this work is in flight,
do not run `make install` against fatlaptop. The current renderer
+ rsync combination silently breaks the file ownership the linuxserver
containers depend on, and there is no longer-term fix in this branch
— that's `plans/static-uids.md`. This plan recovers the box, makes
the structural-defense improvements, and hands the durable fix to
static-uids.

## Goal

End state on fatlaptop:

1. All services up and stable. Verified ≥30min uptime with no crash
   loops or growing overlay layers, on the services touched
   (qbittorrent, sonarr, radarr, prowlarr — the linuxserver-image
   set with `user:` baked into compose).
2. Host `kernel.core_pattern` configured so a future crash cannot
   fill the root filesystem with cores.
3. Docker daemon configured with json-file log rotation
   (`max-size: 50m`, `max-file: 3`) so a future log-spammer can't
   fill the disk via container json-logs either.
4. Prometheus / Alertmanager rule firing on root-fs >85% — the
   alarm that would have caught this 30G earlier.
5. Host-side bits (sysctl drop-in, `daemon.json`) live in the repo
   under `host/` so they're reproducible on a fresh box, not just
   imperatively configured.
6. `fatlaptop-docker-disk-handoff.md` and the cores at
   `/media/qbittorrent-cores/` cleaned up.

The durable UID fix is **out of scope** — that's `plans/static-uids.md`,
which becomes critical-path after this branch ships. Document the
deploy freeze; do not unfreeze until static-uids lands.

## Investigation summary

Captured here so the next session has the full chain without
re-deriving it.

### Symptom

`/dev/sda2` (221G root fs on fatlaptop) hit 100%. All containers
exited 137 (killed by docker on disk pressure / hung writes). User
manually stopped the stack.

### First (wrong) diagnosis

`fatlaptop-docker-disk-handoff.md` claimed qbit was downloading into
its writable overlay layer. **Wrong** on two counts:

- `docker inspect qbittorrent` shows `/data:/data` is bind-mounted
  correctly. Same for sonarr, radarr.
- The 182G in qbit's overlay is in
  `diff/run/s6-rc:s6-rc-init:iDcbLm/servicedirs/svc-qbittorrent/`,
  not `/downloads`.

### Second (also wrong) diagnosis

The cores dir held 13,867 files of ~18M each named `core.<pid>`,
spanning 2026-04-25 18:47 → 2026-04-26 01:23 (~35 crashes/min for
6.5h). `file core.140` confirmed they were qbittorrent-nox cores.
Initial guess: AVX2-incompatible Qt plugin (`strings core.earliest`
showed `/usr/lib/qt6/plugins/tls/libqcertonlybackend.so.avx2: No
such file or directory`). **Wrong** — fatlaptop's CPU has AVX2
(`grep avx2 /proc/cpuinfo`); the `.avx2` line is just Qt's variant
loader being noisy in dlerror, caught and ignored.

### Actual root cause (from `journalctl -u qbittorrent.service`)

The container's stderr in journald, in plain text, no sudo, no gdb:

```
qbittorrent | QtSingleCoreApplication: listen on local socket failed,
              QLocalServer::listen: Permission denied
qbittorrent | terminate called after throwing an instance of 'AsyncFileStorageError'
qbittorrent | ./run: line 16: 139 Aborted (core dumped) ... qbittorrent-nox ...
```

qbit couldn't write to its `/config` dir. Two failures escalating:

1. `QLocalServer::listen` fails on its singleton-instance unix socket
   (`Permission denied` because parent dir isn't writable by the
   container's running uid).
2. `AsyncFileStorageError` thrown when async storage tries the same
   dir.
3. Exception propagates past `main`, `std::terminate` calls
   `abort(3)`, kernel writes a core, systemd respawns. Loop.

### Why the permission denied — UID misalignment

The compose template `systemd/service.compose.yml.erb:6` sets:

```erb
service_config["user"] = service.user_id if service.user_id
```

`service.user_id` (`lib/mediaserver/config.rb:63`) shells out to
`id -u <name>` — on the **rendering host**. That used to be
fatlaptop, where service users had the uids the on-disk files
already had. Now (post-`plans/remote-deploy.md`), rendering happens
on the laptop. Laptop and fatlaptop have completely disjoint uids
for the same usernames:

| service     | laptop uid | fatlaptop uid |
|-------------|-----------:|--------------:|
| qbittorrent |        942 |          1504 |
| sonarr      |        944 |          1502 |
| radarr      |        945 |          1501 |
| prowlarr    |        943 |          1503 |
| jellyfin    |        941 |           992 |

So the rendered `docker-compose.yml` says `user: '942'` (laptop's
qbittorrent uid). The container is forced to run as 942. Meanwhile,
`plans/remote-deploy.md` commit 9 added `--chown=qbittorrent:mediaserver`
to the install rsync, which chowns config files to **fatlaptop's**
qbittorrent (uid 1504). Container writes as 942 to a tree owned by
1504. EACCES on every write. Crash. Loop.

### Trigger

`journalctl` shows `make install` ran at **2026-04-25 18:46:23**
from the laptop (sudo rsync to `/opt/mediaserver/config/qbittorrent/`).
The rsync fired the qbittorrent path unit, which ran compose-reload,
which restarted the container as `user: '942'` against a freshly
re-chowned-to-1504 tree. The very next minute (18:47) the cores
started.

### Backup status

`/opt/mediaserver.bak` exists, birth time 2026-04-25 18:35:04 — ~12
minutes before the bad deploy. **Not a useful drop-in restore**: the
file *content* is identical (`diff` returned empty between live and
backup `qBittorrent.conf`), and the backup's ownership is
`root:root` for that file — which doesn't help the container any
more than the live `qbittorrent:1504` does. Either way the fix is to
chown the live tree to a uid that matches what the compose forces.
Keep the backup as a content-rollback safety net but don't restore
from it.

### Why this didn't bite earlier

`plans/remote-deploy.md` shipped 2026-04-25. Commit 9 ("per-service
rsync with `--chown`; drop post-rsync chown loop") landed during
that branch. The 18:46:23 deploy was very likely the first one that
actually re-chowned existing files from 942 → 1504. Before that, the
files were at whatever uid the container created them as (942), the
container could write, qbit was fine.

## Related plans

- `plans/static-uids.md` — **becomes critical-path after this branch
  ships.** This branch chowns config trees to laptop-uid and freezes
  deploys; static-uids is the durable answer ("uids in a manifest,
  identical on every machine"). The deploy freeze stays in place
  until static-uids ships. Strong sequencing: do not start a third
  parallel branch before static-uids.
- `plans/remote-deploy.md` — **shipped**. Its commit 9 is the proximate
  trigger for the incident; not a bug in remote-deploy itself, just
  the change that exposed the latent UID drift.
- `plans/nixos-target.md` — host-level config (sysctl, daemon.json)
  becomes Nix module config under NixOS. The Debian-era files this
  plan adds under `host/` are throwaway at the NixOS cutover. Worth
  a header comment in the host files so future-us doesn't port them
  as-is. Same trajectory as `script/make_users.sh`.
- `plans/lisp-render.md`, `plans/deploy-preview.md`, `plans/pre-rewrite.md`
  — orthogonal. Renderer / preview work, no interaction.

## Design notes

### Sequencing inside this branch

Three classes of work, ordered by urgency:

1. **Recovery first.** The box is down. `chown` the affected service
   trees to the laptop uids so that, the next time we restart them,
   they have permission to write. This is per-service and reversible.
2. **Structural defense second.** core_pattern, docker log rotation,
   disk-pressure alarm. None of these would fix qbit, but they would
   have stopped this incident from going from "qbit is unhappy" to
   "everything 137'd."
3. **Cleanup last.** Delete the wrong handoff doc, remove the
   preserved cores once recovery is durable.

### Affected services

Every service whose rendered compose has `user: '<uid>'` and whose
host file ownership differs from that uid. From the renderer:

```ruby
service_config["user"] = service.user_id if service.user_id
```

`service.user_id` returns nil when no host user with that name
exists (the `2>/dev/null` swallows the error and `.strip` produces
empty string → falsy). So `user:` is rendered iff the rendering host
has a user with that name. On the laptop, that's: **qbittorrent,
sonarr, radarr, prowlarr, jellyfin** (and possibly homer, alertmanager,
others — to be confirmed in commit 1's audit).

But: not every linuxserver-image service necessarily crashes the
same way. qbit's failure mode is loud (singleton unix socket, async
storage exception → SIGABRT). Sonarr/Radarr are Mono/.NET-based;
they may degrade more quietly (a logged "can't write DB" error,
service stays up but malfunctions). All of them still have the
permission gap; we should fix them all even if only qbit was
crashlooping at the disk-fill moment.

### `chown` strategy

The compose forces `user: '942'` (etc.). For the container to be able
to write, the on-disk tree must be owned by uid 942. **We should
chown to the numeric uid, not the host username** — the host user with
uid 942 may not exist at all (it doesn't on fatlaptop). Files will
appear as `942 mediaserver` in `ls -l` until static-uids ships and we
either renumber the host users or accept this as the resting state.

Per-service:

```bash
ssh fatlaptop sudo chown -R 942:1002 /opt/mediaserver/config/qbittorrent
ssh fatlaptop sudo chown -R 944:1002 /opt/mediaserver/config/sonarr
ssh fatlaptop sudo chown -R 945:1002 /opt/mediaserver/config/radarr
ssh fatlaptop sudo chown -R 943:1002 /opt/mediaserver/config/prowlarr
ssh fatlaptop sudo chown -R 941:1002 /opt/mediaserver/config/jellyfin
```

(Numbers from this laptop's `id -u <svc>`. Confirm again in commit 1
in case the audit finds others.)

`mediaserver` group is gid 1002 on fatlaptop, 1002 on this laptop —
matched by accident, but matched. Worth verifying as part of commit 1
that group ids align across machines; if they don't, that's another
manifest entry for static-uids.

### Deploy freeze

Until static-uids ships, every `make install` from the laptop will
re-chown trees back to fatlaptop uids and re-break the containers.
Options:

1. **Don't deploy.** Documented prominently in CLAUDE.md ("DO NOT
   `make install` against fatlaptop until `plans/static-uids.md`
   ships").
2. **Revert the `--chown=` part of remote-deploy commit 9.** Brings
   back the post-rsync chown loop or removes ownership rewriting
   entirely. Restores pre-incident behavior. Smaller blast radius
   than freezing all deploys.
3. **Render `user:` from a fixed uid table** (mini static-uids).
   Half-measure that converges with what static-uids.md will do
   anyway.

Pick (1) for this branch. (2) muddies the remote-deploy plan; (3) is
just static-uids done badly. The freeze is honest about the state
of things and sets up static-uids as the unblocking work.

If the freeze is impractical (e.g. urgent service config change),
`make install` *can* still ship safely if followed immediately by
the same chown commands above — but every time, every service. This
is the ergonomic argument for static-uids.

### Coredump policy

`kernel.core_pattern` is currently the literal string `core` —
kernel writes `core.<pid>` to the crashing process's cwd. For a
container, that cwd is inside the writable overlay. Set
`core_pattern = |/bin/true` to discard cores entirely. We already
have samples from this incident; future qbit-in-container cores have
near-zero forensic value (we can't fix upstream container images,
and journald has the stderr we actually need).

### Docker log rotation

`/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

Caveat: only affects containers created *after* docker reload. Since
recovery already restarts every container, this is moot for this
plan, but worth a comment in the file for future-us.

### Disk-pressure alarm

The incident escalated from "qbit unhappy" to "every container 137'd"
because nothing watched disk. Add a Prometheus rule:

```yaml
- alert: RootFilesystemFilling
  expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.15
  for: 5m
  labels: { severity: warning }
  annotations:
    summary: "Root fs on {{ $labels.instance }} <15% free"
- alert: RootFilesystemCritical
  expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.05
  for: 1m
  labels: { severity: critical }
  annotations:
    summary: "Root fs on {{ $labels.instance }} <5% free"
```

Two thresholds: warn at 15% (catches slow drift days before failure),
critical at 5% (catches a fast crashloop with hours to spare).
Routes via the existing alertmanager config; no new receiver needed
unless the user wants one. Confirm `node_exporter` is scraping
fatlaptop in commit 1.

Live in `services/prometheus/rules/` (or wherever the existing rules
template lives — confirm in commit 1). One new rule file or appended
to the existing one; appended is smaller.

### `host/` directory shape

New top-level `host/` dir for files that target `/etc/...` on the
host. Two reasonable models:

- **Symlink-style:** `host/etc/sysctl.d/60-no-coredumps.conf`,
  `host/etc/docker/daemon.json`. `make install` rsyncs `host/etc/`
  to the target's `/etc/`. Requires careful rsync filtering so we
  don't clobber unrelated `/etc/` files.
- **Script-driven:** files live under `host/` flat,
  `script/install-host-config.sh` copies them to the right places.
  More flexible, less "magic," easier to add validation steps.

Pick script-driven. The rsync model for `/etc/` is one typo from
clobbering host-critical config. Same shape as `script/make_users.sh`.

### What about the hardlink concern from the handoff doc?

Resolved: irrelevant. All three of qbit/sonarr/radarr mount
`${media_path}:/data` — same host path, same in-container path,
same filesystem (`/dev/sdc2`). Hardlinks across them work. The
handoff doc's premise (overlay-layer downloads) was wrong.

## Commits

1. ✅ **Audit affected services + alarm prerequisites** — Walk every
   service's rendered `docker-compose.yml` (under `config/` after
   `make all`) for the `user:` field. Cross-check against host users
   on fatlaptop. Note: (a) which services have `user:` rendered,
   (b) the laptop uid baked in vs the fatlaptop uid + name, (c)
   whether the `mediaserver` gid matches across machines, (d)
   whether `node_exporter` is scraping fatlaptop's filesystem
   metrics (Prometheus query `node_filesystem_avail_bytes{mountpoint="/",instance=~".*fatlaptop.*"}`),
   (e) whether the existing alerting rule template is per-service or
   centralized, (f) which alertmanager receiver fires for `severity:
   warning` / `severity: critical`. Drop the result into the plan as
   a `**Decisions:**` block on this commit, plus a temporary
   `plans/crashloop-recovery-audit.md` if it doesn't fit cleanly.
   *Verify:* the affected-services list is concrete (names + uid
   pairs); the alarm prerequisites question for each subitem (a)–(f)
   has a documented answer.
   **Decisions:**
   - (a/b) Blast radius is **17 services**, not 5. Every service whose name exists as a user on both hosts has a uid mismatch. Pairs (`<svc> laptop=<uid> fatlaptop=<uid>`): qbittorrent 942/1504, sonarr 944/1502, radarr 945/1501, prowlarr 943/1503, jellyfin 941/992, homer 940/1505, caddy 946/993, grafana 938/472, prometheus 210/113, alertmanager 211/1508, qbittorrent-exporter 933/984, exportarr-sonarr 934/985, exportarr-radarr 935/986, cadvisor 937/1509, blackbox-exporter 939/1507, otelcol 936/995, vaultwarden (no user either side; rendered `user:` is empty — skip). `wireguard` has no laptop user, so `user:` not rendered — skip.
   - (c) `mediaserver` gid is **1002 on both machines** — accidentally aligned. Static-uids will pin it. Not blocking.
   - (d) `node_exporter` IS scraping fatlaptop filesystem metrics — confirmed by an existing rule using `node_filesystem_avail_bytes{mountpoint=~"/|/media.*"}`.
   - (e) Rules live in `services/prometheus/rules/{rules,blackbox,mediaserver}.yaml.erb`. New disk rules go into `mediaserver.yaml.erb` (centralized, not per-service).
   - (e-bonus) **An existing rule already covers disk-fill**: `VolumeFillingUp` at >75% used (25% free), no `for:`, label `partof: streaming, service: disk`. It should have fired during the incident — possible reasons it didn't: prometheus itself died when disk filled, or alertmanager → discord webhook is broken. Worth a smoke test in commit 7 regardless. The plan's proposed *warning* threshold (15% free / 85% used) is *less strict* than the existing rule, so don't duplicate — keep `VolumeFillingUp` as the warning, add only a **critical** rule (5% free / 95% used, `for: 1m`).
   - (f) Single alertmanager receiver: `discord` (webhook). No severity-based routing today. New rules use the existing label convention (`partof:`, `service:`) rather than introducing a `severity:` label that nothing routes on.

2. **Add deploy-freeze guardrail** — Fail `make install` with a
   loud message when targeting any non-`local` host, until
   `plans/static-uids.md` ships. The check goes early in the
   `install` recipe, before any rsync. Mechanism: a sentinel file
   (e.g. `.deploy-frozen`) the install rule checks for, with the
   message pointing at this plan and at static-uids. Document in
   CLAUDE.md under Workflow.
   *Verify:* `TARGET=fatlaptop make install` exits non-zero with the
   freeze message before any rsync runs; `make install` (TARGET=local)
   is unaffected; `rm .deploy-frozen` (after static-uids ships)
   removes the freeze with no other code change. Manual check on
   wording: the message tells the next person *exactly* what to do.

3. **Recover qbit + the rest of the linuxserver stack** —
   Per-service: ssh to fatlaptop, `chown -R <laptop-uid>:1002
   /opt/mediaserver/config/<svc>` for each service identified in
   commit 1 (qbittorrent, sonarr, radarr, prowlarr, jellyfin —
   confirm full list from commit 1). Then `systemctl start` them
   one at a time, watch logs (`journalctl -fu <svc>.service`) for
   30s each before moving to the next. This commit makes no
   repo changes — it documents the recovery procedure in the plan
   as a `**Decisions:**` block (commands run, services that came up
   cleanly, anything that needed extra attention). Recovery is
   imperative, not committed code.
   *Verify:* `docker compose ps` (or `systemctl --type=service | grep
   -E '(qbit|sonarr|radarr|prowlarr|jellyfin)'`) shows all targeted
   services Up / active. `df -h /` on fatlaptop holds steady over
   30min. No new files in any overlay layer
   (`sudo find /var/lib/docker/overlay2 -name 'core.*' -newer /tmp/recovery-marker`
   empty). qbit web UI loads and shows torrents from `BT_backup`.

4. **Add `host/` skeleton + `script/install-host-config.sh`** —
   New `host/etc/` tree (empty for now), plus
   `script/install-host-config.sh <target>` that takes an ssh alias
   (or `local`) and copies `host/etc/sysctl.d/*.conf` and
   `host/etc/docker/daemon.json` to the right paths, running the
   appropriate reload (`sysctl --system`, `systemctl restart docker`)
   only if files actually changed. Use `install -C` semantics or
   hash compare. Header comment in each host-side file: rationale,
   link to this plan, "this is throwaway at NixOS cutover —
   `plans/nixos-target.md` will template these." Shellcheck clean.
   *Verify:* `script/install-host-config.sh local` is a no-op when
   `host/etc/` is empty; running twice in a row with one stub file
   reloads exactly once. `script/install-host-config.sh fatlaptop`
   on a clean tree reloads nothing (since no files exist yet).

5. **Add `kernel.core_pattern = |/bin/true` drop-in** — Write
   `host/etc/sysctl.d/60-no-coredumps.conf`:
   `kernel.core_pattern = |/bin/true`, `kernel.core_uses_pid = 0`,
   `fs.suid_dumpable = 0`. Run
   `script/install-host-config.sh fatlaptop`. Smoke test: ssh to
   fatlaptop, run a process inside any container that segfaults
   (e.g. `docker exec homer sh -c 'kill -SIGSEGV $$'`), confirm no
   core appears anywhere under `/var/lib/docker/overlay2/`.
   *Verify:* `ssh fatlaptop cat /proc/sys/kernel/core_pattern` is
   `|/bin/true`. Smoke test result documented in commit message.

6. **Add Docker log-driver size cap** — Write
   `host/etc/docker/daemon.json` with `log-driver: json-file`,
   `log-opts: { max-size: 50m, max-file: 3 }`. Run
   `script/install-host-config.sh fatlaptop` (which restarts
   docker — bouncing all containers once). Recreate one container
   to pick up the new defaults; verify
   `docker inspect <ctr> --format '{{json .HostConfig.LogConfig}}'`
   shows `max-size=50m`, `max-file=3`.
   *Verify:* a freshly created container has the expected LogConfig.
   Stack still up after docker restart.

7. **Add disk-pressure alarm** — Append (or new file under)
   `services/prometheus/rules/` per commit 1's finding for the
   rules layout. Two rules: `RootFilesystemFilling` at <15% for 5m,
   `RootFilesystemCritical` at <5% for 1m, both scoped to
   `mountpoint="/"`. Render, install (locally — deploy freeze still
   applies, do this on the host directly or via whatever bypass is
   in place; document in commit message). Reload prometheus.
   Smoke test: in a tmpfs scratch dir, `dd` a file large enough to
   push the test instance under threshold, confirm the alert fires
   in <2 cycles, then clean up. Document this exercise in the
   commit message; do not include the dd output as an artifact.
   *Verify:* `promtool check rules` clean. New alert visible in
   Prometheus UI under Rules. Alert fires when threshold breached
   (in test); clears when restored. Routes to whatever receiver
   commit 1 identified.

8. **Cleanup: remove handoff doc, prune saved cores, document
   freeze** — `git rm fatlaptop-docker-disk-handoff.md` (the
   diagnosis is wrong; this plan is the record). On fatlaptop:
   `sudo rm -rf /media/qbittorrent-cores/` once the host has been
   stable for ≥48h (do this *after* the rest of the branch has
   been merged and uptime confirmed; this commit lands the deletion
   command in the plan, not the actual rm). Update CLAUDE.md:
   add `host/` paragraph under Configuration; add
   `script/install-host-config.sh` line under Commands; add deploy-freeze
   note under Workflow with a pointer to `plans/static-uids.md` as
   the unblocking work.
   *Verify:* `grep -rn fatlaptop-docker-disk CLAUDE.md README.md`
   finds nothing. CLAUDE.md mentions `host/`, `install-host-config.sh`,
   and the freeze. `make check` green. The 48h core-deletion command
   is a documented line in the plan's `**Decisions:**` block, not
   a still-pending action that ages out into noise.

## Future plans

- **`plans/static-uids.md`** — already drafted, becomes critical-path
  immediately after this branch. Unblocks the deploy freeze.
- **Move qbit `/config` to `/dev/sdc2`** — only relevant if qbit
  configs ever cause real disk pressure. Today's mount on root fs
  works; not urgent.
- **SSL cert expiration alarm** — analogous to the disk-pressure
  alarm. Same class of "obvious thing that could go wrong" as this
  incident. Cheap; do as a standalone plan after static-uids.
- **Per-container resource limits** — `mem_limit`, `pids_limit`,
  `--log-opt` overrides. Defense-in-depth; useful but not
  load-bearing given the daemon-wide log cap from commit 6.
- **Audit *-arr* hardlink topology** — confirm Sonarr/Radarr "Use
  Hardlinks" is actually hardlinking under `/data`. The handoff
  doc's framing was wrong, but the underlying question (are
  hardlinks working?) is worth checking once. Cheap.
- **journald log-driver instead of json-file** — would have made
  the qbit stderr discoverable from a single `journalctl -u
  <svc>.service` instead of three different paths. Out of scope;
  json-file is the current contract and changing log driver is its
  own decision.

## Non-goals

- **Static UIDs in this branch.** That's `plans/static-uids.md`. The
  deploy freeze is the bridge.
- **NixOS templating of host-level config.** Files in `host/etc/`
  are Debian-specific and become Nix module config at the NixOS
  cutover (`plans/nixos-target.md`). Don't pre-template.
- **Forcing every linuxserver service to use PUID/PGID env.** That's
  one fix shape; static-uids.md is a different one. Don't pre-empt
  the static-uids design by retrofitting PUID/PGID here.
- **Investigation tooling.** The `gdb` + `nix-shell` rabbit-hole was
  unnecessary in retrospect; `journalctl -u <svc>` had the answer.
  Lesson recorded in this plan; no tooling commit needed.

## Open questions

- **Does `core_pattern = |/bin/true` work cleanly on this kernel?**
  Pipe handlers run as kernel core dumper; `/bin/true` exiting
  immediately is the canonical "discard" pattern but worth
  confirming the kernel doesn't log warnings or retry. Fallback if
  it misbehaves: a tiny script under `/usr/local/sbin/discard-core`
  that drains stdin and exits 0.
- **Does any other container besides qbit produce cores under load?**
  Spot-check `find /var/lib/docker/overlay2 -name 'core.*'` once
  before commit 5 lands. Anything turning up is a bug report
  somewhere, not a scope expansion.
- **Should `script/install-host-config.sh` integrate with `make
  install`?** Tempting but `host/` changes are rare and the script
  restarts docker. Keep it separate; the freeze sentinel from
  commit 2 doesn't apply to `install-host-config.sh`.
- **`mediaserver` gid alignment.** Both machines happen to use 1002,
  but that's accidental. Static-uids will pin it; not this plan's
  job.
