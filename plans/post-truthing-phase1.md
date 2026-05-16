# Post-truthing phase 1

Make the claims in `tmp/media-server-post` accurate without taking on
the larger aspirational items it implies (those are phase 2 — see
`Future plans` below). Mostly docs + one bash script + one parameterization.

## Goal

After this branch ships:

1. The Discord webhook URL is sourced from `config.local.yml`, not
   hard-coded in the rendered alertmanager config.
2. `script/generate-local-config.sh` exists and produces a working
   `config.local.yml` with random secrets — readers of the post can
   actually run the command it names.
3. Every `services/<x>/README.md` link in `docs/installation.md` and
   the post resolves to a real file (`alertmanager`, `wireguard`,
   `radarr`, `jellyfin`).
4. `make all` emits `config/vaultwarden/passwords.csv` — one row per
   service with credentials, ready to import into Bitwarden /
   Firefox. The post's "automatically generated password.csv" claim
   stops being aspirational.
5. A short `tmp/post-edits.md` lists the find/replace fixes the post
   itself needs (path/name drift). Not a code change — handed back
   to the user to apply to the post draft.

## Context

Reviewing `tmp/media-server-post` against the repo turned up two kinds
of gap: (a) the post names files/scripts that don't exist, and (b)
one real configuration leak — `services/alertmanager/alertmanager.yml.elp:22`
has a literal Discord webhook URL committed. User has acknowledged the
leak and will rotate the webhook out-of-band; no `git filter-repo`
needed.

Phase 2 (one-line follow-up only; see `Future plans` below).

## Related plans

- **`plans/health-rules-quickfix.md`** (drafted, not started) — adds
  alert *rules* to fire on the next crashloop. Touches
  `services/prometheus/rules/*.yaml.elp`, not `alertmanager.yml.elp`.
  No conflict; this plan parameterizes *where the webhook URL comes
  from*, that plan tunes *what fires*. Either order works.
- **`plans/crashloop-recovery.md`** (drafted, not started) — design
  notes call out that the discord webhook may have been silently
  broken during the 2026-04-25 incident. Parameterizing the webhook
  here makes a future "fire a synthetic alert" smoke test cheaper to
  wire (the test can read the URL from the same place alertmanager
  does).
- **`plans/deploy-rebuild.md`** (drafted, not started) — adds a
  top-level `service_user_ids:` map to `config.local.yml`. The new
  `discord_webhook` key chosen here should sit at the same
  shape-level (top-level key, not under `service_overrides:`) for
  consistency.
- **In-flight worktrees** (`pre-rewrite`, `restructure-per-service`,
  `tailscale-cert`) — none touch `alertmanager.yml.elp`,
  `config.local.yml.example`, `script/`, or
  `services/{wireguard,radarr,jellyfin,alertmanager}/README.md`.
  No expected merge conflicts.

## Design notes

**Webhook key shape.** Top-level `discord_webhook:` in
`config.local.yml`, not nested under `service_overrides.alertmanager`.
Rationale: the URL isn't an alertmanager-internal field that gets
deep-merged into a service definition; it's a project-wide secret
consumed at template-render time. Top-level matches the existing
shape of `hostname:` and (proposed) `service_user_ids:`.

**Default value.** The `service.yml.elp` for alertmanager declares
`discord_webhook: ""` so the field exists in the manifest with a
safe empty default; `config.local.yml` overrides it. The template
renders the URL verbatim — if empty, alertmanager will refuse to
start, which is the right failure mode (loud, immediate).

**README scope.** Each per-service README is short — what the user
needs to do *that isn't already in the service.yml.elp*. Don't
duplicate field documentation.

## Commits

1. **Parameterize Discord webhook through config.local.yml** —
   Add `discord_webhook: ""` field to `services/alertmanager/service.yml.elp`,
   change `alertmanager.yml.elp:22` to `<%= discord_webhook %>`, add
   `discord_webhook:` to `config.local.yml.example` with a comment
   pointing at Discord's webhook-creation docs.
   *Verify:* `make all && grep -r 'discord.com/api/webhooks/[0-9]' config/` returns
   nothing (the URL no longer appears in rendered output unless
   `config.local.yml` supplies it). Render with a test value set in a
   throwaway `config.local.yml` and confirm it lands in
   `config/alertmanager/alertmanager.yml`.

2. **Add `script/generate-local-config.sh`** — Bash script: refuses
   if `config.local.yml` exists; copies from
   `config.local.yml.example`; uses `sed -i` to replace each
   `REPLACE_ME` with a freshly-generated secret (`openssl rand -hex
   16` for `apikey:` lines, `openssl rand -base64 24` for `password:`
   / `relay_password:` lines). Prints the generated file path and a
   reminder to fill in `hostname:`, SMTP relay creds, and
   `discord_webhook:` by hand.
   *Verify:* On a clean checkout, `script/generate-local-config.sh`
   produces a `config.local.yml` for which `make all` succeeds (with
   `hostname:` patched to a placeholder). Re-running the script exits
   non-zero without overwriting.

3. **Write `services/alertmanager/README.md`** — One section per
   rule file under `services/prometheus/rules/`, one bullet per
   alert with its trigger condition in plain English. Forward-link
   to `config.local.yml.example` for the `discord_webhook:` setup.
   *Verify:* `grep -c '^- ' services/alertmanager/README.md`
   matches the count of `alert:` lines across the rule files (or is
   intentionally lower with a stated reason — e.g. dead-man-switch
   stays commented out).

4. **Write `services/wireguard/README.md`** — One-time bootstrap:
   how to drop a provider `.conf` into
   `<install_base>/config/wireguard/wg_confs/`, what `use_vpn: true`
   does (the `network_mode: container:wireguard` injection in
   `lisp/src/derive.lisp`), the healthcheck behavior, and what to
   look for in `journalctl -u wireguard` on first boot.
   *Verify:* `grep -n 'services/wireguard/' docs/installation.md
   README.md` — every link resolves. `markdown-link-check` if
   convenient, otherwise eyeball.

5. **Write `services/radarr/README.md` and
   `services/jellyfin/README.md`** — Radarr: where its `apikey`
   gets seeded from (`config.local.yml` → ENV →
   `RADARR__AUTH__APIKEY`), the `urlbase=/radarr` convention, what
   to do on first boot before api-config has run. Jellyfin: GPU
   transcoding `service_overrides:` snippet (the one referenced
   from the main README's Storage section). Combined commit since
   both READMEs are short and independent of each other; keeps
   commit count down.
   *Verify:* `grep -n 'services/\(radarr\|jellyfin\)/' docs/installation.md
   README.md` — every link resolves.

6. **Add `services/vaultwarden/passwords.csv.elp`** — Bitwarden-format
   CSV template that `loop-services` iterates over services with
   credentials. One row per (service, url) pair: for services with
   `public_url` *and* `internal_url`, emit two rows so the same
   password is auto-filled at either URL. Columns:
   `folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp`.
   For username/password services (qbittorrent, vaultwarden admin if
   present), fill `login_username`/`login_password`. For
   apikey-bearing services (radarr/sonarr/prowlarr), put the key in
   `login_password` and the field name in `notes`. Document in
   `services/vaultwarden/README.md` (new file) that the CSV lands at
   `config/vaultwarden/passwords.csv` after `make all` and how to
   import into Bitwarden.
   *Verify:* `make all && head -3 config/vaultwarden/passwords.csv`
   shows the header and at least one row; column count is uniform
   across all lines (`awk -F, '{print NF}' | sort -u` returns a
   single value).

7. **Write `tmp/post-edits.md`** — Plain markdown checklist of the
   find/replace fixes the post draft needs:
   - `INSTALLATION.md` → `docs/installation.md`
   - `shell` docker compose target → `dev`
   - `config.local.yaml` → `config.local.yml`
   - "systemd cron job" → "systemd timer"
   - "generate-local-config.sh\`\`" (double-backtick typo) → single
     backticks
   - The `api-config` failure paragraph: soften "discord message
     with all the info you need to fix it" to "discord message via
     the SystemdUnitFailed alert" — the alert fires, but the body
     doesn't carry the failing journal lines today.
   *Verify:* User reads the file and applies (or pushes back).

## Future plans

- Audit per-service `.path` unit ExecStart actions to verify the
  "SIGHUP reload vs restart" framing the post uses — likely needs
  either real `ExecReload=` for caddy/prometheus/alertmanager or a
  post wording walk-back.

## Non-goals

- Rewriting Git history to remove the leaked webhook. User has
  acknowledged the leak and will rotate the webhook itself.
- Touching alert *rules* — `health-rules-quickfix.md` owns that.
- Any change to `service.yml.elp` schema beyond the single
  `discord_webhook:` field.
