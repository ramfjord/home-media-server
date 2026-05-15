# qbittorrent-exporter

Sidecar that polls qBittorrent's HTTP API and re-exposes the data as
Prometheus metrics — active torrents, transfer rates, queue state.
qBittorrent doesn't speak Prometheus natively, so this is the bridge.

## More

- Upstream: <https://github.com/esanchezm/prometheus-qbittorrent-exporter>
