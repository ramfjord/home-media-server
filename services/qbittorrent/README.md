# qBittorrent

The torrent client that actually downloads what Radarr and Sonarr
ask for. Shares WireGuard's network namespace so all torrent traffic
exits via the VPN provider; Radarr/Sonarr reach it over the shared
netns and Caddy proxies the web UI in.

## More

- Project: <https://www.qbittorrent.org/>
- Upstream (app): <https://github.com/qbittorrent/qBittorrent>
- Upstream (image): <https://github.com/linuxserver/docker-qbittorrent>
