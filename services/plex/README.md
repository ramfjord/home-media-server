# Plex

Second media server alongside [Jellyfin](../jellyfin/). Plex earns its
place for the **remote-TV** case: Roku / smart-TV apps can't join the
tailnet, so they need a server reachable over the public internet —
and Plex's own remote access handles exactly that. The server
heartbeats its current public IP to plex.tv, so clients route
themselves regardless of how often the home IP rotates; the only
host-side requirement is a router port-forward of `:32400`. Jellyfin
and the arr suite stay tailnet-only behind caddy; Plex is the one
deliberately internet-reachable surface.

## Why host networking (not caddy)

Same as Jellyfin: `network_mode: host` so GDM/DLNA discovery
broadcasts reach LAN clients and Plex binds `:32400` (plus its
discovery ports) directly. `derive.lisp` infers `proxied: false` from
the host network mode, so caddy never proxies Plex — its apps speak to
`:32400` directly. Plex also serves at `/` and doesn't do subpath
routing cleanly, so a caddy route would be the wrong shape anyway.

## Migration from the bare-metal install

Plex was previously a host `plexmediaserver.service`. Moving it
in-stack is a data migration, not a fresh setup — a fresh container
would be a *new* server identity, forcing a re-claim and breaking
existing shares. The migration preserves identity, libraries, watch
state, and shares (no claim token needed):

1. Stop + disable the old `plexmediaserver.service` (never run both
   against the same data dir — two Plex processes corrupt the DB).
2. `rsync /var/lib/plexmediaserver/Library` →
   `$install_base/config/plex/Library`, owned `plex:plex`.
3. Mount media at the container path the migrated DB already stores —
   here `/media/Movies` and `/media/TV` (the same mapping jellyfin
   uses: `$media_path/Movies:/media/Movies:ro`). Plex stores absolute
   library paths, so the mount must land them where the DB expects or
   libraries show "unavailable". (The old bare-metal install used
   `/media/...`, so this matches with no repathing in Plex's UI.)

The `plex` host user (uid 997, gid 989) left by the old Debian package
is reused: the chownall owner defaults to the service name `plex`, the
compose template forces `user: ${SVC_UID}:${SVC_GID}` = `997:989`, and
the migrated data is already `plex:plex` — so the container runs as the
uid that owns its data with no re-chown.

## Image

`lscr.io/linuxserver/plex` — matches the stack's forced-`user:`
linuxserver pattern (as qBittorrent does) and lays `/config` out as
`/config/Library/Application Support/Plex Media Server`, the same
subtree the migrated data uses.

## Not yet wired (follow-ups)

- **Metrics / health probe.** No Prometheus scrape or blackbox probe
  yet (Plex exposes no native `/metrics`; a tautulli-style exporter
  would be the path). Mirrors Jellyfin, which is also unscraped.
- **Transcode scratch.** Transcodes land in `/config` (the data
  volume). A dedicated `/transcode` mount + Plex's "Transcoder
  temporary directory" setting would keep scratch off the data dir.
- **GPU transcoding.** NVIDIA passthrough via `service_overrides`
  (Plex Pass required), same shape as Jellyfin's override. Not enabled.

## More

- Upstream (image): <https://github.com/linuxserver/docker-plex>
- Docs: <https://support.plex.tv/>
