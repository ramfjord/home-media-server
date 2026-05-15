# exportarr-sonarr

Sidecar that polls Sonarr's HTTP API and re-exposes the data as
Prometheus metrics — queue size, missing episodes, indexer health, etc.
Sonarr itself doesn't speak Prometheus, so this is the bridge.

## More

- Upstream: <https://github.com/onedr0p/exportarr>
