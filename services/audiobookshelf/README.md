# Audiobookshelf

Self-hosted audiobook and podcast server ([audiobookshelf.org](https://www.audiobookshelf.org/)),
with native Android/iOS apps. SQLite-backed, single container.

## Networking

Path-routed under the main 443 site at `https://<fqdn>/audiobookshelf`.

`/audiobookshelf` is not a free choice — it's the **only** subpath
Audiobookshelf supports, fixed upstream. The server rewrites any request
whose path doesn't already start with `ROUTER_BASE_PATH` to include it,
so caddy needs no path-stripping and api-config can use `internal_url`
unchanged. That fixed path is also why this service doesn't need the
dedicated-host-port treatment vaultwarden/vikunja/qbittorrent get.

## Auth

Audiobookshelf authenticates through Authelia via **OpenID Connect**,
not through the caddy gateway. It declares no `gateway_auth:`.

The reason is the mobile apps: caddy `forward_auth` returns a redirect
to Authelia on every request, including the `/api` calls the apps make,
and the apps can't complete that flow. Gating at the edge would leave
the service usable only in a browser — for an audiobook server, that
removes the primary use case. This is the same trade Vikunja resolved
the same way.

OIDC covers the apps because Authelia's client registers the app's
custom scheme (`audiobookshelf://oauth`) alongside the two web
callbacks, so the code flow completes in-app.

`authOpenIDSubfolderForRedirectURLs` is on, which is what makes ABS
advertise its callbacks under `/audiobookshelf/...`. Without it ABS
emits them at the host root, caddy doesn't route them, and Authelia
rejects the request as a `redirect_uri` mismatch.

### Local login stays enabled

`authActiveAuthMethods` is `["local", "openid"]` — deliberately unlike
Vikunja, which disables local login. If OIDC breaks (Authelia down, a
client-secret drift, a misconfigured redirect), Audiobookshelf's only
documented recovery is editing its SQLite database by hand. The root
account is break-glass that avoids that, and it costs nothing extra
because api-config already holds the password to drive the reconcile.

`authOpenIDAutoLaunch` is `false` for the same reason: the ABS login
page stays reachable rather than bouncing straight to Authelia.

## Config as code

Settings → Authentication is **reconciled on every deploy** by
api-config, not clicked through the UI. The three-step flow in
`service.yml.elp`:

1. `POST /init` — creates the root user. Returns 500 once one exists,
   i.e. every deploy after the first; `on_failure: continue` logs that
   at WARNING (not ERROR), keeping it out of `ServiceLogErrors`.
2. `POST /login` — extracts the bearer from `user.accessToken`. Note
   this is *not* the flat `"token"` key open-webui matches on; ABS
   v2.26 reworked its auth and nested it. Carries a
   `retry_budget_seconds` because steps get no transport-level retry
   and this can race ABS's first-boot migrations.
3. `PATCH /api/auth-settings` — writes the whole OIDC block. Idempotent
   by construction: ABS diffs before persisting.

Consequence worth knowing: **manual UI edits to Settings →
Authentication are clobbered on the next deploy.** Change
`service.yml.elp` instead.

Step 3 spells out the authorization/token/userinfo/JWKS URLs
explicitly. ABS derives nothing from the issuer server-side — the
"Auto-populate" button in its UI is a client-side fetch of the
provider's discovery document, so an issuer-only PATCH would leave the
endpoints null.

### `PATCH /api/auth-settings` fails silently per-field

The endpoint returns **200 even when it rejects individual fields**. It
loops over the keys it knows, type-checks each one, and `continue`s past
any that don't match — logging a `WARN` to *ABS's* log, not to the HTTP
response. api-config sees a 200 and reports success.

So a green reconcile does not prove the settings landed. Two field
shapes are easy to get wrong, and both did on first deploy here:

- `authOpenIDSubfolderForRedirectURLs` is a **string** path prefix
  (`/audiobookshelf`), not a boolean. ABS builds redirect URIs as
  `` `${this}/auth/openid/callback` ``; `''` means no subfolder.
- `authActiveAuthMethods` is filtered against `supportedAuthMethods`,
  and a filtered-empty or unchanged result is a silent no-op.

To verify a change actually applied, read it back rather than trusting
the 200:

```sh
curl -s http://<abs-ip>/audiobookshelf/status          # authMethods
docker logs audiobookshelf 2>&1 | grep "Invalid value" # rejected fields
```

## Host user

Runs under a dedicated `audiobookshelf` host user (the `user:` field
defaults to the service name). Must exist before first deploy —
`chownall` resolves it with `id -u audiobookshelf`:

```sh
sudo useradd -r -s /usr/sbin/nologin audiobookshelf
```

## Media

- `<media_path>/Audiobooks` → `/audiobooks`
- `<media_path>/Podcasts` → `/podcasts`

Both mounted read-write — ABS writes podcast downloads. The service
user is in the `mediaserver` group, which owns those directories.

Libraries still have to be pointed at those paths once in the UI —
library definitions are not reconciled by api-config.

## Why metadata isn't its own bind mount

`METADATA_PATH=/config/metadata` puts scan artifacts (cover art,
extracted metadata) inside the config volume instead of the separate
`/metadata` mount ABS's own docs suggest.

A second bind at `<install_base>/config/audiobookshelf/metadata` breaks
the *first* deploy: the deploy's `chown -R` runs over the service dir
before the container exists, docker then creates the missing bind
target as `root:root`, and ABS exits with `EACCES: mkdir
'/metadata/logs'`. A redeploy fixes it, which is what makes the bug
easy to miss. As a plain subdirectory, ABS creates it itself as the
service user inside a tree that user already owns.

The same trap applies to any nested bind mount under a service dir
that receives no shipped files.

## Monitoring

A homer tile asset (`services/homer/assets/tools/audiobookshelf.png`)
makes it `displayable`, so the public blackbox probe hits `public_url`.
The probe uses the `http_basic` module (expects 2xx) rather than
`http_gated` — correct here, since the service isn't behind
forward_auth and its landing page returns 200 to an anonymous request.

The internal probe hits `/audiobookshelf/healthcheck`, which returns a
bare 200.

**What this misses:** the probe only proves the HTTP server is up. A
broken OIDC config (bad secret, Authelia unreachable) still serves a
200 landing page, so login being broken does *not* fire an alert — the
api-config reconcile failing is the signal for that
(`ApiConfigReconcileFailed`, `service=audiobookshelf`). A library that
has stopped scanning is not covered at all.
