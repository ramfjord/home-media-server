# Open WebUI

Chat interface for talking to local LLMs. Points at Ollama as its
backend, so any model `ollama pull`ed onto the host is available
through the web UI.

## Auth: Authelia trusted-header SSO

Gated behind Authelia (`gateway_auth: true`). caddy's `forward_auth`
authenticates the human and copies `Remote-Email`/`Remote-Name` onto
the proxied request; `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` /
`WEBUI_AUTH_TRUSTED_NAME_HEADER` make Open WebUI trust them and
auto-provision/log-in that user — **no separate Open WebUI login**.

The api-config admin (`admin_email`/`admin_password`) is **not**
removed: api-config reaches OWUI directly on mediaserver-network
(`http://open-webui:8080`, no caddy → no `Remote-*` header) and still
authenticates its signin/bootstrap flow with that account. It is now
purely an **M2M service account** (drives the Grafana tool-server +
Grafana-Assistant model reconcile); humans no longer use it. OWUI's
own `/api/*` keeps its bearer auth, so no `public_paths` carve-out is
needed — Authelia gates the page, OWUI gates its API.

**Fresh-DB admin race (DR-only caveat).** OWUI makes the *first-ever*
user an admin. On the existing persistent DB the api-config admin
already exists, so humans arriving via SSO are regular users — fine.
On a *from-scratch* DB there's an order race: if a human browses in
(trusted-header → auto-provisioned, becomes admin) before api-config's
first reconcile creates the admin account, the roles invert and the
Grafana-Assistant reconcile (which needs an admin token) silently
degrades (its steps are `on_failure: continue`). Recovery: clear the
errant user / promote the api-config account in OWUI, redeploy. Only
relevant on disaster-recovery rebuilds, not normal deploys.

**Verify post-deploy:** chat streaming uses websockets through
`forward_auth` — confirm a streamed response works after the first
deploy with gating on (the one interaction render/validate can't
catch).

## More

- Upstream: <https://github.com/open-webui/open-webui>
- Docs: <https://docs.openwebui.com/>
