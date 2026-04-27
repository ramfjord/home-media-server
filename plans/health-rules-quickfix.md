# Health rules quick-fix

Close the alerting-content gaps the 2026-04-25 crashloop incident
exposed, with the smallest possible diff: three rule changes, no
schema work, no validator work, no per-service tuning. Ships as one
branch in ~80 lines of YAML.

## Goal

After this lands, the next incident with the same shape pages
discord:

1. **Crashlooping service** — qbit-style "abort, respawn, abort,
   respawn" at any rate above ~0.5/sec for 2 minutes.
2. **Down service exposing `healthz:`** — jellyfin-style "container
   up but HTTP probe failing" or "container exited and stayed
   exited."
3. **Slow drift toward disk-fill** — already covered by
   `VolumeFillingUp` and (after `plans/crashloop-recovery.md` ships)
   `RootFilesystemCritical`. This plan does not touch those.

Mechanism: project-wide rules keyed on `node_systemd_unit_*` and
`probe_success`, plus a single new scrape config that wires
blackbox-exporter to probe every service with a `healthz:` field.

## Context

`plans/crashloop-recovery.md` commit 1's audit found three
content-side gaps (separately from the path-side gaps about whether
Prometheus or the discord webhook were even alive during the
incident):

1. **`BlackboxProbeFailed` is commented out** in
   `services/prometheus/rules/blackbox.yaml.erb` with a stale "docker
   network issues" note. Whatever those issues were, they predate
   the current network topology and should be re-tested.
2. **Blackbox is configured but probes nothing.**
   `services/prometheus/blackbox.yml.erb` defines `http_basic`,
   `http_head`, and `icmp` modules; no scrape config references
   them. `probe_success` series do not exist — even if (1) were
   enabled, no data would feed it.
3. **`SystemdUnitDown` (`state="active" != 1` for 5m) flaps under
   crashloop.** A unit respawning ~30×/min briefly reports `active`
   between respawns; on a 30s scrape interval the predicate never
   sustains 5m and never fires.

The `per-service-health.md` plan proposed a typed-`health:` field
with per-service rendering to address all of this systematically.
Evaluation of that plan flagged it as over-engineered relative to
the actual incident shape: project-wide rules cover the same ground
in one branch instead of seven commits, and the per-service tuning
the typed plan offered may not buy anything we need until we see
evidence otherwise.

This plan is the empirical first cut. If the next incident slips
through these rules, that's evidence that per-service tuning matters
and `per-service-health.md` becomes the follow-on. If the next
incident *is* caught, the typed plan likely stays deferred forever.

## Related plans

- **`plans/crashloop-recovery.md`** — in flight. **Sequencing: this
  plan lands after crashloop-recovery merges.** Uses its commit-1
  audit findings (the rules layout under
  `services/prometheus/rules/{rules,blackbox,mediaserver}.yaml.erb`,
  the `discord` receiver convention, the existing label conventions
  `partof:`/`service:`). The deploy freeze it introduces means
  testing on fatlaptop waits for `plans/static-uids.md`; local
  testing is fine.
- **`plans/per-service-health.md`** — drafted, deliberately deferred.
  This plan is paradigm A from that plan's evaluation; the typed
  plan is the paradigm-B follow-on if quick-fix proves insufficient.
  Cross-reference for future-us deciding whether to invest further.
- **`plans/static-uids.md`** — drafted. No interaction; this plan
  doesn't touch UID-sensitive paths. The deploy freeze gates remote
  testing but not the work itself.
- **`plans/lisp-render.md`** — drafted, not started. No interaction;
  this plan adds rule YAML and one scrape_config block, all of which
  port mechanically. No new template structures, no helpers, no
  dispatch — nothing to translate that the existing renderer
  doesn't already handle.
- **`plans/pre-rewrite.md`** — shipped. Goldens cover the renderer.
  The new scrape_config is rendered output; goldens may need
  refresh, but the fixture services don't have `healthz:` set
  (intentionally minimal), so the new probe scrape_config likely
  emits empty for fixtures and the goldens stay stable. Confirm in
  commit 3.
- **`plans/deploy-preview.md`**, **`plans/nixos-target.md`**,
  **`plans/remote-deploy.md`** — orthogonal.

## Design notes

### Rule (1): un-comment `BlackboxProbeFailed`

The disabled block in `blackbox.yaml.erb`:

```yaml
# Disabled - grafana, homer, cadvisor probes failing due to docker network issues
# - alert: BlackboxProbeFailed
#   expr: probe_success == 0
#   for: 0m
```

Two changes from the disabled form when re-enabling:

- `for: 0m` → `for: 2m`. Avoids paging on a single failed scrape
  during a planned restart; matches the convention used by other
  rules in this file.
- Drop the "docker network issues" comment. If those issues
  resurface for grafana/homer/cadvisor specifically, address them
  per-service in a follow-up rather than disabling the global rule
  again.

`BlackboxProbeHttpFailure` (the second commented block, on
`probe_http_status_code <= 199 OR >= 400`) stays commented out —
`probe_success` already covers HTTP status: blackbox's `http_basic`
module fails the probe on non-2xx by default, so the second alert
is redundant with the first.

### Rule (2): project-wide crashloop alert

Goes into `services/prometheus/rules/mediaserver.yaml.erb` (the same
file the existing `SystemdUnitDown` and `VolumeFillingUp` rules live
in):

```yaml
- alert: SystemdUnitCrashlooping
  expr: changes(node_systemd_unit_start_time_seconds{name=~".+\\.service"}[5m]) > 3
  for: 2m
  labels:
    partof: monitoring
    service: systemd
  annotations:
    summary: "{{ $labels.name }} restarted >3 times in 5m"
    description: "Unit {{ $labels.name }} on {{ $labels.instance }} is restarting rapidly"
```

Threshold rationale: 3 starts in 5min ≈ one start per ~100s, which
is well above any planned-restart cadence (path-unit-driven reloads
during a deploy fire a single restart) but well below the qbit
incident shape (~30/min = 150 in a 5min window). `for: 2m` requires
the rate to sustain — a single retry burst from a flaky service
during deploy doesn't page.

This rule **replaces** `SystemdUnitDown` for crashloop shapes but
not for clean-down shapes (a unit that just stays inactive). Keep
`SystemdUnitDown` in place; the two alerts catch different failure
modes and overlap is fine.

### Rule (3): wire blackbox to probe services with `healthz:`

New file `services/prometheus/scrape_configs/blackbox_probes.yaml.erb`,
shape:

```yaml
scrape_configs:
<% services.select { |s| s["healthz"] }.each do |svc| %>
  - job_name: blackbox-<%= svc["name"] %>
    metrics_path: /probe
    params:
      module: [http_basic]
    scrape_interval: 30s
    static_configs:
      - targets: ["http://<%= svc["name"] %>:<%= svc["port"] %><%= svc["healthz"] %>"]
        labels:
          service: <%= svc["name"] %>
          partof: <%= svc["partof"] %>
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - target_label: __address__
        replacement: blackbox-exporter:9115
<% end %>
```

The select-and-iterate is exactly the kind of inline ERB the
existing renderer already does elsewhere (e.g. the disabled
`UnitNeverStarted<%= svc["name"] %>` block in `mediaserver.yaml.erb`
is the same shape). No new helpers, no dispatch — ports cleanly to
the lisp rewrite if/when it ships.

Six services have `healthz:` today: cadvisor, grafana, alertmanager,
jellyfin, plex, vaultwarden, prometheus. (`grep healthz services/`
produces the canonical list — confirm in commit 3 in case any have
been added since.)

### What about the *-arr stack?

qbit, sonarr, radarr, prowlarr have no `healthz:` field and are
**not** covered by the new probes. They're covered by:

- **`SystemdUnitCrashlooping`** when they actively crash (qbit-style).
- **`SystemdUnitDown`** when they cleanly fail to come up.
- **Neither** when they hang silently on a permission error without
  crashing or exiting (the failure mode where sonarr/radarr could
  malfunction without alerting). This is a known gap; if it bites,
  the answer is to add `healthz:` to those services and let the new
  scrape config pick them up — no code change, just YAML.

Adding `healthz:` to the *-arr services is **out of scope for this
plan** because most of them gate `/health`-style endpoints behind
auth, and figuring out the right unauthenticated probe path
per-service is its own small audit. Capture as a future plan.

### Why not just enable `BlackboxProbeFailed` and skip (3)?

Because (1) without (3) is a no-op: the rule fires on
`probe_success == 0`, but `probe_success` is a metric exposed *by
blackbox-exporter when something scrapes it via `/probe`*. Without
a scrape config that drives blackbox to probe service URLs, the
metric only appears for whatever ad-hoc targets exist (probably
none). (1) and (3) ship together or neither does anything.

### Goldens

The fixture services in `test/golden/` were chosen to span
networking modes, not health surface; per `pre-rewrite.md` notes
they sidestep host-shelling-out paths and likely have no `healthz:`.
The new scrape_config template renders empty for the fixtures
(select returns nothing). Confirm in commit 3 by running
`make test`.

If a fixture *does* have `healthz:` (didn't check exhaustively),
the goldens get a refresh in the same commit that adds the
template; the resulting diff is mechanical.

### Path-side gaps

This plan does **not** address the deeper unknown the
crashloop-recovery audit named: "did `VolumeFillingUp` not fire
because Prometheus died, or because the discord webhook is
broken?" That's a meta-bug about whether alerts *can* be delivered
at all, separate from whether the right alerts *exist*. Out of
scope here; capture as a future plan ("end-to-end alerting-path
test") and note that the user's "listen to discord better" remark
covers the human side of it for now.

## Commits

1. **Re-enable `BlackboxProbeFailed`** — Edit
   `services/prometheus/rules/blackbox.yaml.erb`: un-comment the
   block, change `for: 0m` to `for: 2m`, drop the stale "docker
   network issues" comment. Leave `BlackboxProbeHttpFailure`
   commented out (redundant with `probe_success` once probes are
   wired in commit 3). This commit is harmless on its own — without
   commit 3 the alert never fires because no probe data exists.
   Lands first specifically so it's a one-line YAML diff for review.
   *Verify:* `make check` (`promtool check rules`) green. Rendered
   `config/prometheus/rules/blackbox.yaml` shows the rule active. No
   alert fires (yet) because `probe_success` series don't exist —
   confirm in Prometheus UI.

2. **Add `SystemdUnitCrashlooping`** — Append the rule to
   `services/prometheus/rules/mediaserver.yaml.erb` per the design
   note. Keep `SystemdUnitDown` in place; the two are complementary.
   *Verify:* `make check` green. Rendered rule visible in Prometheus
   UI under Rules. Smoke test: pick a low-stakes systemd-managed
   container, force a tight restart loop (`while true; do systemctl
   restart <svc>; sleep 1; done` for ~3 minutes against a fixture
   container), confirm the alert fires within 2m of crossing the
   threshold; stop the loop, confirm it clears. Document the smoke
   test in the commit message; do not commit a script for it.

3. **Wire blackbox probes via new scrape_config** — New file
   `services/prometheus/scrape_configs/blackbox_probes.yaml.erb`
   per the design-note shape. Iterates `services` and emits one
   blackbox http_basic probe per service with `healthz:`. Refresh
   goldens (`make test`); expected to be a no-op on the fixture
   tree but verify.
   *Verify:* `make all` clean; rendered
   `config/prometheus/scrape_configs/blackbox_probes.yaml` contains
   one job per healthz-having service in real `services/`; goldens
   stable. Local Prometheus picks up the targets after reload;
   `probe_success` series exists and reports `1` for each healthy
   service. Manually break one probe (point its target at
   `/nonexistent`), confirm `BlackboxProbeFailed` fires within 2m.

4. **Document and capture follow-ups** — Update CLAUDE.md (or
   wherever rule documentation lives — confirm in commit) with a
   one-paragraph note: "Service health is monitored via three
   project-wide rules (probe_success on services with healthz,
   systemd-unit-down, systemd-crashloop). Adding healthz to a
   service automatically enrolls it in HTTP probing." Add two
   future-plan stubs: (a) "Add `healthz:` to *-arr services" with
   the auth-path-audit note from the design notes; (b)
   "End-to-end alerting-path test" for the path-side meta-bug.
   *Verify:* `make check` green. CLAUDE.md grep for "healthz"
   finds the new paragraph. New future-plan stubs visible in
   relevant plans (this one's Future plans section, plus a one-line
   pointer in `per-service-health.md` if it doesn't already mention
   them).

## Future plans

- **Add `healthz:` to the *-arr services** (qbit, sonarr, radarr,
  prowlarr). Each needs an auth-path audit to find an
  unauthenticated probe endpoint, or an explicit decision to probe
  an authed endpoint with a basic-auth blackbox module variant.
  Cheap once the audit is done. Closes the "hanging silently on
  permission errors" gap noted in design.
- **End-to-end alerting-path test.** Inject a synthetic alert,
  confirm it lands in discord. Run quarterly and after any
  alertmanager-config change. Catches the meta-bug the incident's
  silence may have actually been (Prometheus dead or webhook
  broken) — content rules don't matter if the path is broken.
- **`plans/per-service-health.md`.** The typed-`health:` plan stays
  drafted but deferred. Promote to active only if a future incident
  slips through the rules this plan adds — that's the empirical
  signal that per-service tuning is buying something.

## Non-goals

- **Schema changes.** No new fields on `service.yml`. The existing
  `healthz:` field is the only input.
- **Per-service alert tuning.** Project-wide rules with global
  thresholds. If a specific service needs a different threshold,
  that's the trigger to revisit `per-service-health.md`, not to
  hack a special-case rule into this plan.
- **Recording rules / `service_healthy` abstraction.** Direct
  alerting on raw signals; no normalization layer. The verifier
  script and install-time gating from `per-service-health.md` are
  also out of scope.
- **Adding `healthz:` to services that don't have one.** Future
  plan, not this one.
- **Path-side verification.** Whether discord actually receives
  alerts is a separate concern; user's "listen to discord better"
  is the current mitigation.

## Open questions

- **Does any existing scrape currently target blackbox-exporter
  itself?** If yes, blackbox already has *some* `probe_success`
  series and `BlackboxProbeFailed` may have been firing or
  flapping unnoticed. Confirm in commit 1 by checking
  Prometheus's `/targets` page and `probe_success` for any
  unexpected series.
- **Threshold for `SystemdUnitCrashlooping` — is `> 3 in 5m` right?**
  qbit's incident was 30/min, which dwarfs the threshold; planned
  deploy reloads are 1 in 5m, well below. The risk zone is a service
  that legitimately restarts 4-5 times in 5min during a flaky
  startup. If false positives appear, raise to `> 5` in commit 2's
  decisions block; don't pre-tune.
- **Does the `relabel_configs` pattern in commit 3 work with the
  current docker network setup?** Blackbox-exporter is reachable as
  `blackbox-exporter:9115` from the prometheus container (per the
  existing service definitions). Confirm in commit 3 — this is
  exactly the kind of "docker network issues" the disabled-rule
  comment may have been talking about. If probes can't reach
  services, that's the actual problem to solve, not a reason to
  re-disable the alert.
