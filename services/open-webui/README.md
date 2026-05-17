# Open WebUI

Chat interface for talking to local LLMs. Points at Ollama as its
backend, so any model `ollama pull`ed onto the host is available
through the web UI.

## Auth: Authelia trusted-header SSO

Gated (`gateway_auth: true`). caddy `forward_auth` copies
`Remote-Email`/`Remote-Name`; `WEBUI_AUTH_TRUSTED_*_HEADER` make OWUI
trust them — no separate OWUI login. api-config reaches OWUI directly
(no caddy) and self-asserts the same `Remote-Email` (= `admin_email`,
which must equal the Authelia user's email), so api-config and the
human resolve to one OWUI user. Trusted-header mode ignores passwords;
`open-webui.admin_password` is unused.

First authenticator on a fresh OWUI DB becomes admin. Sharing the
email makes order moot — whoever's first creates the shared admin, the
other logs into it — unless a *different*-email user logs in before
api-config, who is then admin (recovery: clear that user, redeploy).
DR-only.

**Verify post-deploy:** chat streaming uses websockets through
`forward_auth` — confirm a streamed response works after the first
deploy with gating on (the one interaction render/validate can't
catch).

## More

- Upstream: <https://github.com/open-webui/open-webui>
- Docs: <https://docs.openwebui.com/>
