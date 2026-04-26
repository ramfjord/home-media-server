# Lisp render binary

Replace `render.rb` + `lib/mediaserver/*.rb` (Ruby + ERB, one process
per template) with a single SBCL binary that loads the service tree
once and renders every template in one pass. Templates switch from
embedded Ruby to embedded Lisp via `elp/`.

## Goal

A `bin/render` binary that, given the repo root, walks every template
under `services/`, top-level `*.erb`, and `systemd/*.erb`, and writes
the same `config/` tree the current Ruby renderer produces — bit-for-bit
identical against the live `services/` and the golden fixtures.

`make all` invokes `bin/render` exactly once per build; per-template
shelling-out goes away.

## Context

Two motivations stack:

1. **Process-per-template is the dominant cost.** Each ERB target
   spawns Ruby, parses every `service.yml` from scratch, builds the
   `Config`, then renders one template. For ~85 templates that's ~85
   YAML parses per `make all`. A single-pass binary reads the tree
   once.
2. **The Ruby code is the thing in the way of every other plan.**
   `nixos-target.md` wants a second emitter; `deploy-preview.md` wants
   a render-and-diff cutover gate; `static-uids.md` wants the renderer
   to stop shelling out to `id -u`. All of those are easier on top of
   a Lisp implementation that's already reasoning about the service
   tree as data, not strings being formatted by ERB.

ELP exists, has golden tests, error reporting with file:line:column,
and a CLI mode that already saves to a self-contained binary
(`elp/bin/elp`). The codegen path returns a sexp; we can keep it that
way and call `eval` from inside the render driver, no separate binary
per template.

The pre-rewrite goldens (just merged) are the safety net: the new
renderer must produce byte-identical output on the fixture tree and
on the real `services/` tree. The old renderer stays in place until
the cutover commit so a side-by-side diff is always available.

## Related plans

- `plans/pre-rewrite.md` — **shipped** (`92c3483 Add golden tests for
  renderer`). Provides `test/golden/`. This plan is the rewrite the
  pre-rewrite plan was scoped to enable. The fixture `.erb` files get
  ported to ELP in this plan; the rendered goldens stay byte-stable.
- `plans/deploy-preview.md` — sibling, in flight (not yet started per
  `plans/MERGE_ORDER.md` if present). **Strong synergy:** preview's
  rsync-and-diff is the cutover gate the deploy-preview plan
  explicitly calls out ("render with both implementations, diff the
  trees, ship when the diff is empty"). If preview lands first, the
  cutover commit here uses it directly. If not, this plan falls back
  to a one-off `diff -r config-ruby/ config-lisp/`. Either order
  works; sequencing is opportunistic, not blocking.
- `plans/nixos-target.md` — downstream. Adding a second emitter
  (`--target nixos`) is much cheaper after this rewrite than before:
  the templates already build sexps, so a second emitter is a second
  set of templates plus a target switch, not a parallel ERB pipeline.
  No coordination needed; nixos-target should reference this plan
  once it's in flight.
- `plans/static-uids.md` — orthogonal but adjacent. Removing
  `id -u <name>` shelling lives equally well in Ruby or Lisp. If
  static-uids lands first, the Lisp `service-user-id` becomes a
  literal lookup; if this plan lands first, static-uids has fewer
  call sites to change.
- `elp/plans/*.md` — internal ELP plans (mmap, reader-driven codegen,
  swank source locations). All shipped or in-progress in `elp/`; this
  plan consumes the public API (`elp:render`, `elp:template-code`)
  and does not touch ELP internals. If a missing ELP feature shows up
  during the port, file it as a sibling plan under `elp/plans/`, not
  here.

## Design notes

### Template language: full Lisp, not a DSL

ELP gives templates full Common Lisp inside `<% %>`. Templates already
contain non-trivial logic (see `systemd/service.compose.yml.erb`
building a YAML hash with conditionals); a restricted DSL would mean
porting that logic into the renderer. Keep the "full host language at
template time" property — translate Ruby idioms to Lisp idioms,
don't try to hide them.

### Service / config representation

Mirror the Ruby `ProjectService` and `Config` shape, exposed as a
package `mediaserver`. Each service is a struct (or class with reader
generics — pick whichever falls out of REPL exploration). Templates
receive `service` (the current service), `services` (the list),
`globals` (alist), and `raw` (the full merged hash) as context, just
like ERB's `binding`. Method calls translate one-to-one:

  Ruby                          Lisp
  ----                          ----
  service.name                  (service-name service)
  service.use_vpn?              (service-use-vpn? service)
  services.select { |s| ... }   (remove-if-not (lambda (s) ...) services)
  hash.to_yaml                  (yaml:emit hash)   ; via cl-yaml

YAML I/O uses `cl-yaml` (Quicklisp). Group lookup (`getent group`) and
user-id lookup (`id -u`) shell out the same way they do today; the
behavior change is "one shell-out per service, not per render." Both
are slated for removal in `static-uids.md` — don't pre-empt.

### Render driver: one walk, one eval each

The driver walks `services/**/*.erb`, top-level `*.erb`, and
`systemd/*.erb`. For each template:

1. Compute the destination path (mirror current Makefile pattern
   rules: `services/<svc>/<rel>.erb → config/<svc>/<rel>`,
   `systemd/<x>.erb → config/systemd/<x>`,
   `<x>.erb → config/<x>`).
2. For per-service templates under `systemd/` (`service.service.erb`,
   `service.path.erb`, etc.), expand to one output per applicable
   service, same as the current `SERVICE_NAME=<svc> ./render.rb`
   convention.
3. Bind context, `(elp:render path context stream)` to a buffer,
   write-if-changed to disk.

Write-if-changed semantics: only `rename(2)` the new file into place
if the bytes differ. Rsync already only ships changed files, but
preserving mtime keeps `make`'s incremental story honest if anything
ever depends on output mtimes (e.g. systemd path units watching the
installed tree — already covered by rsync, so this is belt-and-braces).

### Make granularity vs. reload granularity

The user-facing concern: "if I edit one service's `service.yml`, only
that service should reload." Today that's enforced through Make's
per-target dependency graph. After this rewrite, Make gets coarser
but the *reload* granularity is preserved, because reloads aren't
driven by Make:

- **Make** sees one sentinel target (`config/.rendered`). Any input
  change → re-run the binary → whole tree re-rendered. Coarser than
  today, but a single-process re-render is faster than ~85
  per-template Ruby invocations even when it does more nominal work.
- **Disk writes** are content-gated: the binary `rename(2)`s a new
  file into place only when bytes differ. Aggregators like
  `homer/config.yml` legitimately re-render when any service.yml
  changes — but if nothing in homer's output text actually changed,
  no write happens, no mtime bump, nothing downstream notices.
- **Reload granularity** lives at the install layer. `rsync` only
  ships changed files; `.path` units only fire on file write at
  `/opt/mediaserver/config/`. So the chain "edit svc.yaml → only
  that service reloads" still holds, end-to-end, content-based at
  every step.

Editing one `service.yml` re-renders the world locally, ships
nothing if the only file whose output changed is that service's, and
fires no path units except that service's. Same outward behavior as
today, by a different mechanism.

### Makefile shape

Today: ~10 explicit aggregator rules + a pattern rule per template
class, each calling `./render.rb`. After: per-service + aggregator
sentinels, composed into `all`. Per-service granularity is preserved
so `make render-jellyfin` is snappy when iterating on one service.

  bin/render: $(LISP_SOURCES) elp/elp.asd
  	cd lisp && sbcl --script build.lisp   # save-lisp-and-die

  # Per-service: depends only on this service's inputs.
  render-%: bin/render globals.yml services/%/service.yml \
            $$(shell find services/% -name '*.erb' 2>/dev/null) \
            $(wildcard config.local.yml)
  	./bin/render --service $*

  # Aggregators: depend on every service.yml because they iterate.
  render-aggregators: bin/render globals.yml $(SERVICE_YAMLS) \
                     $(AGGREGATOR_ERBS) $(wildcard config.local.yml)
  	./bin/render --aggregators

  all: $(addprefix render-,$(ALL_SERVICES)) render-aggregators \
       $(NON_ERB_CONFIG_TARGETS)

The split is the load-bearing trick: editing
`services/jellyfin/service.yml` reruns `render-jellyfin` (small) and
`render-aggregators` (small), but leaves the other 19 `render-<svc>`
targets cached. Editing one template under `services/jellyfin/`
reruns only `render-jellyfin`. That's the dev-loop snappiness today's
per-file targets provide, kept.

`bin/render` always parses every service.yml on startup, even in
`--service` mode — cheap (one YAML pass, ~10ms), and it gives
cross-service validation for free on every per-service render.

`.make.services` goes away — the binary derives all service lists
internally. `ALL_SERVICES` for the `addprefix` above comes from a
small `bin/render --list-services` subcommand cached the same way
`.make.services` is today (one ssize-cheap invocation per `make`
run), or via a static glob in the Makefile if startup ever bothers
us.

The user's framing was "the binary depends on service ymls." The
**per-service target** depends on that service's yml; the
**aggregator target** depends on all of them; the **binary itself**
only depends on Lisp sources. Three dependency edges, each narrow
to its own concern.

### Per-service lifecycle targets

While we're shaping per-service Make targets, group the existing and
new lifecycle verbs into a consistent set:

  render-<svc>     → bin/render --service <svc>
  install-<svc>    → render-<svc> render-aggregators + rsync just
                     config/<svc>/ (and aggregator outputs that
                     reference <svc>; in practice, just rsync the
                     whole config/ since aggregator deltas are
                     content-gated by write-if-changed)
  restart-<svc>    → already exists
  start-<svc>      → systemctl start <svc>.service via $(REMOTE)
  stop-<svc>       → systemctl stop  <svc>.service via $(REMOTE)
  status-<svc>     → systemctl status <svc>.service via $(REMOTE)

Land these alongside the rendering split so the per-service story is
end-to-end coherent in one branch.

**Workflow note for CLAUDE.md.** `make render-<svc>` is the iterate
verb; `make all` is the full-rebuild verb. Reflexively typing
`make all` while iterating costs ~1s per loop instead of ~50ms.
Worth one line in the docs so the muscle memory shifts.

### Cutover safety

Before deleting `render.rb`, run both engines on the real tree and
diff. The pre-rewrite goldens cover the fixture tree but not the
real one — the real tree is what `make preview` (sibling plan) is for.
If preview hasn't shipped, the cutover commit's verify step is a
one-off `diff -r`.

### What `bin/render` does NOT do

- No `--target nixos` (that's `nixos-target.md`'s job — but the design
  here is friendly to it).
- No watch mode. Path units handle reloads on the deploy side; on the
  dev side, `make all` is fast enough after this rewrite that watch
  is overkill.
- No partial render (`bin/render --only caddy`). The whole-tree render
  is the unit; if it's ever too slow, profile then.

## Commits

1. **Inventory the renderer's template surface** — Grep every `.erb`
   for method calls on `service`, iterations over `services`, lookups
   in `globals` / `config_yaml`, and any other binding name. Drop
   the result into `plans/lisp-render-surface.md` (or a comment
   block in this plan) as a checklist: every Ruby method that needs
   a Lisp equivalent. This is the source of truth for the
   `mediaserver` Lisp package's API. Cross-check against
   `lib/mediaserver/config.rb` to make sure no ProjectService method
   is missed.
   *Verify:* checklist exists; spot-check three templates of
   different shapes (a per-service systemd unit, an aggregator like
   Caddyfile, a YAML-emitting one like service.compose.yml) and
   confirm every binding they reference appears in the checklist.

2. **Add `lisp/mediaserver` system: config loader + service struct** —
   New ASDF system at `lisp/mediaserver.asd` depending on `cl-yaml`,
   `elp`, and `uiop`. `mediaserver:load-config` reads `globals.yml`,
   merges `services/*/service.yml` (sorted, with `order` field),
   applies `config.local.yml` overrides + `service_overrides`,
   expands `${var}` references. Returns a `config` struct with
   `services`, `globals`, `raw`. Service struct has readers for
   every checklist item from commit 1. No template rendering yet.
   *Verify:* FiveAM tests under `lisp/test/` cover load + override
   + var expansion against a small fixture tree. `(mediaserver:load-config
   "test/fixtures/")` returns the same shape as
   `Mediaserver::Config.load(root: "test/fixtures/")` (compare
   serialized structures by hand once; commit a regression test).

3. **Add render driver: walk templates, render, write-if-changed** —
   `mediaserver:render-tree` takes a config and an output dir, walks
   `services/**/*.erb`, top-level `*.erb`, and per-service
   `systemd/*.erb` (one output per service), binds context, calls
   `elp:render`, writes only when content changed. No CLI yet.
   *Verify:* unit test renders the fixture tree from commit 2 to a
   tmpdir; the set of output paths matches what the current
   `Makefile` produces for the same input (compare against
   `make all` output paths under `test/fixtures/`).

4. **Port fixture and per-service `.erb` templates to ELP** — Mechanical
   translation of every `services/*/*.erb` (excluding aggregators)
   plus the fixture templates under `test/fixtures/`. Ruby method
   calls become Lisp function calls per the commit-1 surface map.
   Templates keep the `.erb` extension to minimize Makefile churn;
   the engine is selected by content (or by file-tree position),
   not by extension. This is where `service.compose.yml.erb`'s
   YAML-hash-construction translates to building an alist and
   passing it to `cl-yaml:emit`.
   *Verify:* `lisp/bin/render-once <svc>` (a tiny driver added in
   this commit, deleted in commit 7) renders one service's tree;
   `diff -r config-ruby/<svc>/ config-lisp/<svc>/` is empty for
   each ported service. Commit per service-cluster (e.g. all
   prometheus templates in one commit, all jellyfin in another) so
   each commit's diff is reviewable.

5. **Port aggregator templates** — `Caddyfile.erb`, `homer/config.yml.erb`,
   `otelcol-config.yaml.erb`, `prometheus/rules/mediaserver.yaml.erb`,
   `systemd/mediaserver.target.erb`. These iterate `services` and
   build cross-service output. Goldens for the fixture aggregators
   re-seed identically; goldens for `--list-make` either port to
   the new binary's subcommand or get deleted with `--list-make`.
   *Verify:* `bin/render-once` for each aggregator produces a
   tree-identical diff against the Ruby render. Goldens still pass.

6. **Build `bin/render` as a saved SBCL image** — Real CLI:
   `--service NAME`, `--aggregators`, `--list-services`, plus
   default (whole tree). Argparse for repo root and output dir
   (defaults: `.` and `config/`). Add `Makefile` rule `bin/render:
   $(LISP_SOURCES) elp/elp.asd lisp/mediaserver.asd` that runs `sbcl
   --script build.lisp`, producing a self-contained binary the same
   way `elp/bin/elp` is built today. Add `lisp/build.lisp`.
   *Verify:* `./bin/render` against the real repo writes a
   `config/` tree byte-identical to `make all` (Ruby). `diff -r`
   confirms. `./bin/render --service jellyfin` writes only
   `config/jellyfin/`. Binary is reproducible (two builds in a row
   produce identical bytes; if SBCL save-lisp embeds a timestamp,
   document the caveat — don't fight it).

7. **Cutover Makefile + delete Ruby renderer** — Replace
   per-template `./render.rb` recipes with `render-%` (per service)
   and `render-aggregators` targets per the Makefile-shape section.
   Add `install-<svc>`, `start-<svc>`, `stop-<svc>`, `status-<svc>`
   pattern rules for symmetry with the existing `restart-<svc>`.
   Drop `.make.services` (replace with a `bin/render --list-services`
   cache file if needed for `addprefix` expansion). Drop
   `--list-make` from the binary unless still referenced. Delete
   `render.rb`, `lib/mediaserver/`, `test/config_test.rb`,
   `test/renderer_test.rb`, `test/validator_test.rb`. Keep
   `test/golden_test.rb` repointed at the Lisp renderer (or rewrite
   in Lisp under `lisp/test/` — pick whichever stays cheaper to
   run in CI). Update `CLAUDE.md` and `README.md`: replace "configs
   generated from `.erb` templates via `render.rb`" with the Lisp
   story, document `bin/render` build dependency, and add a
   workflow line that `make render-<svc>` is the dev-loop verb
   (not `make all`).
   *Verify:* `make clean && make all` produces a `config/` tree
   byte-identical to a tag taken at the start of this branch
   (`git tag pre-lisp-render`). `make render-jellyfin` after a
   `make clean` produces only `config/jellyfin/` plus the
   aggregator outputs (and is noticeably faster than `make all`).
   Editing one service.yml and running `make all` reruns only that
   service's `render-<svc>` plus `render-aggregators`, leaving
   other targets cached (verified via `make -d` or by mtime
   inspection). `make test` green. `make check` green. Either
   `make preview` shows no changes against a freshly
   `make install`'d host, or a manual `diff -r` against an
   archived `config/` from main shows no changes.

## Future plans

- **`bin/render --target nixos`** — see `plans/nixos-target.md`.
  Designed in but explicitly deferred from this branch.
- **Drop `id -u` / `getent` shell-outs** — see `plans/static-uids.md`.
- **Watch mode for dev** — only if `make all` ever feels slow after
  the cutover. Don't pre-build it.
- **Move `elp/` and `lisp/` under one top-level Lisp tree** — only
  worth doing if/when a third Lisp library shows up in this repo.

## Non-goals

- **No new template features.** Whitespace-trimming, custom
  delimiters, partials — out of scope. The port mirrors current
  behavior.
- **No splitting Lisp packages by concern.** One `mediaserver`
  package + `elp` is fine until it isn't. Resist over-modularizing
  before the surface is settled.
- **No CI changes in this branch.** CI runs `make test` and `make
  check`; both keep working as long as the Lisp toolchain is on the
  runner. If it isn't, that's a separate (small) plan.
- **No removing the `.erb` extension.** Renaming 85 files is pure
  churn; the engine doesn't care what the files are called.

## Open questions

- **`cl-yaml` output stability vs. Ruby's `Psych`.** The
  service.compose.yml render currently uses Ruby `Hash#to_yaml`. If
  cl-yaml emits keys in a different order or escapes strings
  differently, byte-identical diffs are impossible — and
  byte-identical is the cutover gate. Spike this in commit 2 or
  early commit 4: take one hash, emit with both, diff. If they
  diverge in ways that aren't tunable, options are (a) sort/format
  the Lisp side to match Ruby, (b) accept the diff and update
  goldens at cutover (use `make preview` once on the real tree to
  confirm semantically equivalent), or (c) emit YAML by hand for
  this one template. Resolve before commit 4 reaches
  service.compose.yml.
- **Building the binary in CI / on fresh machines.** SBCL +
  Quicklisp + cl-yaml needs to be available wherever `make all`
  runs. Currently that's Thomas's laptop and fatlaptop only;
  documenting the bootstrap in `CLAUDE.md` is enough. Revisit if a
  new dev machine shows up.
- **Saved-image size and startup.** `elp/bin/elp` is already a saved
  SBCL image; expect ~50MB and ~50ms startup. Acceptable for a
  one-shot per `make all` build. If startup ever matters, look at
  `sb-ext:save-lisp-and-die :compression t`.
