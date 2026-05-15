# Caddy

The single HTTPS front door for the stack. Caddy terminates TLS using
the cert issued by `tailscale cert` and reverse-proxies each service
under its `/<name>` path (with a few services on dedicated ports for
clients that can't do path-based routing).

`Caddyfile.elp` is the routing config; it's assembled from each
service's manifest entry so adding a service automatically gets it a
route.

## More

- Upstream: <https://github.com/caddyserver/caddy>
- Docs: <https://caddyserver.com/docs/>
