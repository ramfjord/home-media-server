# node-exporter

Exposes host-level (OS) metrics — CPU, memory, disk, filesystem,
network, load average — as Prometheus metrics. The "is the box itself
healthy?" complement to cAdvisor's per-container view.

## systemd collector

The collector is `defaultDisabled` upstream, so `--collector.systemd`
is set explicitly. Without it `node_systemd_unit_state` has no series
and `SystemdUnitFailed` can never fire.
`--collector.systemd.enable-start-time-metrics` is a second, separate
opt-in for `node_systemd_unit_start_time_seconds`, which is what
`ServiceStarting` keys on.

**dbus.** The collector talks to systemd over dbus, and `--path.rootfs`
does not redirect that — the socket must exist at its real path inside
the container. `/run/dbus/system_bus_socket` is bind-mounted, not `:ro`
(connecting to a unix socket needs write access to the inode), and
`DBUS_SYSTEM_BUS_ADDRESS` points at it because godbus otherwise
defaults to `/var/run/dbus/system_bus_socket`, relying on a
`/var/run` -> `/run` symlink this image does not have.
`--collector.systemd.private` is the other route to a connection;
upstream hides the flag and documents it as test-only.

**`unit-include` is required, not an optimization.** The default
`unit-exclude` already drops mounts/scopes/slices, so cardinality is
not the reason. The reason is that the host carries failed units the
stack does not own and cannot fix — stray distro packages, leftover
units from removed services — and unfiltered every one of them pages
forever under `SystemdUnitFailed`. The pattern is generated from the
manifest, so it tracks the service list automatically. Upstream
anchors it as `^(?:...)$`; do not add `^`/`$` here, a literal `$`
would be consumed by compose variable interpolation.

Units in scope: `<svc>.service`, `<svc>-reload.service`,
`<svc>-compose-reload.service`, `<svc>.path`, `<svc>-compose.path`,
plus `mediaserver-network.service` and `tailscale-cert.{service,timer}`.

**Relabel.** The scrape stamps `service=operating-system` on every
node-exporter series, correct for host metrics and wrong for systemd
units, which each describe one stack service. A
`metric_relabel_config` rewrites `service` from the unit name so
`SystemdUnitFailed` groups under the offending service and
alertmanager's `service-settle` inhibition (`equal: [service]`) can
scope to it. Non-systemd metrics carry no `name` label, do not match,
and keep `operating-system`.

**Accepted risk:** `-reload` and `-compose-reload` units map to their
parent service, so a failing reload unit pages as that service rather
than as itself. The unit name is in `$labels.name`.

## More

- Upstream: <https://github.com/prometheus/node_exporter>
