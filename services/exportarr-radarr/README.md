# exportarr-radarr

Sidecar that polls Radarr's HTTP API and re-exposes the data as
Prometheus metrics — queue size, missing movies, indexer health, etc.
Radarr itself doesn't speak Prometheus, so this is the bridge.

## More

- Upstream: <https://github.com/onedr0p/exportarr>
