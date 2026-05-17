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

## More

- Upstream: <https://github.com/prometheus/alertmanager>
- Docs: <https://prometheus.io/docs/alerting/latest/alertmanager/>
