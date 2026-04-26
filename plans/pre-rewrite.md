# Pre-rewrite: golden tests + deploy preview

Groundwork landing before a Lisp rewrite of `render.rb` (separate plan,
not yet drafted). This plan is intentionally scoped to **safety nets
only** — no edits to `lib/mediaserver/*.rb` or `render.rb` itself. The
simplification urge is deferred to the rewrite, where Lisp
metaprogramming earns its keep on the `ProjectService` field
proliferation.

## Goal

Two artifacts that together make the eventual rewrite low-risk:

1. **Golden tests** — synthetic fixtures + checked-in expected outputs.
   Proves "renderer behaves identically on a fixed input" across any
   reimplementation. Language-agnostic; the Lisp port consumes the
   same fixtures and asserts the same goldens.
2. **Deploy preview** — `make preview` shows a diff between locally
   rendered `config/` and what's currently deployed at the target,
   before any rsync runs. Proves "renderer behaves identically on
   *your real config* on *your real host*" on every deploy. Output is
   terminal-only — never written into the repo, since real configs
   may carry sensitive values.

Together these replace the value of refactoring `lib/` for safety.

## Non-goals

- **No edits to `render.rb` or `lib/mediaserver/*.rb`.** Tempting
  cleanups (drop `expand_vars` if unused, fold `Validator` into
  `Config`, replace host-shelling-out with an injected seam) are all
  deferred. They're either solved cleanly by the Lisp rewrite or are
  load-bearing in ways grepping won't catch.
- **No checked-in golden of the real `services/` tree.** Synthetic
  fixtures only. Real-config confidence comes from `make preview`.
- **No new ERB features, no template changes.** This is pure
  scaffolding around current behavior.

## Approach

### Part 1 — Golden tests

Layout:

```
test/
  fixtures/
    services/
      svc-docker/service.yml          # dockerized, no groups, no user lookup
      svc-systemd/service.yml         # has `unit`, no docker
      svc-with-erb/
        service.yml
        config.conf.erb
      svc-vpn/service.yml             # use_vpn: true
    globals.yml
    config.local.yml                  # exercises overrides + service_overrides
  golden/
    svc-with-erb/config.conf          # expected rendered output
    ...                               # one file per .erb in fixtures/
  golden_test.rb
```

Pick fixture service names that **don't trigger the host calls** in
`ProjectService`:

- `name` ≠ any real user on the dev box (so `id -u <name>` returns
  empty deterministically).
- No `groups:` field on any fixture service (so `getent group` is
  never invoked).
- This is enough to make output stable across machines without
  touching `config.rb`.

The goldens themselves should also exercise the surface the real
templates use: `services.each`, `service.name/port/dockerized?`,
`install_base`, `media_path`, `hostname`, `compose_file`,
`config_yaml["…"]`. One synthetic ERB per shape is enough — we're
testing the renderer, not enumerating real templates.

Test runner: walk `test/fixtures/services/**/*.erb`, render each
against the fixture `Config`, diff against `test/golden/<same path
minus .erb>`. On mismatch, print the diff and fail. `UPDATE_GOLDEN=1
ruby test/golden_test.rb` rewrites the goldens; the diff lands in the
PR.

### Part 2 — `make preview`

Render locally, diff against deployed tree, before any rsync. Composes
with `plans/remote-deploy.md` — see below.

Local-only first cut (works today):

```make
preview: check all
	@echo "--- file manifest ---"
	@rsync -ain --delete --out-format='%i %n' \
		config/ /opt/mediaserver/config/ \
		| grep -v '^\.' || echo "no changes"
	@echo "--- content diff ---"
	@diff -ruN /opt/mediaserver/config/ config/ || true
```

- `rsync -ain --delete` is dry-run: prints which files would be added,
  changed, or deleted. Cheap survey of the whole tree.
- `diff -ruN` shows actual content changes for human review. Pipe to
  `less` if it's long.
- Output is terminal-only. Nothing written to repo or to `tmp/`.

`make install` is left unchanged — `preview` is a manual pre-flight,
not a confirmation gate. (Trivial changes still go straight through
`make install` from muscle memory.) If that becomes a footgun, add a
prompt later.

### Part 3 — Cutover use during the eventual rewrite

For the Lisp port, the same machinery does the cutover:

```
ruby render.rb …  → tmp/ruby-out/
lisp render        → tmp/lisp-out/
diff -ruN tmp/ruby-out/ tmp/lisp-out/
```

Empty diff against the real services tree = behavior parity. No new
tooling needed.

## Related plans

### `plans/remote-deploy.md` — direct synergy, blocks this plan

**Decision (2026-04-25): remote-deploy lands first.** The deployed
config lives on fatlaptop, not the laptop — a local-only preview
would diff against an empty/stale `/opt/mediaserver/config/` here
and miss the actual workflow entirely. Once remote-deploy Phase 2
introduces `RSYNC_DEST`/`REMOTE`, preview composes cleanly:

```make
preview: check all
	@rsync -ain --delete --out-format='%i %n' \
		config/ $(RSYNC_DEST)/opt/mediaserver/config/ \
		| grep -v '^\.' || echo "no changes"
	@$(REMOTE) tar -C /opt/mediaserver/config -cf - . \
		| tar -C tmp/deployed-snapshot -xf - \
		&& diff -ruN tmp/deployed-snapshot/ config/ || true
```

The content-diff line is the only awkward bit: `diff` can't reach
across ssh, so we snapshot the remote tree to `tmp/` (gitignored)
first. For `TARGET=local`, `$(REMOTE)` is empty and it degenerates to
a local `tar | tar` round-trip — slightly silly but uniform. Or
short-circuit: if `REMOTE` is empty, do the simple local `diff`
directly.

**Sequencing:** goldens (Part 1) are independent and can land anytime.
`make preview` (Part 2) is blocked on remote-deploy Phase 2. Goldens
will likely ship as a standalone PR while remote-deploy is in flight.

Additional design notes from the sequencing discussion:

- **Preview is additive, matching `make install`.** Today's install
  rsync uses `-av --exclude='systemd/'` with no `--delete`. Preview
  must match: deployed-only files (sqlite DBs, runtime state apps
  write into their config dirs) are left alone, not flagged as "to
  delete." Use `rsync -ain` (no `--delete`) for the manifest, and
  drive the content diff from rsync's changed-file list rather than
  a bidirectional `diff -ruN`.
- **Snapshot the remote tree to `tmp/`.** `diff` can't reach across
  ssh, so preview's first step is `$(REMOTE) tar -C /opt/mediaserver/config
  -cf - . | tar -C tmp/deployed -xf -`. `tmp/` is gitignored.

### `plans/nixos-target.md` — preview semantics shift

Under NixOS, "deploy" becomes `nixos-rebuild switch --target-host`,
which has its own preview verbs (`dry-activate`, `nvd diff
/run/current-system result`). The intermediate `config/` directory may
or may not still exist depending on how Nix templates emit container
configs. So:

- **Goldens still apply.** They test the renderer's input → output
  transformation, regardless of what consumes the output. They
  survive the NixOS cutover unchanged.
- **`make preview` partially obsoleted.** The rsync-and-diff form
  doesn't apply to a `nixos-rebuild` flow. The *concept* (preview
  before deploy) survives; the implementation gets replaced by Nix's
  own dry-run tooling. Don't over-invest in `make preview`'s
  ergonomics expecting it to outlive the Debian target.

This is another reason to keep `make preview` minimal — it's a
medium-term tool, not a permanent fixture.

### `plans/static-uids.md` — no interaction

Goldens use fixture service names with no `groups:` and no matching
host user, sidestepping the UID/GID code paths entirely. Static-UIDs
work can land before, during, or after this plan with no coordination.

## Open questions

- **Does any real `service.yml` use `${var}` interpolation
  (`Mediaserver.expand_vars`)?** If yes, fixture coverage should
  include it. If no, deletion is a candidate during the rewrite.
  Cheap one-time grep, but explicitly *not* a code change in this
  plan.
- **Should goldens cover the `--list-make` output of `render.rb`?**
  That branch produces Makefile fragments, not template output, but
  it's part of the renderer's contract. Probably yes — one extra
  golden file, `test/golden/list-make.txt`.
- **`UPDATE_GOLDEN=1` ergonomics.** Make-target convenience
  (`make goldens-update`) vs. raw env var. Defer until the workflow
  hurts.
