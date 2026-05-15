# Sonarr

TV show collection manager. You tell Sonarr which shows you want; it
searches indexers (via Prowlarr) for new episodes, hands matches to
qBittorrent to download, then renames and organizes the finished files
into the library that Jellyfin reads.

Runs through the WireGuard VPN netns so indexer search traffic exits
via the VPN provider.

## More

- Upstream: <https://github.com/Sonarr/Sonarr>
- Docs: <https://wiki.servarr.com/sonarr>
