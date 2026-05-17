# api-config

Reconciles the HTTP-API-driven config of the *arr apps and qBittorrent
to match what's declared in YAML — so settings like "Radarr's download
client is qBittorrent at this URL with this password" live in version
control instead of being clicked through each app's web UI.

Runs as a oneshot on deploy: reads `upstreams.yaml` (which services to
talk to) and `resources.yaml` (what state they should be in), makes the
HTTP calls, and exits.

## Auth-exempt by topology (why it's on mediaserver-network)

api-config sits on `mediaserver-network` and reaches each upstream by
its **`internal_url`** — `http://<name>:<port>` for bridge services,
`http://wireguard:<port>` for VPN-netns ones (the wireguard container
holds their netns and is itself on mediaserver-network, so it's the
same address caddy reverse-proxies to). It deliberately does **not**
go through caddy.

This is load-bearing for the auth gateway. caddy's `forward_auth`
gates the *whole* caddy site for a gated service, so if api-config
reached upstreams via their public URL, gating any of them would 302
api-config to the Authelia portal (httpx doesn't follow redirects →
the reconcile step fails). Going direct bypasses the gate entirely
(forward_auth is caddy-only), so **api-config stays auth-exempt
without any per-path bypass** — that's the whole reason a gated arr /
qBittorrent / Open WebUI doesn't break its reconcile. It was
previously `network_mode: host` + public-URL-through-caddy for
uniformity; the gateway invalidated that calculus. `configure.py`
treats `base_url` as an opaque HTTP base (no TLS pinning), so plain
http to a docker-DNS name needs no cert/FQDN — the host-net rationale
left with it.

## More

- Upstream: <https://github.com/ramfjord/api-config>
