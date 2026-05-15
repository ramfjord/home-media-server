# Alertmanager

Receives alerts fired by Prometheus and routes them to humans — in this
stack, that means a Discord webhook (and SMTP as a backup channel).
Alertmanager handles grouping, deduplication, silencing, and inhibition
so a single underlying problem doesn't fan out into dozens of pages.

`templates/` holds the message templates used to format alerts before
they're posted to Discord.

## More

- Upstream: <https://github.com/prometheus/alertmanager>
- Docs: <https://prometheus.io/docs/alerting/latest/alertmanager/>
