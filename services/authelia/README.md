# Authelia

Single sign-on / forward-auth portal. Authenticates a user once, then
the reverse proxy gates the gateway-opted-in web UIs against that
session (wired in a later commit via the per-service `gateway_auth:`
field — see [CONTRIBUTING.md](../../CONTRIBUTING.md)). One process,
SQLite + flat-YAML config, no Redis/Postgres — the minimal-deps
constraint.

## Required `config.local.yml` keys

Authelia's secrets and the user record are **required** and live in
git-ignored `config.local.yml` under `service_overrides.authelia`.
They are read via `for-service` (not `getf`), so `make all` fails
fast with `Unknown field :jwt_secret` until they're present — the
same uniform "your `config.local.yml` is incomplete" behaviour as
grafana/smtp, on purpose. Add:

```yaml
service_overrides:
  authelia:
    jwt_secret: "<rand>"
    session_secret: "<rand>"
    storage_encryption_key: "<rand>"
    user_username: "thomas"
    user_displayname: "Thomas"
    user_email: "thomas.ramfjord@gmail.com"
    user_password_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."
```

Generate them with the pinned image (no local Authelia install
needed):

```sh
# each of the three secrets (≥64 chars; run three times)
docker run --rm authelia/authelia:4.39.19 authelia crypto rand --length 64 --charset alphanumeric

# the password hash (argon2id) — never store the plaintext
docker run --rm authelia/authelia:4.39.19 \
  authelia crypto hash generate argon2 --password 'your-password'
```

The hash is a one-time manual bootstrap. It's a *secret*, and every
secret in this repo already lives out-of-band in `config.local.yml`
as plaintext (grafana/qbittorrent/smtp) — a hash there is strictly
better, not a new wart.

## Why a dedicated port, not `/authelia`

Authelia officially recommends a dedicated subdomain/root; subpath
deployment needs `server.path` plus dynamic base-tag handling and is
its documented finicky path. This tailnet host has no subdomains, so
Authelia takes a dedicated host port (`9091`) — the same escape hatch
vaultwarden (`8000`) and qBittorrent (`8443`) use. caddy publishes
`9091:9091` (see `services/caddy/service.yml.elp`).

## Host-header handling (resolved)

The generic dedicated-port caddy site block rewrites `Host` to the
upstream hostport (`header_up Host {upstream_hostport}`) — a
qBittorrent-specific requirement that is **wrong for Authelia**, which
needs the original `Host` plus `X-Forwarded-*` for cookie-domain and
portal-URL correctness. Resolved: `service.yml.elp` sets
`proxy_preserve_host: true`, a single-consumer optional field that
makes `services/caddy/Caddyfile.elp` skip the `header_up Host` line
for this service. Caddy's `reverse_proxy` default already preserves
`Host` and sets `X-Forwarded-*`, so the plain block is correct.

## Scope notes

- Auth: one-factor (username+password) default. `policy: two_factor`
  is per-service opt-in (later commit); when enabled it will be
  WebAuthn/passkey via Bitwarden/Vaultwarden, not TOTP.
- Notifier: the in-stack `smtp` relay (`smtp:25`, plaintext internal
  hop); the relay authenticates upstream. No extra credential.
- Break-glass: Prometheus/Grafana/Alertmanager are intentionally left
  un-gated so the monitoring stack stays reachable to debug Authelia
  itself.

## Operational (learned from the canary deploy)

- **No `command:`** in `service.yml.elp`. The official image's
  entrypoint already runs `authelia` with the default config path
  `/config/configuration.yml` (our volume mounts it there). Passing a
  bare `--config=…` as the container command makes `entrypoint.sh`
  fail with `exec: illegal option --` and crash-loop. `validate-config`
  cannot catch this — it never exercises the entrypoint.
- **`notifier.disable_startup_check: true`.** Authelia otherwise runs
  a notifier probe at boot and exits *fatally* if `smtp:25` isn't
  answering yet — turning a briefly-unready relay into an Authelia
  crash-loop, and (since Authelia gates routes via forward_auth)
  taking every gated service down with it. Auth must come up
  independent of email; `make install` ordering is best-effort only.
- Verifying the container locally: never bind-mount the repo's
  `config/authelia` writable — Authelia writes `db.sqlite3` as root
  and blocks the next `make all`. Use a throwaway dir and
  `--user "$(id -u):$(id -g)"`.

## More

- Upstream: <https://github.com/authelia/authelia>
- Config reference: <https://www.authelia.com/configuration/>
