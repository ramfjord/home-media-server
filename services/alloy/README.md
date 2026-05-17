# Alloy

Grafana Alloy is a telemetry collector. Here it reads the host's
systemd journal and ships log lines to Loki, and emits per-unit error
counters that Prometheus scrapes — so dashboards and alerts can react
to logs without Prometheus having to read logs directly.

`config.alloy.elp` is the pipeline definition: which inputs to read, how
to relabel, and where to send the result. It renders to
`config/alloy/config.alloy`.

## `config_target` (api-config attribution)

A pre-fan-out `loki.process "enrich"` stage, scoped to
`{service="api-config"}`, regexes the leading `[<target>]` prefix off
api-config's log lines into a `config_target` label (`service` stays
`api-config`). It sits before the write/metrics fan-out so the label
lands on both the stored logs (the per-service Grafana panel queries
`{config_target="$service"}`) and the metric (the
`ApiConfigReconcileFailed` rule `label_replace`s `config_target` →
`service`). The label is *exclusive* to api-config — no other service's
lines ever carry it — which is what makes `{config_target="X"}`
unambiguous and lets `ServiceLogErrors` exclude api-config's
per-upstream errors via `config_target=~"|api-config"` without
affecting any other service (they have no such label ≡ "").

## Excluding log noise from the error counter

Kernel/hardware noise (e.g. a flaky NIC spamming the ring buffer) has no
systemd unit, so it buckets under `service=alloy` and can flap the
`ServiceLogErrors` alert. Any service may declare `log_metric_exclude_regex`
— a list of RE2 regexes — to drop matching lines from the error counter
while still shipping them to Loki (so they stay greppable in Grafana).
Each service's patterns are anchored to its own `service` label, so a
pattern can only mute the service that declared it.

Kernel/unit-less noise is the **alloy** service's responsibility (a relabel
rule defaults unit-less entries to `service=alloy`, so they're reachable
from alloy's own selector). Declare such patterns via the alloy override in
`config.local.yml`:

```yaml
service_overrides:
  alloy:
    log_metric_exclude_regex:
    - 'r8169.*(NETDEV WATCHDOG|rtl_rxtx_empty_cond)'
```

Patterns for one service are OR-joined into one `stage.drop.expression`
inside a per-service `stage.match { selector = \`{service="<svc>"}\` }`.
Unset (the default) applies no filtering. The list unions across config
layers, so an override only ever *adds* suppression on a given host.

The regex lives in `stage.drop.expression` (a plain RE2 field) rather
than a LogQL `|~` line filter in the match `selector` on purpose:
Alloy's match-stage parser only lexes `"`-quoted strings after `|~`
(not backtick raw strings), and `"`-quoting would force escaping the
regex across a LogQL string layer. Routing the raw regex through
`stage.drop` via a River backtick string removes that layer. Note this
class of error is not caught by `make check` or even `alloy validate` —
it only surfaces at `alloy run` (component build), so verify Alloy
config changes by actually running them, not just validating.

## More

- Upstream: <https://github.com/grafana/alloy>
- Docs: <https://grafana.com/docs/alloy/latest/>
