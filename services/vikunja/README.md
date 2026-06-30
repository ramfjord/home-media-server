# Vikunja

Self-hosted task management ([vikunja.io](https://vikunja.io)). Single
unified container serving both API and web UI on `:3456`, SQLite-backed.

## Why a dedicated port, not a `/vikunja` subpath

Vikunja can't run under a URL subpath with the stock image. Subpath
hosting requires building the frontend from source with
`VIKUNJA_FRONTEND_BASE=/vikunja/` baked in at build time
([docs](https://vikunja.io/docs/running-vikunja-in-a-subdirectory/));
the published image is pre-built for root. Rather than maintain a
custom image rebuilt on every version bump, Vikunja gets its own caddy
site on a dedicated host port (`public_port: 8004`, `public_path: /`) —
the same pattern as vaultwarden and qbittorrent. It still rides caddy's
single TLS cert, just at `https://<fqdn>:8004/` instead of a path.

`VIKUNJA_SERVICE_PUBLICURL` must match that browser-facing URL (scheme +
trailing slash) — behind a proxy it's how the frontend discovers the API
and what Vikunja puts in outgoing emails.

## Auth

Gated behind Authelia (`gateway_auth: true`): caddy emits `forward_auth`
on the `:8004` site and Authelia's global `one_factor` enforces. Vikunja
keeps its own login as well — Authelia is the outer gate, there's no SSO
handoff, so a user authenticates twice (Authelia, then Vikunja). That's
acceptable for a low-traffic personal app; wiring Vikunja's OpenID
Connect to Authelia would remove the second login but is not done here.

## Secret

`VIKUNJA_SERVICE_SECRET` is a required secret read from
`config.local.yml` (`service_overrides.vikunja.jwt_secret`) via
`for-service`, so a missing value fails `make all`. (The older
`VIKUNJA_SERVICE_JWTSECRET` name is deprecated and silently ignored
when `SECRET` is set.) If left unset
Vikunja auto-generates a fresh secret on every boot, which invalidates
all sessions on each restart — hence it's pinned. Generate with
`openssl rand -base64 48`.

## Host user

Runs under a dedicated `vikunja` host user (uid isolation for its
`/db` + `/files` volumes), matching the per-service-user pattern the
rest of the stack uses. The user must exist on the deploy host before
first deploy — `chownall` does `id -u vikunja` and chowns the config
dir to it, but does not create it:

```sh
sudo useradd -r -s /usr/sbin/nologin vikunja
```

(User creation isn't scripted in the deploy yet; it's a manual prereq
for every service, Vikunja included.)

## Monitoring

A homer tile asset (`services/homer/assets/tools/vikunja.png`) makes it
`displayable`, so the public blackbox probe hits `public_url`
(`https://<fqdn>:8004/`, a 2xx) — a dead Vikunja port fires
`BlackboxProbeFailed`. No Prometheus `/metrics` scrape: Vikunja can
expose metrics (`VIKUNJA_METRICS_ENABLED`) but it isn't wired here yet.

## Persistent data

- `config/vikunja/db/vikunja.db` — SQLite database
- `config/vikunja/files/` — uploaded attachments
