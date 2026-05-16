# Caddy

The single HTTPS front door for the stack. Caddy terminates TLS using
the cert issued by `tailscale cert` and reverse-proxies each service
under its `/<name>` path (with a few services on dedicated ports for
clients that can't do path-based routing).

`Caddyfile.elp` is the routing config; it's assembled from each
service's manifest entry so adding a service automatically gets it a
route.

## Gateway auth (forward_auth)

A service that sets `gateway_auth:` (see
[CONTRIBUTING.md](../../CONTRIBUTING.md)) gets a `forward_auth` block
injected ahead of its `reverse_proxy`, in both the path-routed and
dedicated-port sites, pointed at the Authelia portal
(`/api/authz/forward-auth`). Unauthenticated requests are bounced to
Authelia and back; `Remote-User`/`Remote-Groups`/`Remote-Email`
/`Remote-Name` are copied to the upstream. Keyed on the derived
`gateway_protected` boolean — services that don't opt in render
exactly as before (the conditional emits nothing).

Authelia itself is **not** gated (it's the gateway; gating it with
itself would loop) and it sets `proxy_preserve_host: true` so its
dedicated-port block skips the qBittorrent-specific
`header_up Host {upstream_hostport}` rewrite — Authelia needs the
original `Host` + `X-Forwarded-*` for cookie/portal correctness, which
Caddy's `reverse_proxy` default already provides. The monitoring stack
(Prometheus/Grafana/Alertmanager) is intentionally left un-gated as a
break-glass path to debug the portal itself.

## More

- Upstream: <https://github.com/caddyserver/caddy>
- Docs: <https://caddyserver.com/docs/>
