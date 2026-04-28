# Per-service health spec

Add a typed `health:` field to every service definition, render it
into Prometheus alert rules and (where applicable) blackbox scrape
configs, expose a unified `service_healthy{service=...}` recording
rule, and gate `make install` on Prometheus reporting all services
healthy after deploy.

End state: every service declares how its liveness should be
checked. The renderer dispatches inline (ERB `case`) on the kind.
Crashloops are caught by a restart-rate alert, not a flap-prone
`state="active" != 1` predicate. A post-deploy verifier reads the
same recording rule the alerts read, so install fails loudly when
the stack hasn't actually come up.

## Goal

1. `services.yml` schema gains a required `health:` block with a
   `kind:` discriminator (`http`, `systemd`, `tcp`, `expr`). Default
   resolved at render time when omitted: `kind: systemd`. Validator
   rejects unknown kinds and missing kind-specific fields.
2. Every service in the repo has an assigned (or defaulted) kind,
   captured in commit 1's `**Decisions:**` block.
3. Prometheus emits a per-service alert pair under `kind: systemd`:
   `<svc>UnitInactive` (`state="active" != 1` for 10m, slow signal)
   AND `<svc>Crashlooping` (`changes(node_systemd_unit_start_time_seconds[5m]) > 3`
   for 2m, fast signal). The qbit incident's failure mode (~30
   restarts/min for 6.5h) lights up the second alert within minutes.
4. Prometheus probes every `kind: http` service via blackbox at the
   declared `path:`, scrape interval 30s, alert on `probe_success == 0`
   for 2m. Same shape for `kind: tcp` via blackbox `tcp_connect`.
5. `kind: expr` services declare a raw promql expression; renderer
   wraps it in an alert with the same naming scheme.
6. A `service_healthy{service="<name>"}` recording rule exists for
   every service, derived from whichever kind-specific signal applies.
   `1` = healthy, `0` = unhealthy. One series per service, normalized.
7. `script/verify-stack.sh` queries `service_healthy` against the
   target's Prometheus and exits non-zero if any service is `0` or
   missing. `make install` runs it as a post-deploy gate (with a
   sleep + timeout) on remote targets.
8. The currently-disabled `BlackboxProbeFailed` rule is removed —
   the new per-service rules supersede it.

## Context

The 2026-04-25 crashloop incident exposed three observability gaps,
all in the alerting *content* rather than the alerting *path*:

1. **`BlackboxProbeFailed` is commented out** in
   `services/prometheus/rules/blackbox.yaml.erb` with a stale "docker
   network issues" note.
2. **Blackbox is configured but not actually probing services.**
   `services/prometheus/blackbox.yml.erb` defines modules; no
   `scrape_config` references them. The single scrape config
   (`prometheus_meta.yaml.erb`) only scrapes Prometheus itself. So
   `probe_success` series do not exist today — no jellyfin probe to
   alert on.
3. **`SystemdUnitDown` (`state="active" != 1` for 5m) flaps under
   crashloop.** With qbit respawning ~30×/min, the unit briefly
   reports `active` after each respawn; on a 30s scrape interval the
   predicate never sustains 5min and never fires.

The `healthz:` field exists on 6 services (cadvisor, grafana,
alertmanager, jellyfin, plex, vaultwarden, prometheus) but is unused
for alerting. The *-arr stack (qbit, sonarr, radarr, prowlarr) has
no health signal at all beyond the flap-prone systemd alert.

A typed `health:` field with inline-case rendering closes all three
gaps with a single schema change. The default `kind: systemd` gives
every service free baseline coverage via node_exporter; richer kinds
opt in for HTTP-deep, TCP, or custom-promql checks (wireguard ICMP,
cadvisor metric thresholds).

## Related plans

- **`plans/crashloop-recovery.md`** — in flight. This plan's direct
  motivation. Crashloop-recovery's commit 1 audit found the disabled
  alert, the unused blackbox modules, and the rules layout
  (`services/prometheus/rules/{rules,blackbox,mediaserver}.yaml.erb`)
  this plan extends. **Sequencing: this plan should land after
  crashloop-recovery merges.** Crashloop-recovery's `RootFilesystemCritical`
  rule (commit 7) is orthogonal and stays — disk-fill is a different
  failure class worth catching independently.
- **`plans/static-uids.md`** — drafted, becomes critical-path after
  crashloop-recovery. While the deploy freeze is in place,
  `TARGET=fatlaptop make install` is gated by `.deploy-frozen`, so
  the post-deploy verifier (commit 7 here) can only be exercised
  against `local` until static-uids ships and unfreezes. Acceptable;
  not blocking. Plan validates locally and on fatlaptop only after
  static-uids merges.
- **`plans/lisp-render.md`** — drafted, not started. **Synergy, not
  blocker.** Inline ERB `case` translates mechanically to a lisp
  `ecase`/`cond`. The rewrite is a natural place to clean up the
  case if it grows past ~6 kinds; until then, flat case is the right
  shape on either side. This plan does NOT block on the rewrite, and
  the rewrite gets a concrete real example (per-kind rendering) to
  demonstrate against. If the rewrite ships first, the case
  translates 1:1 and this plan ships against the lisp renderer
  instead of ERB; otherwise vice versa.
- **`plans/pre-rewrite.md`** — shipped. Goldens cover the renderer's
  input → output transformation. This plan adds `health:` to fixture
  services and refreshes the rendered goldens. No structural change
  to the goldens harness; just new bytes.
- **`plans/deploy-preview.md`** — drafted. The post-deploy verifier
  here is conceptually adjacent (both reach across to the target)
  but operates on Prometheus query results, not rsync diffs. No
  shared code. Both end up consumed by `make install` at different
  phases.
- **`plans/nixos-target.md`** — forward-compatible. The `health:`
  field is a service-data concern; under NixOS the emitter generates
  equivalent Nix-side Prometheus config. No special handling needed
  here; the schema is target-agnostic.
- **`plans/remote-deploy.md`** — shipped. Provides `TARGET`/`REMOTE`.
  The verifier script reuses these to query the right Prometheus.

## Design notes

### Schema shape

```yaml
# services.yml
health:
  kind: http          # one of: http | systemd | tcp | expr
  path: /health       # required for kind: http
  # kind: systemd     — no extra fields; uses service.unit
  # kind: tcp         — uses service.port
  # kind: expr:
  #   expr: 'rate(...)[5m] > 0'   # raw promql; 1=healthy, 0=unhealthy
```

If `health:` is omitted, the renderer treats it as `kind: systemd`.
Validator requires the kind-specific fields when their kind is set
explicitly. (Default-vs-explicit asymmetry is fine: the default is
the cheapest and least likely to be wrong.)

### Why inline case, not dispatch

Two ERB `case` blocks (one in the rules template, one in the scrape
configs template) iterate `services` and emit the per-kind block.
No helpers, no partials. Header comment in each template noting:
"adding a 5th kind requires editing both case blocks; if this grows
past ~6 kinds, factor to dispatch."

Cost: editing two cases when adding a kind. Benefit: the case
translates 1:1 to lisp; no scaffolding to carry across the rewrite;
the rendered output is grep-able in a way helper-method-emitted
output is not.

### `kind: systemd` alert pair

The crashloop-flap problem is that `state="active" != 1 for: 5m`
samples mostly `active` between rapid respawns. The fix is a second
alert that watches for *too many* starts in a window:

```yaml
- alert: <%= svc.name %>Crashlooping
  expr: changes(node_systemd_unit_start_time_seconds{name="<%= svc.unit %>.service"}[5m]) > 3
  for: 2m
  labels: { partof: <%= svc.partof %>, service: <%= svc.name %> }
- alert: <%= svc.name %>UnitInactive
  expr: node_systemd_unit_state{name="<%= svc.unit %>.service", state="active"} != 1
  for: 10m
  labels: { partof: <%= svc.partof %>, service: <%= svc.name %> }
```

Two alerts because they catch different shapes: `Crashlooping`
fires fast on rapid respawns; `UnitInactive` catches a unit that
just stays down (no respawning, no flap). For a true crashloop both
fire; for a clean down-state only the second fires.

The `UnitInactive` window is intentionally generous (10m vs the
existing 5m) because we have a faster signal alongside it; we'd
rather not page on a 30s blip during a planned restart.

### `kind: http` and `kind: tcp` shape

Single new scrape config file
`services/prometheus/scrape_configs/health.yaml.erb` iterates services
and emits one entry per `kind: http` (using the `http_basic` blackbox
module) and one per `kind: tcp` (`tcp_connect`). Static targets, no
relabeling magic — the service name and target are known at render
time.

```yaml
# rendered example
- job_name: health-http-jellyfin
  metrics_path: /probe
  params: { module: [http_basic] }
  scrape_interval: 30s
  static_configs:
    - targets: [http://jellyfin:8096/health]
      labels: { service: jellyfin, kind: http, partof: streaming }
  relabel_configs:
    - { source_labels: [__address__], target_label: __param_target }
    - { target_label: __address__, replacement: blackbox-exporter:9115 }
```

Alert in the rules template (one per kind, looped):

```yaml
- alert: <%= svc.name %>ProbeFailed
  expr: probe_success{service="<%= svc.name %>"} == 0
  for: 2m
```

### `kind: expr`

Raw promql escape hatch. The expression evaluates to `1` for healthy
and `0` for unhealthy. Renderer wraps it into:

```yaml
- alert: <%= svc.name %>HealthExprFailed
  expr: (<%= svc.health.expr %>) == 0
  for: <%= svc.health.for || '5m' %>
```

Candidates: wireguard (probe a ping metric from a sidecar — but if
no metric exists today, wireguard stays `kind: systemd` and the
docker `healthcheck:` it already has provides container-level
liveness; the systemd unit alert covers the rest), cadvisor (metric-
threshold based "is it scraping" check). Final assignments live in
commit 1.

### Recording rule: `service_healthy`

One rule file `services/prometheus/rules/service_healthy.yaml.erb`
emits a normalized series per service:

```yaml
- record: service_healthy
  expr: 1 - (ALERTS{alertname="<%= svc.name %>ProbeFailed", alertstate="firing"} or vector(0))
  labels: { service: <%= svc.name %>, kind: <%= svc.health.kind %> }
```

Or, more directly, derive from the underlying signal per kind
(`probe_success`, `node_systemd_unit_state`, the `expr` itself).
Decided in commit 6 — both options work; preference for the direct-
signal version since it doesn't depend on the alert evaluation
having fired yet.

The recording rule is what `script/verify-stack.sh` queries. One
source of truth, two consumers (alerting + deploy gate).

### Post-deploy verifier

`script/verify-stack.sh <target>`:

1. Resolves the Prometheus URL for the target (local or via
   tailscale hostname).
2. Sleeps ~30s to give path units time to reload + new scrape data
   to land.
3. Polls `count(service_healthy == 0) + (count(service_count) - count(service_healthy))`
   (or equivalent: unhealthy + missing) every 5s for up to 60s.
4. Exits 0 once that count is 0 for two consecutive polls; exits
   non-zero with a list of failing services on timeout.

Wired into `make install` as a post-step on remote targets only
(local install doesn't go through the same path-unit reload latency,
and a CI-style local check would just slow down the inner dev loop).

### Cleanup

Remove the disabled `BlackboxProbeFailed`, `BlackboxProbeHttpFailure`,
and the "Disabled" comment trail in `blackbox.yaml.erb` once the new
per-service rules cover the same ground. Keep the slow-probe and SSL
expiration rules — they're orthogonal.

## Commits

1. **Schema + audit + validator** — Define `health:` block in
   `services.yml` schema docs (CLAUDE.md or service.yml header
   comment). Add validator rules in `lib/mediaserver/validator.rb`
   (or wherever the per-service validation lives): `kind` must be one
   of the four; kind-specific fields required when present; default
   `kind: systemd` applied at access time, not at parse time (so the
   absence is visible to tooling). Audit every service; set explicit
   `health:` blocks where the default isn't right. Drop assignments
   into the plan's `**Decisions:**` block on this commit, with a
   one-line rationale per service.
   *Verify:* `make check` passes. `make all` produces unchanged output
   (no rendering wired up yet — schema-only commit). Audit captures
   every service in `services/`; each one has either an explicit
   `health:` or an explicit "defaults to systemd, that's fine"
   notation in decisions.

2. **Render `kind: systemd` alert pair** — Extend
   `services/prometheus/rules/mediaserver.yaml.erb` (or new file
   `service_health.yaml.erb` if mediaserver gets crowded — decide in
   commit) with a loop emitting `<svc>Crashlooping` and
   `<svc>UnitInactive` for every service whose resolved kind is
   `systemd`. Drop the existing project-wide `SystemdUnitDown` alert
   in the same commit — it's superseded by the per-service pair and
   the flap problem is exactly why it failed during the incident.
   *Verify:* `make all` clean; `make check` runs `promtool check
   rules` and passes; rendered rules contain the expected pair for
   every kind:systemd service; goldens refreshed under
   `test/golden/` for any fixture changes. Manually load into a
   local Prometheus: alerts visible under Rules; `Crashlooping`
   fires within 2m of synthetic restart-loop on a test unit.

3. **Render `kind: http` + `kind: tcp` probes and alerts** — New
   `services/prometheus/scrape_configs/health.yaml.erb` with one
   case-driven loop emitting blackbox scrape jobs for http/tcp
   kinds. Add `<svc>ProbeFailed` alerts in the rules template (same
   loop, kind-filtered). Move the existing healthz field references
   into the `health:` block (already audited in commit 1). Remove
   the disabled `BlackboxProbeFailed` and `BlackboxProbeHttpFailure`
   blocks from `blackbox.yaml.erb`.
   *Verify:* `make all` + `make check`. Rendered scrape config has
   one job per http/tcp service. Local Prometheus picks up probes;
   `probe_success` series exist; alerts fire on a deliberately-broken
   target (e.g. wrong path on a fixture).

4. **Render `kind: expr` alerts** — Loop in the rules template
   wrapping each kind:expr service's raw promql into an alert. Apply
   to whichever services were assigned this kind in commit 1
   (likely cadvisor; possibly wireguard if a ping-metric source is
   identified, otherwise wireguard stays systemd).
   *Verify:* rendered output has the expected raw-promql-wrapped
   alerts; `promtool check rules` parses them; firing semantics
   confirmed against a hand-crafted false expression.

5. **Recording rule: `service_healthy`** — New
   `services/prometheus/rules/service_healthy.yaml.erb` emitting one
   recording rule per service, derived from the kind-specific signal
   (case again). `1` = healthy, `0` = unhealthy. Labels: `service`,
   `kind`, `partof`.
   *Verify:* `make check`. Series shows up in Prometheus for every
   service after a scrape cycle. Counts match: total services in
   `services/` == `count(service_healthy)`. Manually flipping a
   single service unhealthy (stop a test container) flips its
   `service_healthy` series within ≤2 cycles.

6. **`script/verify-stack.sh` post-deploy verifier** — Shell script
   that takes a target argument, resolves the Prometheus URL,
   polls `service_healthy` until all services report `1` or
   timeout. Hard timeout 60s; per-poll interval 5s; 30s warmup
   sleep before first poll. Exits non-zero with a list of failing
   services. Shellcheck clean.
   *Verify:* `script/verify-stack.sh local` against a healthy
   stack returns 0 in ≤45s; same script with a deliberately-stopped
   service returns non-zero with that service named in stderr.

7. **Wire verifier into `make install`** — Add a post-step to the
   `install` recipe, gated on `TARGET != local`, that runs
   `script/verify-stack.sh $(TARGET)`. Exit non-zero on the script's
   non-zero exit, surfacing the failing-services list. Document the
   step in CLAUDE.md under Workflow ("install fails loudly when the
   target's stack isn't healthy after deploy").
   *Verify:* `TARGET=local make install` is unchanged (verifier
   skipped). On a remote target with a healthy stack, install
   completes; on a remote target where a service is broken, install
   exits non-zero pointing at the broken service. (Note: actual
   remote testing waits on `plans/static-uids.md` to ship and lift
   the deploy freeze; until then, exercise via a manually-overridden
   `TARGET=fatlaptop` after temporarily clearing `.deploy-frozen` in
   a controlled way, or by pointing the verifier at a local
   Prometheus mocking fatlaptop's metrics.)

## Future plans

- **Health spec dispatch refactor (post-lisp-rewrite).** If the kind
  list grows past ~6, factor the inline case into a dispatch table
  keyed by kind. Cleaner in lisp than ERB; defer until either
  threshold is hit.
- **Severity routing.** Today there's a single discord receiver for
  everything. Tagging the new alerts with severity labels and
  routing critical-but-not-warning differently is a separate plan.
- **Healthcheck-driven docker `healthcheck:` parity.** Some services
  (wireguard) already define a docker-level `healthcheck:`; the
  `health:` field could in principle generate that too, unifying
  the two layers. Out of scope here — the docker healthcheck is
  consumed by docker compose's restart policy, not by alerting,
  and the two consumers want different shapes.
- **NixOS emitter port.** When `plans/nixos-target.md` lands, the
  `health:` field needs an emitter that produces Nix-side Prometheus
  config. Mechanical translation; flagged here so it's not
  forgotten.

## Non-goals

- **Dispatch abstraction / helper methods in the renderer.**
  Explicit choice to keep ERB inline `case` statements. Two case
  blocks (rules + scrape_configs) is the accepted cost. Justified
  by the flat case translating cleanly to the lisp rewrite without
  carrying scaffolding across.
- **Generalized "stack health" check.** The verifier checks one
  thing: `service_healthy` from Prometheus. Not Prometheus's own
  health, not Alertmanager's, not webhook delivery. That's a
  separate concern (call it "alerting-path verifier") and would be
  its own small plan if needed.
- **Replacing the disk-fill alert.** `RootFilesystemCritical` from
  `plans/crashloop-recovery.md` stays. Disk fill is a distinct
  failure class — services can be healthy and the disk can still
  fill via cores, logs, or unrelated processes. Both signals worth
  having.
- **Backfilling docker-compose `healthcheck:` from `health:`.** Two
  consumers (docker, prometheus) with different needs; don't conflate.
- **Fixing the deploy freeze.** That's `plans/static-uids.md`. This
  plan tolerates the freeze by exercising the verifier locally
  until static-uids ships.

## Open questions

- **Recording rule derivation: from `ALERTS` or from raw signal?**
  Raw signal is more direct (no dependency on alert evaluation
  timing) but requires a per-kind expression in the recording rule
  template. `ALERTS`-based is uniform but coupled to alert state.
  Lean raw-signal; finalize in commit 5.
- **Should `kind: systemd` skip `<svc>UnitInactive` when we already
  have `<svc>Crashlooping`?** Argument for keeping both: they catch
  different shapes (rapid-respawn vs. clean-down). Argument for
  dropping inactive: it's the flap-prone one, and crashlooping
  covers the actual incident. Probably keep both; the 10m window
  on inactive should avoid the flap problem in practice.
- **Verifier: poll Prometheus or query directly via promtool?**
  Polling the HTTP API is simpler and doesn't require promtool on
  the deploying host. Lean HTTP API.
- **Where does the verifier resolve the Prometheus URL from?**
  Probably a render-time output — `config/verifier-targets.yml`
  or similar — keyed by target hostname. Avoids hardcoding into
  the script.
