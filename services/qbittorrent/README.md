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

## VPN containment

qBittorrent shares wireguard's netns, which contains both `wg0` (the
tunnel) and `eth0` (the docker bridge → host → home IP). Containment is
layered:

1. **libtorrent pinned to `wg0`** (`Session\Interface` /
   `Session\InterfaceName` in `qBittorrent.conf.elp`). Fail-closed: if
   `wg0` is absent, transfers stall rather than falling back to `eth0`.
   Does **not** by itself cover tracker/DHT/DNS — libtorrent's
   interface bind has historically excluded those.
2. **netns killswitch** (wireguard) — the categorical backstop:
   anything leaving on a non-`wg0` interface (except the docker subnet,
   which carries the WebUI / api-config / arr paths) is dropped,
   independent of qBittorrent's config or wg-quick lifecycle timing.
3. **healthcheck verifies VPN egress**, not mere reachability, so qbit
   is never gated open onto a leaky path.

`qBittorrent.conf` is shipped (not `sync_exclude`d), so the `wg0` pin
applies on deploy + `make restart-qbittorrent`; qbit preserves the
keys on its own rewrites.

## More

- Project: <https://www.qbittorrent.org/>
- Upstream (app): <https://github.com/qbittorrent/qBittorrent>
- Upstream (image): <https://github.com/linuxserver/docker-qbittorrent>
