# WireGuard

VPN tunnel to an external VPN provider. The downloading stack
(Radarr, Sonarr, Prowlarr, qBittorrent) joins this container's
network namespace via `network_mode: container:wireguard`, so all of
their outbound traffic exits through the VPN provider rather than the
home IP.

Distinct from Tailscale (which runs on the host for remote *access*);
WireGuard here is purely about masking outbound downloader traffic.

## More

- Project: <https://www.wireguard.com/>
- Upstream (image): <https://github.com/linuxserver/docker-wireguard>
