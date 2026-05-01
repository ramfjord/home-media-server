# vs. docker-compose-nas

Comparison with [docker-compose-nas](https://github.com/AdrienPoupa/docker-compose-nas), a more battle-tested alternative covering similar ground.

| Aspect | This Project | docker-compose-nas |
|---|---|---|
| Service management | Per-service systemd units + Docker | Pure Docker Compose |
| Remote access | Tailscale (private) | Internet-facing (Traefik + Let's Encrypt) |
| Reverse proxy | Caddy (internal + HTTPS where required) | Traefik (internet ingress) |
| Monitoring | Prometheus + Grafana + Alertmanager + OTel | Live dashboard only |
| Config | Per-service YAML + ELP (Lisp) templates | Individual compose files |
| Compose layout | One compose file per service on shared `mediaserver-network` | Single monolithic compose file |
