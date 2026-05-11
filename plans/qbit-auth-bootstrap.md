# qBittorrent auth bootstrap

api-config currently calls `POST /api/v2/app/setPreferences` to set
qBittorrent's webui password from `config.local.yml`. The call relies
on qBittorrent's subnet-whitelist auth-bypass to land without
credentials. In practice the password isn't sticking: every time
qBittorrent restarts (cascaded from `BindsTo=wireguard.service`), it
boots with no `Password_PBKDF2=` in its conf, generates a one-shot
random temp password, logs it to stdout once, and rejects every
subsequent API call (including the arrs' authenticated requests at
localhost — `LocalHostAuth=true` defeats the subnet-whitelist for
in-netns callers).

Goal: replace the existing one-shot setPreferences POST with a
bootstrap flow that handles qBittorrent's "I just regenerated a temp
password" case. After this branch ships, the arrs ↔ qbit auth
recovers automatically on any qBittorrent restart without manual UI
intervention.

## Goal

After this lands:

1. `api-config.service` for the `qbittorrent` upstream reads
   qBittorrent's stdout-emitted temporary password from Loki, logs
   in with it, and pushes the configured username/password from
   `config.local.yml` via `/api/v2/app/setPreferences`.
2. If the configured creds already work (qbit's `Password_PBKDF2` is
   intact), the bootstrap is a no-op — single login probe, exit.
3. Wiping `Password_PBKDF2=` from `qBittorrent.conf` and triggering
   a deploy recovers auth without operator action. This doubles as
   a smoke test: the bootstrap is verifiable.

## Context

Root cause of the 2026-05-10 outage: every `make install` rsync of
the rendered `qBittorrent.conf` strips any `Password_PBKDF2=` line
qBittorrent had persisted. On the next qbittorrent restart (any
cause — wireguard re-up, image upgrade, deploy), qBittorrent finds
no password in the conf and falls back to its random session
password. The arrs' saved credentials no longer match → permanent
401 until manual intervention.

qBittorrent has no API to retrieve the current password. The
temporary password is only ever in the container's stdout. Loki
already ingests qbit's journald (via alloy) and is the most
container-friendly source for the value.

## Related plans

- **`plans/post-truthing-phase1.md`** (in flight, unmerged) — adds
  per-service READMEs (radarr, wireguard, jellyfin, vaultwarden,
  alertmanager) + the passwords.csv.elp. None of those files
  conflict with this plan's touch list. `radarr/README.md` mentions
  api-config for the download-client wiring; nothing in there
  contradicts the bootstrap design.
- **`plans/crashloop-recovery.md`** (drafted, not started) —
  references the discord webhook reliability story and the
  api-config oneshot. Doesn't constrain this plan.
- **`plans/health-rules-quickfix.md`** (drafted, not started) —
  alert content, not api-config logic. Independent.

## Design notes

**Why Loki, not docker.sock or journalctl.** api-config runs with
`network_mode: host` for the public_url-via-caddy reason already
documented in `services/api-config/service.yml.elp`. It needs to
read qbittorrent's logs. Three sources considered:

- Mount docker.sock — adds privilege expansion. api-config would
  gain the ability to do anything Docker can do.
- Mount /var/log/journal + run journalctl — works but the container
  isn't sized for systemd packages, and host-side log layout is a
  fragile dependency.
- Query Loki HTTP — alloy already ships journald to loki. No new
  mounts. Adds an ordering dependency on alloy + loki being up
  before api-config can succeed; the existing 7.5min retry budget
  in `configure.py` covers it.

**How api-config reaches Loki.** Loki today has no published port
(internal-only on the docker network as `loki:3100`). api-config is
on `network_mode: host` and can't resolve `loki`. Add
`127.0.0.1:3100:3100` to loki's compose entry — host-only exposure,
nothing tailnet-facing changes. api-config queries
`http://127.0.0.1:3100/loki/api/v1/query_range`.

**Operation type — qbittorrent-specific, not general.** The new
configure.py operation is named `qbittorrent_auth_bootstrap` and
hard-codes the regex (`temporary password is provided for this
session: (\S+)`), the login endpoint shape (qbit-form-encoded), and
the setPreferences body. No `source: loki, query: ...,
extractor: regex, store_as: $temp_pw` abstraction — one consumer,
one named operation. If sonarr or anything else ever needs a similar
log-scrape bootstrap, generalize then.

**Schema shape.** Add to qbittorrent's `api_resources:`:

```yaml
qbittorrent_auth_bootstrap:
  username: <%= username %>
  password: <%= password %>
  loki_url: http://127.0.0.1:3100
  unit: qbittorrent.service
```

Drops the existing `posts: app/setPreferences` block — the bootstrap
operation IS the password-setting flow, the posts entry was
redundant (and didn't reliably set the password anyway).

**Failure mode if Loki has no temp-pw line.** Possible if alloy
hasn't shipped yet (first deploy on a fresh stack) or qbit was
booted long ago and the entry rolled out of loki's retention. The
operation polls loki for up to ~6 minutes (loki retry budget within
configure.py's existing schedule) and then fails loudly. Manual
recovery falls back to "log in to the qbit UI with the latest temp
pw from `docker logs`" — same as today.

## Commits

1. **Expose loki on 127.0.0.1:3100** — Add a host-only port mapping
   to `services/loki/service.yml.elp`'s `docker_config`. Goldens
   regenerate.
   *Verify:* `make all && grep -A1 ports config/loki/docker-compose.yml`
   shows the loopback-bound mapping. After deploy:
   `curl -s http://127.0.0.1:3100/ready` on the host returns
   `ready` (or whatever loki's readiness reply is).

2. **Add `qbittorrent_auth_bootstrap` operation to configure.py** —
   New top-level resource type. Implementation:
   - Attempt `POST /api/v2/auth/login` with configured creds. If
     body is `Ok.` (qbit's success-string), return success — the
     password is already set, nothing to do.
   - On `Fails.` body or 401/403: query loki via
     `GET /loki/api/v1/query_range?query={unit="qbittorrent.service"} |~ "temporary password is provided"&direction=BACKWARD&limit=10`,
     extract `(\S+)` after `for this session: ` from the most
     recent matching log line.
   - Log in with the temp password → SID cookie.
   - `POST /api/v2/app/setPreferences` (qbit-form-encoded) with
     `web_ui_username` and `web_ui_password` set to configured
     values, using the SID cookie.
   - Re-attempt the configured-creds login. If it succeeds, exit
     success; else raise `ConfigureError` with the failure body.
   - Loki retries with the existing `RETRY_BACKOFFS` schedule when
     the query returns empty (no matching line yet — alloy hasn't
     shipped).
   *Verify:* `tools/api-config/Dockerfile` builds clean. Unit
   smoke-test: drop a fake loki response into a local mock,
   run configure.py against an httpx mock, assert the expected
   sequence (login fail → loki query → login with temp → setPreferences
   → login confirm). If a quick mock isn't worth it: integration
   verify in commit 5 via real deploy.

3. **Replace qbittorrent's `posts:` block with `qbittorrent_auth_bootstrap`** —
   Edit `services/qbittorrent/service.yml.elp`'s `api_resources:`
   block. Drop the comment about "qBittorrent.conf.elp sets
   AuthSubnetWhitelist..." since the bootstrap no longer relies on
   that auth-bypass. Keep the conf entries (they still help
   tailnet-facing callers that come via caddy).
   *Verify:* `make all && grep -A10 qbittorrent
   config/api-config/resources.yaml` shows the new key shape.

4. **Build + push the new api-config image** — `make api-config-publish`.
   The qbittorrent compose entry pulls `ghcr.io/ramfjord/api-config:latest`
   on next deploy, so no tag bump needed (rely on :latest until
   that becomes a problem).
   *Verify:* `docker pull ghcr.io/ramfjord/api-config:latest` on the
   deploy host shows the new digest after the push. `docker inspect`
   the image: ENTRYPOINT and the configure.py content reflect the
   bootstrap operation.

5. **Deploy and verify on fatlaptop** — `make install`, then
   `sudo systemctl start api-config.service` (path watcher should
   trigger it from the resources.yaml change, but a manual kick
   makes the test deterministic). Check `journalctl -u api-config.service`
   for the bootstrap sequence. Then probe `curl -d
   'username=admin&password=admin123' http://localhost:8080/api/v2/auth/login`
   from inside radarr — expect `Ok.`. Then check Radarr's UI
   download-client status: queue/history pull resumes.
   *Verify:* No `Failed to authenticate with qBittorrent` lines in
   `docker logs radarr` for 5 minutes after the deploy.

## Future plans

- **Make `Password_PBKDF2` survive deploys.** The real underlying
  bug is that `qBittorrent.conf` gets rsynced over every install,
  stripping qbit's persisted password line. Two options worth
  considering:
  - Render `Password_PBKDF2=` into the conf template (requires
    PBKDF2-SHA512 in Lisp, salt cached in `config.local.yml` for
    determinism).
  - Make the deploy mechanic skip rsync of `qBittorrent.conf` if
    it already exists on the target (treat it like a one-shot
    bootstrap file rather than templated state).
  Either fix removes the recurring need for the bootstrap operation
  in this plan. The bootstrap stays as belt-and-suspenders for
  first-install and unexpected wipe events.

## Non-goals

- Generalize the bootstrap operation to a "log-scrape any
  secret from any service" primitive. Re-evaluate when a second
  consumer appears.
- Mount docker.sock in api-config. Loki path is the choice.
- Touch the deploy mechanic's handling of `qBittorrent.conf`.
  Separate plan (see Future plans).
