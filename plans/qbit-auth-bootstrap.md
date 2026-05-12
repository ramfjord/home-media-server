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

**Generic `steps:` operation, not a qbit-specific one.** Original
draft put a `qbittorrent_auth_bootstrap` op into configure.py with
the regex / unit name / qbit-specific request shape baked in.
Reverted on user feedback: configure.py stays "curl-like" (generic
HTTP request + value extraction); per-service quirks live in each
`service.yml.elp`. The new primitive is a `steps:` block — an
ordered sequence of HTTP requests with $var substitution, optional
regex extraction from response bodies, and small control flow
(`on_success: stop`, `on_failure: continue`,
`retry_budget_seconds`). Per-upstream cookie jar persists across
steps via httpx's Client.

**Schema shape.** Each step is:

```yaml
- name: <readable>
  request:
    method: GET|POST|PUT
    url: <full url with $var substitution>
    headers: { ... }            # optional
    params:  { ... }            # optional, URL query params
    json: { ... }     OR        # JSON body (Content-Type: application/json)
    form: { ... }     OR        # form-encoded
    qbit_form: { ... }          # form-encoded with body=`json=<JSON>`
  success_when:                 # optional, default: 2xx
    body_equals: "..."          #   exact-match the response body, OR
    status: 200                 #   exact-match the status code
  extract:                      # optional, pulls regex group 1 from body
    regex: '...(\\S+)...'
    store_as: <varname>
  on_success: continue | stop   # default: continue
  on_failure: raise    | continue  # default: raise
  retry_budget_seconds: <int>   # default: 0 (no per-step retry loop)
```

Drops qbittorrent's existing `posts: app/setPreferences` block —
the steps sequence below IS the password-setting flow.

**Predefined $vars in step context.** `apply_steps` initializes the
ctx with: `$base_url` (upstream's base_url with trailing slash
stripped), `$now_ns`, `$past_24h_ns`, `$past_30d_ns`. The time vars
are convenience anchors for log-store queries that need `start`/`end`
windows — Loki's query_range defaults to a 1h lookback, which is
usually too narrow for finding the temp pw from a boot >1h ago.

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

2. **Add generic `steps:` operation type to configure.py** —
   Sequence of HTTP requests with $var substitution between them,
   regex extraction from response bodies, and small control flow.
   No qbit-specific code. apply_steps initializes the ctx with
   `$base_url`, `$now_ns`, `$past_24h_ns`, `$past_30d_ns`; subsequent
   step `extract.store_as` populates additional vars. Per-upstream
   cookie jar persists via the shared httpx Client.
   *Verify:* `tools/api-config/Dockerfile` builds clean. Smoke-test
   $var substitution and regex extraction locally (no httpx mock
   needed for the pure-Python logic). Integration verify in commit
   5 via real deploy.

3. **Encode qbit auth bootstrap as `steps:` in qbittorrent's
   service.yml.elp** — 5-step sequence:
   probe configured login (stop if it works) → fetch temp pw from
   loki (300s retry budget) → log in with temp pw → POST
   setPreferences with configured creds → verify configured login
   works post-set. All qbit-specific shape (the regex, the
   Referer header, qbit-form encoding, the loki query string)
   lives here, not in configure.py. Drop the existing
   `posts: app/setPreferences` block.
   *Verify:* `make all && grep -A30 '^qbittorrent:'
   config/api-config/resources.yaml` shows the 5-step sequence
   rendered with username/password interpolated.

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

   **Decisions / postmortem:** Deployed successfully but found a
   structural flaw: the probe step (and verify step) hit qbit
   *through caddy*, where qbit sees a non-localhost source IP and
   `AuthSubnetWhitelist=0.0.0.0/0` auth-bypasses *every* endpoint
   including `/auth/login`. `curl -d 'password=wrong_xyz'
   https://hostname:8443/api/v2/auth/login` returns `Ok.` exactly
   like the right password. So the probe is a false-positive
   detector — it can't distinguish "creds work" from "auth-bypassed",
   and `on_success: stop` then short-circuits the steps that
   actually matter. The whole bootstrap dance never triggers.

   Realized the original `posts: app/setPreferences` design was
   correct: setPreferences via caddy auth-bypasses, qbit accepts
   it, computes PBKDF2, persists `Password_PBKDF2=` to qBittorrent.conf.
   Verified by hand-curling exactly that — qbit wrote the hash on
   the first call. Restarting qbittorrent.service then cleared the
   localhost IP-ban (radarr had hammered it for 15h with stale creds)
   and the arrs immediately authed.

   Real root cause of the original outage was *not* missing
   bootstrap logic — it was that **api-config doesn't run when
   qbit restarts**. api-config's `.path` watcher only fires on its
   own rendered config files. When wireguard cascade-restarted qbit
   and qbit lost its in-memory `Password_PBKDF2` (likely
   SIGKILLed mid-flush), nothing told api-config to re-push the
   password.

6. **Revert qbit's `steps:` block back to
   `posts: app/setPreferences`** — The original was right. Drop
   the 5-step sequence, restore the 4-line posts block, update the
   inline comment to record the why (caddy auth-bypass is what
   makes the original correct, LocalHostAuth=true on localhost is
   what makes Password_PBKDF2 needed).
   *Verify:* `make all && grep -A4 '^qbittorrent:'
   config/api-config/resources.yaml` shows the original posts shape
   back.

7. **Trigger api-config from any api-configured service's restart** —
   The actual fix for the recurrence. Edit
   `targets/debian/systemd/__service__.service.elp` to conditionally
   emit `ExecStartPost=/bin/systemctl --no-block start api-config.service`
   when the service has `api_config:` set. Auto-applies to today's
   four upstreams (radarr, sonarr, prowlarr, qbittorrent) and any
   future api-configured service. `--no-block` so the upstream's
   start isn't gated on api-config completion; api-config is
   `Type=oneshot` so multiple triggers during stack-wide boot are
   harmless idempotent runs.
   *Verify:* `make all && grep -A2 ExecStartPost
   config/systemd/qbittorrent.service` shows the trigger line.
   `grep -L ExecStartPost config/systemd/{caddy,grafana,prometheus,…}.service`
   confirms non-api-configured services don't get it. After deploy:
   `sudo systemctl restart qbittorrent.service && sleep 3 && sudo
   journalctl -u api-config.service --since '30s ago'` shows
   api-config triggered automatically.

## What's worth keeping from the bootstrap detour

- **`Loki :3100 on 127.0.0.1`** (commit 1) — was added for the
  bootstrap, but stays as a debugging convenience: `curl loki`
  from the host without a sidecar container. Bound to loopback,
  no tailnet exposure.
- **Generic `steps:` engine in `tools/api-config/configure.py`**
  (commit 2) — small (~100 LoC), well-shaped primitive for any
  future upstream that needs multi-step API flows (login → fetch
  X → use X → verify). Today no consumer; documented in
  configure.py's docstring so the next contributor sees the
  capability.
- **Commits 3 (qbit `steps:`)** and the related `make api-config-publish`
  in commit 4 — reverted in commit 6. The pushed image happens to
  contain the steps engine which is useful regardless.

## Future plans

- **Alert on qbit's `temporary password is provided` log line.**
  Catches the root cause early: any time qbit boots without
  Password_PBKDF2, alloy ships the line to loki within seconds, an
  alert fires. Two implementation paths: (a) alloy emits a metric
  on regex match, prom rule alerts on it; (b) enable loki ruler.
- **Backstop alert on arrs' `Failed to authenticate with qBittorrent`
  log line.** The existing `ServiceLogErrors` rule keys on priority
  ≤3; arrs log this at `[Warn]` (priority 4), so the rule misses
  it. Either widen for arrs specifically or add a Loki-pattern rule.

## Non-goals

- Generalize the bootstrap operation to a "log-scrape any
  secret from any service" primitive. Re-evaluate when a second
  consumer appears.
- Mount docker.sock in api-config. Loki path is the choice (the
  steps engine kept that option open if anyone reaches for it).
- Touch the deploy mechanic's handling of `qBittorrent.conf`.
  Verified during the postmortem: setPreferences persistence works
  fine, the rsync isn't stripping anything. Original Future-plans
  entry on this was wrong.
