# Pre-rewrite: golden tests

Groundwork landing before a Lisp rewrite of `render.rb` (separate plan,
not yet drafted). This plan is intentionally scoped to **safety nets
only** — no edits to `lib/mediaserver/*.rb` or `render.rb` itself. The
simplification urge is deferred to the rewrite, where Lisp
metaprogramming earns its keep on the `ProjectService` field
proliferation.

The other half of the original "pre-rewrite" scope — `make preview` —
was extracted to `plans/deploy-preview.md` once `plans/remote-deploy.md`
shipped. The two halves are independent and can land in either order.

## Goal

A simplified-but-realistic five-service fixture tree + checked-in
expected outputs. Proves "renderer behaves identically on a fixed
input" across any reimplementation. Language-agnostic; the Lisp port
consumes the same fixtures and asserts the same goldens.

Combined with `make preview` (sibling plan), this replaces the value
of refactoring `lib/` for safety:

- Goldens cover a controlled fixture tree — fast, deterministic,
  machine-agnostic, exercises every networking mode and config-merge
  branch the renderer uses.
- `make preview` covers the real config on the real host on every
  deploy.

## Non-goals

- **No edits to `render.rb` or `lib/mediaserver/*.rb`.** Tempting
  cleanups (drop `expand_vars` if unused, fold `Validator` into
  `Config`, replace host-shelling-out with an injected seam) are all
  deferred. They're either solved cleanly by the Lisp rewrite or are
  load-bearing in ways grepping won't catch.
- **No checked-in golden of the real `services/` tree.** Fixtures are
  purpose-built simplifications, not sanitized copies of real
  configs. Real-config confidence comes from `make preview`.
- **No new ERB features, no template changes.** This is pure
  scaffolding around current behavior.

## Related plans

- `plans/deploy-preview.md` — sibling. Was originally Part 2 of this
  plan. Independent code paths; either can land first.
- `plans/nixos-target.md` — goldens survive the NixOS cutover
  unchanged. They test the renderer's input → output transformation,
  regardless of what consumes the output.
- `plans/static-uids.md` — no interaction. Goldens use fixture
  service names with no `groups:` and no matching host user,
  sidestepping the UID/GID code paths entirely. Static-UIDs work can
  land before, during, or after with no coordination.

## Design notes

### Fixture services

Five simplified-but-realistic services chosen to span every
networking mode the renderer emits:

- **wireguard** — the VPN-provider container itself. Exercises
  whatever `use_vpn`-adjacent surface and network-mode emission the
  renderer does for the VPN root.
- **qbittorrent** — VPN consumer via `network_mode: container:wireguard`.
  Catches the network-namespace-sharing path and the implicit
  ordering/healthcheck dependency on wireguard.
- **caddy** — dual-network bridge (Tailscale + WireGuard). Catches
  multi-network attach, port exposure, and cert-path references.
- **sonarr** — plain tailnet service that talks across the network
  boundary to qbittorrent. Catches the "regular service" baseline
  plus inter-service references.
- **prometheus** — monitoring service that scrapes everything.
  Catches the cross-service scrape-target generation surface.

Together these exercise: solo container, container-in-namespace,
multi-network, plain tailnet, and many-to-many service references.
That's the full networking matrix.

### Non-network branches piggyback on these fixtures

Rather than separate fixtures for non-network surface, fold the
branches into the five above:

- `config_yaml[…]` lookups: prometheus consumes them naturally for
  scrape config.
- `service_overrides` (per-service overrides in `config.local.yml`):
  override one field on caddy or sonarr.
- Top-level overrides (`install_base`, `media_path`, `hostname`):
  set non-defaults in the fixture `config.local.yml`.
- `expand_vars` (`${…}` interpolation): include one usage somewhere
  if grep confirms real configs use it; skip otherwise.
- `--list-make` output: covered by a separate golden file, not a
  separate fixture.

### Determinism guards

- Fixture service `name`s must not match any user on a likely dev
  box (so `id -u <name>` returns empty deterministically). Prefix
  with `fx-` or similar.
- No `groups:` field on any fixture service (so `getent group` is
  never invoked).
- Together this keeps output stable across machines without touching
  `config.rb`.

### Fake certs

Caddy templates reference cert paths. Check in throwaway self-signed
certs under `test/fixtures/certs/` so the goldens render
self-contained. A README in that directory explains they're fake,
never to be reused for any real purpose, and how to regenerate if
the format ever changes.

## Approach

Layout:

```
test/
  fixtures/
    services/
      fx-wireguard/service.yml
      fx-qbittorrent/service.yml
      fx-caddy/
        service.yml
        Caddyfile.erb
      fx-sonarr/service.yml
      fx-prometheus/
        service.yml
        prometheus.yml.erb
    certs/
      README.md                      # explains fake/throwaway nature
      fullchain.pem                  # self-signed, dummy
      privkey.pem                    # dummy
    globals.yml
    config.local.yml                 # exercises overrides + service_overrides
  golden/
    fx-caddy/Caddyfile               # expected rendered output
    fx-prometheus/prometheus.yml
    list-make.txt
    ...                              # one file per .erb in fixtures/
  golden_test.rb
```

Test runner: walk `test/fixtures/services/**/*.erb`, render each
against the fixture `Config`, diff against `test/golden/<same path
minus .erb>`. On mismatch, print the diff and fail. `UPDATE_GOLDEN=1
ruby test/golden_test.rb` rewrites the goldens; the diff lands in the
PR.

## Commits

1. **Inventory renderer branches** — Grep `render.rb`,
   `lib/mediaserver/*.rb`, and the real templates for every distinct
   call site / config branch / network mode / config-yaml lookup.
   Drop the result into `test/fixtures/BRANCHES.md` (or similar) as
   a checklist. This is the source of truth for fixture coverage —
   subsequent commits check items off as the fixtures grow.
   *Verify:* checklist exists and visually covers every public
   method on `ProjectService` / `Config` plus every
   network-mode/dependency branch in the real services tree.

2. **Add fixture service tree + fake certs + README** — Five
   `service.yml` files, the two ERB templates (caddy, prometheus),
   `globals.yml`, `config.local.yml`, and `test/fixtures/certs/`
   with a README explaining the certs are throwaway. No test runner
   yet; just data.
   *Verify:* every fixture YAML loads via `ruby -ryaml -e
   'YAML.load_file(ARGV[0])'`. Fixture service names confirmed
   absent from `getent passwd`, no fixture has `groups:`. Certs
   parse via `openssl x509 -in test/fixtures/certs/fullchain.pem
   -noout`.

3. **Add `test/golden_test.rb` and seed initial goldens** — Walk
   fixture ERBs, render against a fixture-rooted `Config`, diff
   against `test/golden/`. First run uses `UPDATE_GOLDEN=1` to seed.
   Cross-check seeded output against the BRANCHES.md inventory; if
   anything in the inventory isn't reflected somewhere in a golden,
   the fixtures need another field before sealing.
   *Verify:* `ruby test/golden_test.rb` exits 0. Tweak one fixture
   ERB → test fails with a readable diff. `UPDATE_GOLDEN=1` re-seeds
   and the next run passes. Every BRANCHES.md item is checked off.

4. **Add `make test` target** — Single entry point for the test
   suite (room to grow if more tests show up). Document in
   CLAUDE.md alongside `make check`.
   *Verify:* `make test` runs the goldens and exits 0; `grep -n
   '^test:' Makefile` and `grep -n 'make test' CLAUDE.md` confirm
   wiring + docs.

5. **Cover `--list-make` output** — `render.rb --list-make`
   produces Makefile fragments, not template output, but it's part
   of the renderer's contract. Add `test/golden/list-make.txt` and
   a branch in the test runner.
   *Verify:* `ruby test/golden_test.rb` covers it; intentional
   change to a fixture's makefile-relevant fields produces a
   readable diff in `list-make.txt`.

## Open questions

- **Does any real `service.yml` use `${var}` interpolation
  (`Mediaserver.expand_vars`)?** Resolved during commit 1's
  inventory. If yes, fold into a fixture; if no, mark for deletion
  during the rewrite (not in this plan).
- **`UPDATE_GOLDEN=1` ergonomics.** Make-target convenience
  (`make goldens-update`) vs. raw env var. Defer until the workflow
  hurts.
- **Cert format drift.** If Caddy ever needs a different cert format
  the throwaway certs become invalid. The fixtures README documents
  regeneration; not a code concern.
