# Vikunja

Self-hosted task management ([vikunja.io](https://vikunja.io)). Single
unified container serving both API and web UI on `:3456`, SQLite-backed.

## Networking

Dedicated caddy site on a host port — `public_port: 8004`,
`public_path: /`, reached at `https://<fqdn>:8004/` under caddy's single
TLS cert (same pattern as vaultwarden and qbittorrent).
`VIKUNJA_SERVICE_PUBLICURL` is that browser-facing URL (scheme +
trailing slash): the frontend uses it to find the API, and Vikunja uses
it in outgoing emails.

## Auth

Vikunja authenticates through Authelia via **OpenID Connect**
(`VIKUNJA_AUTH_OPENID_*`, provider id `authelia`): an unauthenticated
request is redirected to Authelia to log in. Local username/password
login is disabled (`VIKUNJA_AUTH_LOCAL_ENABLED=false`), so OIDC is the
only identity. The `:8004` site is a plain reverse proxy, so native
clients (mobile app, MCP, CLI, CalDAV) reach `/api` directly and
authenticate with Vikunja's own OIDC / API-token auth.

Because OIDC is the only way in, Vikunja must reach Authelia's discovery
endpoint at boot; a `systemd_override` gates startup on Authelia's
docker healthcheck (the wireguard-readiness pattern) so it never comes
up against an unready Authelia.

The OIDC client secret is one logical secret in two homes: Vikunja holds
the **plaintext** (`config.local.yml` `service_overrides.vikunja.oidc_client_secret`),
Authelia holds its **pbkdf2 hash** (`service_overrides.authelia.oidc_vikunja_client_secret_hash`).
See `services/authelia/README.md` → "OIDC secrets" for generation.

## Secret

`VIKUNJA_SERVICE_SECRET` (the JWT signing secret) is required, read from
`config.local.yml` (`service_overrides.vikunja.jwt_secret`) via
`for-service` so a missing value fails `make all`. It's pinned so
sessions survive restarts. Generate with `openssl rand -base64 48`.

## Host user

Runs under a dedicated `vikunja` host user (uid isolation for its `/db`
+ `/files` volumes). The user must exist on the deploy host before first
deploy — `chownall` chowns the config dir to it via `id -u vikunja`:

```sh
sudo useradd -r -s /usr/sbin/nologin vikunja
```

## Monitoring

A homer tile asset (`services/homer/assets/tools/vikunja.png`) makes it
`displayable`, so the public blackbox probe hits `public_url`
(`https://<fqdn>:8004/`, a 2xx) — a dead Vikunja port fires
`BlackboxProbeFailed`.

## Persistent data

- `config/vikunja/db/vikunja.db` — SQLite database
- `config/vikunja/files/` — uploaded attachments
