# qBittorrent

The torrent client that actually downloads what Radarr and Sonarr
ask for. Shares WireGuard's network namespace so all torrent traffic
exits via the VPN provider; Radarr/Sonarr reach it over the shared
netns and Caddy proxies the web UI in.

## Auth model (gated, but no double-login)

qBittorrent has **no** External/trusted-header auth mode — its WebUI
auth *is* its API auth. Three callers, three paths:

- **Browser** → caddy → `forward_auth` (Authelia gates) → `wireguard:8080`.
  qBit sees a non-localhost source; `AuthSubnetWhitelist=0.0.0.0/0`
  (set in `qBittorrent.conf.elp`) makes qBit ask for **nothing**, so
  Authelia is the *only* gate — no second qBit login.
- **api-config** → `wireguard:8080` directly on mediaserver-network
  (not via caddy), non-localhost → same whitelist bypass. forward_auth
  never sees it, so gating doesn't break the password reconcile.
- **arrs** → qbit at `localhost:8080` inside wireguard's netns →
  `LocalHostAuth=true` → they authenticate with the `Password_PBKDF2`
  creds api-config persists via `app/setPreferences`.

Accepted risk: `AuthSubnetWhitelist=0.0.0.0/0` means *any* client
reaching `wireguard:8080` is qbit-unauthenticated — fine for the
browser path (Authelia now fronts it) and the in-stack callers, and
the box has no internet-facing ports. **Optional, separable
hardening:** narrow the whitelist from `0.0.0.0/0` to the docker
bridge subnet (defense-in-depth; not required for correctness — the
browser gate is Authelia, the in-stack callers are on that subnet).

## More

- Project: <https://www.qbittorrent.org/>
- Upstream (app): <https://github.com/qbittorrent/qBittorrent>
- Upstream (image): <https://github.com/linuxserver/docker-qbittorrent>
