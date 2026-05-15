# api-config

Reconciles the HTTP-API-driven config of the *arr apps and qBittorrent
to match what's declared in YAML — so settings like "Radarr's download
client is qBittorrent at this URL with this password" live in version
control instead of being clicked through each app's web UI.

Runs as a oneshot on deploy: reads `upstreams.yaml` (which services to
talk to) and `resources.yaml` (what state they should be in), makes the
HTTP calls, and exits.

## More

- Upstream: <https://github.com/ramfjord/api-config>
