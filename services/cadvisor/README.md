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

## Resource ceiling

Default flags are the wrong shape for this host: cadvisor's `disk`
collector stat()s every mount it can see, and the `/rootfs` bind makes
each overlay2 layer reachable by several nested paths on top of the
multi-TB NFS media mount. Left at defaults it settles at ~6 of 8 cores
and leaks RSS past 1.5G within a week, which is enough to hold the CPU
package near 90°C indefinitely.

`service.yml.elp` therefore pins housekeeping to 30s, restricts
collection to docker containers, drops container labels from the metric
set, and allowlists metric families with `--enable_metrics` (an
allowlist so a future image's new default-on family can't silently
reappear). `mem_limit: 1g` is the backstop.

**Accepted risk:** the `disk` family is off, so `container_fs_usage_bytes`,
`container_fs_limit_bytes`, and `container_fs_inodes_*` are not
collected — per-container filesystem *usage* is unobservable here.
Nothing alerts on them; `VolumeFillingUp` reads node-exporter's
`node_filesystem_avail_bytes`, which measures the host filesystems the
containers actually write to. `diskIO` stays on, so
`container_fs_writes_bytes_total` (the top-talkers dashboard) is intact.

**Not covered:** nothing alerts on a container consuming sustained CPU.
cadvisor's own runaway was invisible until the host was inspected by
hand.

## More

- Upstream: <https://github.com/google/cadvisor>
