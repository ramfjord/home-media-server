# cAdvisor

Exposes per-container resource usage — CPU, memory, network, disk I/O —
as Prometheus metrics. Answers "which container is eating all the RAM?"
at a glance in Grafana.

## Docker health is monitored only through cadvisor

cadvisor is the **sole producer** of `container_health_state` (the
docker healthcheck verdict: `1` healthy, `0` unhealthy, `-1` no
healthcheck). The `ContainerUnhealthy` alert keys on it — nothing else
in the stack observes docker health, since an unhealthy-but-running
container keeps `up==1` and a green systemd unit. Two consequences:

- The image is **pinned** (not `:latest`): a cadvisor upgrade that
  renames or drops `container_health_state` would silently blind
  `ContainerUnhealthy`, so it must arrive as a reviewable diff.
- If cadvisor's own scrape goes down, `TargetDown` covers it; if it's
  up but stops emitting the metric, that gap is currently unguarded
  (an `absent()` rule was the alternative to pinning).

cadvisor runs under `--url_base_prefix=/cadvisor`, so `CADVISOR_HEALTHCHECK_URL`
is overridden to `/cadvisor/healthz` — the image default `/healthz`
404s under the prefix and leaves the container perpetually unhealthy.

## More

- Upstream: <https://github.com/google/cadvisor>
