# per-service chmod override

Caddy's certs (and other secret-shaped files) flow through deploy.sh's generic `Dg+s,Fg+w` rsync, leaving private keys group-writable to `mediaserver`. Need a way to opt into stricter modes (e.g. `D750,F640` for certs) per service so the generic deploy path doesn't have to special-case them.
