# Target dirs + `__service__` fan-out

**Status: shipped on `lisp-render` branch.**

Collapse the per-shape Make rules (6 systemd patterns + docker-compose +
mediaserver.target + static-copy) into one mechanism: source roots
merge into `config/`, `__service__` in a path means fan-out, empty
render output means skip the file.

Single commit. Goldens are the spec — `cd test && make all && git diff
--exit-code test/config/` clean ⇒ ship.

## Layout (as shipped)

Two source roots merge into `config/`:

| Source | Output |
|---|---|
| `services/<svc>/<path>` | `config/<svc>/<path>` (existing) |
| `targets/debian/<path>` | `config/<path>` (new) |

`__service__` is the literal placeholder token in source paths. Path
containing it = fan-out per service. Path without it = singleton.

```
targets/debian/
  systemd/
    mediaserver-network.service                  -> config/systemd/mediaserver-network.service
    mediaserver.target.elp                       -> config/systemd/mediaserver.target
    __service__.service.elp                      -> config/systemd/{svc}.service
    __service__.path.elp                         -> config/systemd/{svc}.path
    __service__-compose.path.elp                 -> config/systemd/{svc}-compose.path
    __service__-compose-reload.service.elp       -> config/systemd/{svc}-compose-reload.service
    __service__-reload.service.elp               -> config/systemd/{svc}-reload.service
  __service__/
    docker-compose.yml.elp                       -> config/{svc}/docker-compose.yml
```

## Bindings

`services` (the list) always bound. `service` bound only when path
contains `__service__` (or comes from `services/<svc>/...`). The CLI
already supported `--service NAME`; no change needed.

Filtering moves into templates: `(when (and dockerized (not has_unit)) ...)`
etc. SYSTEMD_SERVICES / SIGHUP_SERVICES / SERVICES_WITH_CONFIG /
DOCKERIZED_SERVICES are gone from `--list-make` — and `--list-make`
itself is gone (Make computes `ALL_SERVICES` from `wildcard services/*`).

## Make mechanism: per-template manifest

Fan-out templates produce *one Make target each* — a manifest file —
not N targets per template. Recipe iterates `ALL_SERVICES` internally,
writes non-empty renders, records what was written.

`mediaserver` is the literal placeholder in manifest filenames (reads
cleanly next to `mediaserver.target` and `mediaserver-network.service`).
The pattern rule swaps `mediaserver` ↔ `__service__` between target and
prereq via `.SECONDEXPANSION`:

```make
SINGLETON_ELPS := $(shell find $(TARGET_DIR) -name '*.elp' -not -path '*__service__*')
FANOUT_ELPS    := $(shell find $(TARGET_DIR) -name '*.elp' -path '*__service__*')
TARGET_STATIC  := $(shell find $(TARGET_DIR) -type f -not -name '*.elp' -not -path '*__service__*')

MANIFEST_TARGETS := $(patsubst $(TARGET_DIR)/%.elp,config/%.manifest,\
                      $(subst __service__,mediaserver,$(FANOUT_ELPS)))

.SECONDEXPANSION:
config/%.manifest: $$(subst mediaserver,__service__,$(TARGET_DIR)/%.elp) $(RENDER_BIN) | $$(@D)/
	@> $@
	@for svc in $(ALL_SERVICES); do \
	  f=$$(echo "$*" | sed "s|mediaserver|$$svc|"); out="config/$$f"; \
	  mkdir -p "$$(dirname "$$out")"; \
	  $(RENDER_BIN) --service $$svc --root . $< > "$$out.tmp"; \
	  if [ -s "$$out.tmp" ]; then mv "$$out.tmp" "$$out"; echo "$$f" >> $@; else rm "$$out.tmp"; fi; \
	done
```

Why this works: Make doesn't need to enumerate per-service outputs.
The manifest is the target; its recipe creates the files as side
effects. Pure wildcard + patsubst, no `$(shell)` at parse time, no
`-include` of generated Make fragments.

## Pattern rules in the Makefile (5 total)

- `config/%: services/%.elp` (per-service-specific, existing)
- `config/%: services/%` (non-template copy, existing)
- `config/%: $(TARGET_DIR)/%.elp` (singleton)
- `config/%: $(TARGET_DIR)/%` (target-tree copy)
- `config/%.manifest: ...` (fan-out)

Down from 11 dispatch rules.

## Renderer changes

- Dropped `--list-make`, `--files`, `SERVICE_FILES` env handling from
  the CLI.
- Added `:config-files` derived field in `field.lisp`: walks
  `services/<name>/`, returns relative paths of files (excluding
  `service.yml` and `*.erb`), with `.elp` stripped. Used by
  `__service__.path.elp` both as predicate (skip if empty) and as
  the `PathChanged=` watch list.
- No `__service__` substitution logic in the renderer itself — Make
  does the substitution before calling. Renderer gets a fully-resolved
  path and `--service NAME`.

## Templates

Each fan-out template wraps its body in `<%- (when <pred> -%> ... <% ) -%>`.

| Template | Predicate |
|---|---|
| `__service__.service.elp` | dockerized && !has-unit |
| `__service__.path.elp` | dockerized && !has-unit && config_files |
| `__service__-compose.path.elp` | dockerized && !has-unit |
| `__service__-compose-reload.service.elp` | dockerized && !has-unit |
| `__service__-reload.service.elp` | sighup-reload |
| `__service__/docker-compose.yml.elp` | dockerized |

## Verify

```
make clean
make all
cd test && make all
git diff --exit-code test/config/    # must be clean
make test                            # 43 runs, 0 failures
```

## What landed (vs original sketch)

- 5 Make pattern rules (down from 11). 27 deleted Makefile lines net.
- `--list-make` removed entirely. `ALL_SERVICES` derived in Make from
  `$(notdir $(wildcard services/*))`.
- 6 new manifest goldens added under `test/config/`; `list-make.txt`
  golden deleted.
- `bin/render` CLI surface shrunk: just `--service`, `--root`, and a
  template path.

## Skipped / future

- **Stale-file deletion in `make clean`.** Manifests enable it
  (anything in `config/` not in any manifest = delete). Edge cases
  (missing manifest, hand-edited config/) need thought. Separate work.
- **`.erb` shadow cleanup.** 27 `.erb` files still under `services/`
  and `systemd/` — orphans now that `render.rb` is gone. Left in
  place to avoid scope creep; the `:config-files` walker filters
  them out. A future commit can `git rm` them and drop the `.erb`
  filter from the derived field.
- **`systemd/user/media-stack.service`.** Referenced only by the
  legacy `script/install.sh`. Probably also orphan; left alone.
- **`config/mediaserver/` orphan dir.** The `__service__/docker-compose.yml.elp`
  manifest lives at `config/mediaserver/docker-compose.yml.manifest`,
  so the order-only `mkdir` rule creates `config/mediaserver/`. No
  service is named "mediaserver" so `make install`'s loop ignores it.
  Mildly weird; harmless.
- **`--target` flag.** Only one target exists (debian); hardcoded
  `targets/debian/` as the source root for now. Add the flag when
  nixos lands (`plans/nixos-target.md` Phase B).

## Lessons (the meta-point of this plan)

This branch took more back-and-forth than its scope warranted. Worth
calling out so future work doesn't repeat it.

**Where I overcomplicated, and what corrected it:**

- **Initial design proposed `.make.targets` — a generated Make fragment
  emitted by a new `bin/render --list-targets`, then `-include`d.** I
  reached for "renderer enumerates outputs" before checking whether
  Make's own primitives (`wildcard`, `patsubst`, manifest-as-target)
  could express the same thing. User had to ask "what do you need this
  for?" before I reconsidered. The eventual mechanism — manifest *is*
  the Make target, recipe creates files as side effects — was their
  proposal, and it's strictly cleaner: no `$(shell)` at parse time, no
  generated Make fragment, pure wildcard + patsubst.

- **Proposed predicate language / template frontmatter for fan-out
  filters.** User shut it down: "the only predicate is — if rendering
  produces empty output, don't write the file." Right call. The
  template's own `(when ...)` is the filter. No new metadata layer.

- **Kept `--list-make` infrastructure.** The recipe needed
  `ALL_SERVICES`, so I kept the whole `--list-make` machinery + the
  `.make.services` cached fragment + `-include`. User pointed out
  `ALL_SERVICES := $(notdir $(wildcard services/*))` — five characters
  in the Makefile, no shell-out, no cache file. I had been carrying
  forward old infrastructure without re-asking whether it was needed.

- **Stuck with `$service` literal placeholder despite the escaping
  pain.** Two `$$` for Make, single-quotes around `$<` to keep shell
  from expanding it, `$$$$service` inside `.SECONDEXPANSION` prereqs.
  User proposed `__service__`. Result: zero escaping anywhere. The
  whole "swap to `mediaserver` then back to `$service`" dance was
  there only because `$` collides with both Make and shell variable
  syntax. Should have been my proposal, not theirs.

- **Tried to delete the `.erb` shadows mid-branch to drop a filter
  clause.** User reverted. Scope discipline — the cleanup is real but
  it's separate work, and conflating it with the structural change
  makes the diff harder to review.

**Where my pushback was justified:**

- **`(uiop:file-pathname-p p)` filter on the directory walk.** User
  questioned whether it was needed; I tested removing it and the
  prometheus `.path` unit started emitting `PathChanged=.../rules/`
  lines for subdirectories. CL's `directory` returns both file- and
  directory-pathnames; the filter is load-bearing.

- **Suffix-strip verbosity (`(if (uiop:string-suffix-p r ".elp")
  (subseq r 0 (- (length r) 4)) r)`).** User wanted Ruby's
  `r.delete_suffix(".elp")`. CL stdlib genuinely doesn't have it. The
  options are: a 4-line helper used once (net wash), or pull in
  `cl-str`/`cl-ppcre` (preemptive dep). Either is fine; "this is the
  stdlib idiom" is the honest answer.

**Pattern to internalize.** When carrying forward an existing
mechanism (`--list-make`, `service_files` Make function, `$service`
naming, `.make.targets` instinct), ask: *is this load-bearing or
just ambient?* The user's "why?" questions caught at least three
mechanisms I'd kept by inertia. The branch shrunk meaningfully each
time.
