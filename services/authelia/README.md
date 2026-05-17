# Authelia

Single sign-on / forward-auth portal. Authenticates a user once, then
Caddy gates the gateway-opted-in web UIs against that session via the
per-service `gateway_auth:` field (see
[CONTRIBUTING.md](../../CONTRIBUTING.md)). Currently gated:
radarr/sonarr/prowlarr, qBittorrent, Open WebUI. Homer and the
monitoring stack (Prometheus/Grafana/Alertmanager) are deliberately
left un-gated — the latter as break-glass (see Scope notes).
api-config is auth-exempt by topology (reaches upstreams directly off
mediaserver-network, never through caddy) — see
[services/api-config/README.md](../api-config/README.md). One process, SQLite +
flat-YAML config, no Redis/Postgres — the minimal-deps constraint.

## Required `config.local.yml` keys

Authelia's secrets and the `users` list are **required** and live in
git-ignored `config.local.yml` under `service_overrides.authelia`.
They are read via `for-service` (not `getf`), so `make all` fails
fast (`Unknown field :jwt_secret`, `Unknown field :users`, or a named
per-user `:password_hash` error) until they're present — the same
uniform "your `config.local.yml` is incomplete" behaviour as
grafana/smtp, on purpose. Shape:

```yaml
service_overrides:
  authelia:
    jwt_secret: "<rand>"
    session_secret: "<rand>"
    storage_encryption_key: "<rand>"
    users:
      - username: thomas
        displayname: Thomas
        email: thomas.ramfjord@gmail.com
        password_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."
        groups: [admins]
      - username: ruby
        password_hash: "$argon2id$..."
        groups: [users]
```

Per user: `username` and `password_hash` are required;
`displayname` (defaults to `username`), `email`, and `groups` are
optional. `groups` is advisory until per-app `access_control` rules
exist — `access_control` is currently just `default_policy:
one_factor` (any authenticated user reaches any gated app).

Generate the three secrets with the pinned image (no local Authelia
install needed):

```sh
# each of the three secrets (≥64 chars; run three times)
docker run --rm authelia/authelia:4.39.19 authelia crypto rand --length 64 --charset alphanumeric
```

## Adding / resetting a user

```sh
script/authelia-adduser <username> [-e email] [-n displayname] [group...]
```

generates a strong random password, argon2id-hashes it via the pinned
image, and prints the plaintext **once** plus a ready-to-paste
`config.local.yml` block. It does **not** edit `config.local.yml` —
paste the block under `service_overrides.authelia.users:` yourself
(reset = paste over the existing entry), then redeploy.
`authentication_backend.file.watch: true` makes Authelia hot-reload
the users file, so a reset/add takes effect without restarting
Authelia (no gated-stack blip).

**No self-service reset by design.** `users_database.yml` is
config-as-code; an in-product reset would write to the file and be
clobbered on the next deploy. `password_reset.disable: true` turns the
in-product flow off so the only path is the script — single source of
truth, at the cost of self-service.

### Why hashes here, and why this does *not* generalise to Jellyfin

Authelia's file backend lets you **declare the argon2id hash**.
Verification is hash-the-input-and-compare; the server never needs
plaintext. So the only plaintext that ever exists is what the script
prints once for you to store in Bitwarden — `config.local.yml` holds
just the hash. A leak there exposes slow, per-user-salted argon2id
hashes, not usable passwords.

This is *better* than the other secrets in `config.local.yml`
(grafana/qbittorrent/smtp), which are plaintext — and it specifically
does **not** transfer to "have api-config provision Jellyfin users."
Jellyfin's (and qBittorrent's) password APIs take the *plaintext* and
hash it server-side; there is no "accept a precomputed hash"
interface. A reconciler must hold what it replays, so api-config-
provisioned Jellyfin users would require **per-human plaintext
passwords persisted in `config.local.yml`** — a category escalation
over the single infra credential qBittorrent already keeps there.
That asymmetry is the standing reason Jellyfin/qBittorrent user
provisioning is *not* folded into this gateway; revisit only with a
real secret store, not `config.local.yml`.

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
