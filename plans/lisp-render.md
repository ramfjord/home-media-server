# Lisp render: fixtures-first

A Lisp renderer that produces byte-identical output to the existing
fixture goldens (`test/golden/`). Real services and templates are
left untouched. End state: `make test` runs Ruby's golden test and a
new Lisp golden test side-by-side; both pass against the same
goldens.

This is the *first* of (at least) two branches. The full main-project
cutover — porting every real `.erb` and deleting `render.rb` — is a
separate plan, drafted only after this one ships.

## Goal

`make test` runs:
1. The existing `test/golden_test.rb` (Ruby renders the fixture tree,
   diffs against `test/golden/`).
2. A new Lisp golden runner under `lisp/test/` that loads
   `lisp/mediaserver.asd`, renders ELP versions of the fixture
   templates, diffs against the same `test/golden/` files.

Both green ⇒ the Lisp implementation is at parity with the Ruby
implementation on the controlled fixture tree. That's the milestone.

## Context

The pre-rewrite plan (`plans/pre-rewrite.md`, shipped at
`92c3483 Add golden tests for renderer`) gave us exactly the safety
net this rewrite needs: a five-service fixture tree with rendered
goldens covering every networking mode, override branch, and
config-yaml lookup. The fixture goldens are language-agnostic — they
specify renderer output, not the language it's written in. So the
Lisp port can be built and verified entirely against fixtures, with
no risk to deployed services.

Scoping to fixtures keeps this branch small and reviewable.
Main-project work is its own beast (port ~80 templates, swap the
Makefile, retire the Ruby code) and benefits from already having a
working Lisp implementation to extend.

## Related plans

- `plans/pre-rewrite.md` — **shipped**. Provides `test/fixtures/`
  and `test/golden/`. This plan's success criterion is "Lisp
  renderer produces the same `test/golden/` output."
- `plans/deploy-preview.md` — sibling. **Not** the cutover gate for
  *this* plan (fixtures + their goldens are). Becomes the cutover
  gate for the future main-project plan.
- `plans/nixos-target.md` — downstream. Adding a `--target nixos`
  emitter is much cheaper after a Lisp implementation exists. No
  coordination with this plan.
- `plans/static-uids.md` — orthogonal.
- `elp/plans/*.md` — internal ELP plans (mmap, reader-driven
  codegen, source locations). All shipped or in-progress in `elp/`;
  this plan consumes the public API (`elp:render`,
  `elp:template-code`) and does not modify ELP internals.
- **`elp/plans/trim-mode.md`** (to be drafted under `elp/`) —
  **prerequisite for commit 5 below.** ELP currently has no
  whitespace-trimming for block tags; a port of templates with
  `<% (when ...) %>...<% ) %>` produces extra blank lines vs.
  Ruby's `<>` trim mode. Rather than format around the absence
  (cramming `<%` directly adjacent to content, which makes
  templates ugly), wait for ELP to grow the trim behavior
  Ruby's ERB has, then write templates in their natural shape.
  Commit 5 cannot land until that ELP work ships.
- **Future plan** (not yet drafted): main-project cutover. Will
  port every real `.erb`, build a `bin/render` saved image, swap
  the Makefile to per-service / aggregator targets, delete
  `render.rb` and `lib/mediaserver/`. Drafted *after* this one
  ships, when the design is grounded in working code rather than
  speculation.

## Design notes

### Settled in REPL exploration

The shape of the implementation was prototyped against the live
fixture tree before drafting this plan. Decisions baked in:

- **Plist with keyword keys**, `_` → `-` at the load boundary.
  cl-yaml hands back hash-tables with EQUALP string keys; a 5-line
  walker (`yaml->plist`) flattens to a keyword-keyed plist that
  prints readably and pattern-matches with `destructuring-bind`.
- **Single `field` accessor** as the public API. Templates write
  `(field s :name)`, `(field s :use-vpn)`, `(field s :port)` —
  there is no `service` class. `field` falls through to a
  `*derived-fields*` alist for computed values (`:compose-file`,
  `:source-dir`, `:dockerized`, `:has-unit`). Adding a new derived
  field is one alist entry.
- **No `expand-vars` on the Lisp side.** `service.yml` files use
  `<%= install_base %>` (ELP-preprocessed at load time, same
  binding as the templates themselves). `${var}` syntax is gone
  from fixture YAML; it remains in real `service.yml`s only
  because the Ruby renderer still handles them via its own
  `expand_vars`, which is left in place for the duration of this
  branch (real services aren't migrated here). Coexists cleanly
  with docker-compose's runtime `${VAR}` for secret env vars,
  which never collides with `<%= ... %>`.
- **ELP gets a trim mode** (Ruby-ERB `<>` equivalent) before
  templates are ported. Block tags like `<% (when ...) %>` need to
  consume their trailing newline when they occupy a whole line,
  the way Ruby's `<>` trim mode does, otherwise port output gets
  extra blank lines. Without trim mode, the alternative is
  cramming `<%` directly adjacent to content, which makes
  templates ugly. Tracked separately under
  `elp/plans/trim-mode.md`; commit 5 below blocks on it.
- **Validation: 15 lines, three checks**.
  1. Every service has `:name`.
  2. No two services share a `:port`.
  3. Typo detection at field access: `field` errors when called
     with a key not in `*known-fields*` (the union of every key
     appearing in any loaded service plist) ∪ `*derived-fields*`
     ∪ a small built-in allowlist. So `(field s :prot)` errors
     with "Unknown field :PROT. Known: :NAME :PORT ...", but
     `(field s :groups)` on a service that doesn't have `:groups`
     correctly returns nil because some other service does.
  Per-field type checking and cross-service ref validation are
  out — `make check` (promtool / amtool / docker-compose-config)
  catches anything that produces malformed output, and ELP gives
  `file:line:column` on render-time errors. The validator's job
  is "catch the bug class that nothing downstream catches"
  (port conflicts, typos), not "type-check every field."
- **Service files stay YAML**. The leverage of a Lisp rewrite is
  in templating and data manipulation, not on-disk format. cl-yaml
  is a stable dep already in Quicklisp; libyaml is in the system
  package set. yaml-to-plist is 5 lines. Any "remove a dependency"
  win from switching to s-exprs is dwarfed by the cost of
  rewriting every existing service.yml and the ergonomic loss for
  hand-editing.
- **No `Config` class.** `load-config` returns a plist:
  `(:services LIST :globals PLIST :raw HASH-TABLE-OR-PLIST)`.
- **One package**: `mediaserver`. Surface is small enough that
  splitting hurts.

### Layout

```
lisp/
  mediaserver.asd            ; depends on cl-yaml, elp
  src/
    package.lisp             ; (defpackage :mediaserver ...)
    config.lisp              ; yaml->plist, load-config, deep-merge, validate
    field.lisp               ; field accessor, *derived-fields*, *known-fields*
    render.lisp              ; render-tree driver
  test/
    package.lisp
    fixture-test.lisp        ; FiveAM; renders fixtures, diffs goldens
    run.lisp                 ; entry point invoked by `make test`
test/fixtures/                ; existing, plus *.elp versions of *.erb
test/golden/                  ; existing, unchanged
```

ELP fixture templates use `.elp` extension; Ruby fixture templates
keep `.erb`. Both render to the same goldens. A given fixture has
both versions side-by-side until the future cutover plan deletes
the Ruby ones.

### Dependencies

`mediaserver.asd` depends on `cl-yaml` (Quicklisp) and `elp`
(vendored in `./elp/`). cl-yaml requires `libyaml` at the system
level — already installed (Arch package `libyaml`). Quicklisp is
already wired into `~/.sbclrc`; `ql:quickload` works in fresh
SBCL on this box.

For CI / fresh machines: `make test`'s Lisp branch should
`(ql:quickload :mediaserver)` rather than relying on
`asdf:load-system` directly, so the YAML dep gets pulled
transparently. Document the bootstrap in `lisp/README.md`.

### Render driver shape

`render-tree` takes a config plist and an output-dir, walks ELP
templates in the fixture tree, renders each through `elp:render`,
writes results into the output dir. For per-service templates
(systemd `.elp`s parameterized by service name), expand to one
output per service, mirroring the Ruby renderer's
`SERVICE_NAME=<svc>` convention.

Write-if-changed semantics deferred to the future main-project
plan — fixture tests render to a tmpdir on every run and diff
against goldens, so write-if-changed isn't load-bearing here.

## Commits

1. **Skeleton ASDF system + dependency check** — Add
   `lisp/mediaserver.asd`, `lisp/src/package.lisp`,
   placeholder `lisp/src/config.lisp`. `lisp/README.md` documents
   `(ql:quickload :mediaserver)`.
   *Verify:* `(ql:quickload :mediaserver)` in a fresh SBCL
   succeeds, pulls cl-yaml as a transitive dep, exits clean. The
   package `:mediaserver` exists. No symbols exported yet.

2a. **Ruby-side: ERB-preprocess `service.yml`; migrate fixtures
    to `<%= var %>`** — Modify `lib/mediaserver/config.rb` to
    ERB-render each `service.yml` (with merged globals bound as
    locals) before YAML parsing. Migrate fixture `service.yml`s
    from `${var}` to `<%= var %>`. Drop the `${install_base}`
    reference in the fixture `config.local.yml` override.
    Update the two goldens where `${media_path}` was previously
    leaking through unsubstituted. `expand_vars` stays in Ruby
    for real `service.yml`s.
    *Verify:* `make test` green (Ruby unit tests + golden test).
    Real services render unchanged via `make all`.

2b. **Lisp-side: `yaml->plist`, `field`, `*derived-fields*`** —
    Port the YAML-to-plist walker and field accessor (no
    `expand-vars`; substitution happens in load-config via ELP
    preprocessing). Export `field`, `*globals*`, `*derived-fields*`.
    Add unit tests covering plist conversion, direct lookup,
    missing-key handling, and derived fields.
    *Verify:* fiveam tests green.

3. **`load-config` + validator** — `(mediaserver:load-config
   :root path)` reads `globals.yml`, globs `services/*/service.yml`,
   ELP-preprocesses each (with merged globals as ELP context),
   parses YAML, applies `config.local.yml` `service_overrides` via
   plist deep-merge, sorts by `:order`, validates (required
   `:name`, unique ports, sets `*known-fields*`). Returns
   `(:services ... :globals ... :raw ...)` and sets `*globals*`.
   Tests cover: load fixture tree, services sorted correctly,
   ELP substitution worked (including `*default-globals*`
   fall-through for `media_path`), override applied (scalar +
   array union), port-conflict and missing-name detection,
   `(field s :typo)` errors after load.
   *Verify:* fiveam tests green.

4. **`render-tree` driver** — `(mediaserver:render-tree config
   :template-root R :output-dir O)` walks ELP templates under R
   (`*.elp` files), renders each through `elp:render` with
   appropriate context bindings, writes outputs into O mirroring
   the Ruby Makefile's path conventions. For per-service systemd
   templates, expand once per applicable service.
   *Verify:* unit test renders an empty template tree to a
   tmpdir and confirms zero outputs. Renders a single hand-written
   ELP template ("hello <%= (field s :name) %>") and asserts the
   output content.

5. **Port fixture `.erb`s to ELP, side-by-side** — For each
   fixture template (5 services' worth, plus aggregators), add a
   `.elp` sibling next to the existing `.erb`. Ruby goldens are
   the spec; the Lisp render must produce identical bytes.

   **Prerequisite: ELP trim mode** (see `elp/plans/trim-mode.md`).
   Templates are written in their natural shape with `<% (when ...) %>`
   on its own line, like the Ruby `<% if ... %>` lines they replace.
   That requires ELP to consume the trailing newline after a tag
   that occupies a whole line, the way Ruby's ERB `<>` trim mode
   does. Don't start commit 5 until the ELP feature ships and
   has been pulled into this repo's vendored `elp/`.

   **`.erb` and `.elp` coexistence in service source dirs.** Once
   `services/<svc>/Caddyfile.erb` and `Caddyfile.elp` both exist,
   the path-watcher template (`systemd/service.path.erb` /
   `service.path.elp`) needs to skip the *other* engine's
   extension when enumerating files, otherwise Ruby will emit a
   `PathChanged=...Caddyfile.elp` line and Lisp will emit a
   duplicate `Caddyfile` after stripping `.elp`. Add the filter
   to both templates as a same-commit change; the Ruby filter is
   a no-op until the first `.elp` lands, so it doesn't disturb
   existing goldens.

   **`service.compose.yml.elp`** is the riskiest single file
   (Ruby builds a hash and calls `to_yaml`); approach it by
   constructing an alist and emitting via `cl-yaml:emit`, with a
   REPL spike *first* to confirm cl-yaml's emit output matches
   Ruby's `Psych#to_yaml` byte-for-byte on a representative hash.
   If it doesn't, fall back to a hand-rolled YAML emitter for
   that template (the subset we need is small).

   *Verify:* one ELP template at a time, render via
   `render-tree`, `diff` against the corresponding golden file.
   Commit when the whole fixture set's diff is empty. Keep
   commits small (one fixture cluster per commit) so each diff
   is reviewable.

6. **Lisp golden test runner + Makefile wiring** — Add
   `lisp/test/run.lisp` that invokes `render-tree` on the
   fixture tree to a tmpdir and diffs against `test/golden/`.
   Wire into the existing `make test` target so Ruby and Lisp
   golden tests run in sequence. Update `CLAUDE.md` with a brief
   "Lisp implementation lives under `lisp/`, run via `make test`"
   line.
   *Verify:* `make test` runs both runners; both green. Tweak one
   `.elp` template — Lisp test fails with a readable diff. Revert
   — both green again.

## Future plans

- **Main-project cutover** — port every real `.erb`, build
  `bin/render` as a saved SBCL image, swap the Makefile to per-
  service + aggregator targets (`render-<svc>`,
  `render-aggregators`, `install-<svc>` family), delete
  `render.rb` and `lib/mediaserver/`. Drafted as its own plan
  after this one ships. The cutover gate is `make preview`
  (`plans/deploy-preview.md`) plus a manual `diff -r` against a
  pre-cutover-tagged config tree.
- **NixOS target** — `bin/render --target nixos`. See
  `plans/nixos-target.md`.
- **Static UIDs** — drop the `id -u` shell-out from the
  `:user-id` derived field. See `plans/static-uids.md`.

## Non-goals

- **Real services and templates are not touched.** Only fixtures.
- **`render.rb` and `lib/mediaserver/` are not deleted.**
- **No `bin/render` binary.** REPL + `(asdf:load-system :mediaserver)`
  is sufficient for fixture tests. Binary is a main-project plan
  concern.
- **No new template features beyond trim mode.** Trim mode is
  scoped into `elp/plans/trim-mode.md` and is a prerequisite, not
  scope for this plan. Custom delimiters, partials, etc. — out.
- **No CI changes.** `make test` already runs in the existing
  workflow; if the runner needs SBCL + Quicklisp added, that's a
  one-liner to flag if/when CI exists.

## Open questions

- **`cl-yaml:emit` byte-equivalence with Ruby's `Psych#to_yaml`.**
  Spike in commit 5, before touching `service.compose.yml.elp`.
  Most likely failure modes: key ordering, string escaping, line
  wrapping. Resolution paths in priority order: (a) tunable via
  cl-yaml options → use them; (b) post-process the emitted string
  → ugly but bounded; (c) hand-roll YAML emission for this
  template → small and explicit, the YAML subset we need is tiny.
- **ELP performance on the fixture set.** Probably a non-issue
  (fixture tree is ~10 templates), but worth noting on the first
  full render pass: if anything is surprisingly slow, file a plan
  under `elp/plans/` rather than working around it here.
- **`.elp` extension vs. another scheme.** Side-by-side with `.erb`
  in the same directory is the cheapest layout. If it gets
  confusing during the port, alternative is a parallel tree
  (`test/fixtures-lisp/`). Defer the call until the port is
  underway.
