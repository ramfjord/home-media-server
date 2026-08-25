# Alertmanager

Receives alerts fired by Prometheus and routes them to humans — in this
stack, that means a Discord webhook (and SMTP as a backup channel).
Alertmanager handles grouping, deduplication, silencing, and inhibition
so a single underlying problem doesn't fan out into dozens of pages.

`templates/` holds the message templates used to format alerts before
they're posted to Discord.

## Gated (and why it's not break-glass)

`gateway_auth: true` — the web UI is behind Authelia. Un-gated,
Alertmanager is a worse surface than un-gated Prometheus: `POST
/api/v2/silences` lets anyone **suppress alerts** (a stealthy way to
blind the monitoring), and `/api/v2/status` returns the running config
including the **Discord webhook URL** (effectively a secret) and SMTP
settings. None of that is needed to debug a gateway incident — firing
alerts still reach Discord out-of-band, and un-gated Prometheus
`/api/v1/alerts` shows alert state — so gating it costs no break-glass.

Nothing programmatic depends on the gated path: Prometheus pushes
alerts to `alertmanager:9093` over internal DNS (not via Caddy), so
the gate only affects the human browser path.

## Settle windows: muting restart noise

Two marker alerts in
[prometheus/rules/settle.yaml.elp](../prometheus/rules/settle.yaml.elp)
feed the `inhibit_rules` here:

| Marker | Window | Inhibits |
|---|---|---|
| `StackStarting` | host booted <15m ago | everything (`boot-settle`, no `equal`) |
| `ServiceStarting` | container created <10m ago | that service only (`service-settle`, `equal: [service]`) |

Both terminate on the `null` receiver — a receiver with no integration
configs — so they never post to Discord.

A window only mutes an alert if it outlasts that alert's `for:`. The
dominant restart noise (`BlackboxProbeFailed`, `TargetDown`) is
`for: 5m`, so a 5m window would expire on the same evaluation the alert
fires and mute nothing. Both windows are sized past 5m for that reason.

Suppressed is not dropped: an alert muted during a settle window
notifies once the marker clears, at the next `group_interval`.

**`ServiceStarting` tracks container *creation*, not container start.**
Its source, cadvisor's `container_start_time_seconds`, reports docker's
`.Created` — not `.State.StartedAt`. So it fires when a container is
recreated (a deploy whose config changed, an image pull, `compose up
--force-recreate`) and stays silent when an existing container restarts
in place.

**Not covered:**

- In-place restarts. `systemctl restart <svc>` that reuses the
  container, and docker's own `restart: unless-stopped` after a crash,
  both leave `.Created` untouched — that noise still reaches Discord.
- A crash-looping container cannot mute itself indefinitely, for the
  same reason: restarts don't re-arm the marker. There is no
  permanently-inhibited-service failure mode here.
- `SystemdUnitFailed` does not back any of this up. node-exporter runs
  without `--collector.systemd`, so `node_systemd_unit_state` does not
  exist on this host and that alert can never fire.

If cadvisor is down, `ServiceStarting` disappears and nothing is muted
— the failure direction that keeps alerting.

## More

- Upstream: <https://github.com/prometheus/alertmanager>
- Docs: <https://prometheus.io/docs/alerting/latest/alertmanager/>
