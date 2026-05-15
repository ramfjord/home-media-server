# Radarr

Movie collection manager. You tell Radarr which movies you want; it
searches indexers (via Prowlarr), hands matches to qBittorrent to
download, then renames and organizes the finished files into the
library that Jellyfin reads.

Runs through the WireGuard VPN netns so indexer search traffic exits
via the VPN provider.

## More

- Upstream: <https://github.com/Radarr/Radarr>
- Docs: <https://wiki.servarr.com/radarr>
