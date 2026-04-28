# Target dirs + `$service` fan-out

Collapse the per-shape Make rules (6 systemd patterns + docker-compose +
mediaserver.target + static-copy) into one mechanism: source roots
merge into `config/`, `$service` in a path means fan-out, empty render
output means skip the file.

Single commit. Goldens are the spec — `cd test && make all && git diff
--exit-code test/config/` clean ⇒ ship.

## Layout

Two source roots merge into `config/`:

| Source | Output |
|---|---|
| `services/<svc>/<path>` | `config/<svc>/<path>` (existing) |
| `targets/debian/<path>` | `config/<path>` (new) |

`$service` is a literal token in source paths. Path containing it =
fan-out per service. Path without it = singleton.

After the move:

```
targets/debian/
  systemd/
    mediaserver-network.service                    -> config/systemd/mediaserver-network.service
    mediaserver.target.elp                         -> config/systemd/mediaserver.target
    $service.service.elp                           -> config/systemd/{svc}.service
    $service.path.elp                              -> config/systemd/{svc}.path
    $service-compose.path.elp                      -> config/systemd/{svc}-compose.path
    $service-compose-reload.service.elp            -> config/systemd/{svc}-compose-reload.service
    $service-reload.service.elp                    -> config/systemd/{svc}-reload.service
  $service/
    docker-compose.yml.elp                         -> config/{svc}/docker-compose.yml
```

Old `systemd/` goes away. (No top-level `*.elp` exists today.)

## Bindings

`services` (the list) always bound. `service` bound only when path
contains `$service` (or comes from `services/<svc>/...`). No
`SERVICE_NAME` env var change needed — current CLI already supports
`--service NAME`.

Filtering moves into templates: `(when (field service :unit) ...)` etc.
SYSTEMD_SERVICES / SIGHUP_SERVICES / SERVICES_WITH_CONFIG /
DOCKERIZED_SERVICES go away from `--list-make`.

## Make mechanism: per-template manifest

Fan-out templates produce *one Make target each* — a manifest file —
not N targets per template. Recipe iterates services internally,
writes non-empty renders, records what was written.

`mediaserver` is the literal placeholder in manifest filenames (reads
cleanly next to `mediaserver.target` and `mediaserver-network.service`).
The pattern rule swaps `mediaserver` ↔ `$service` between target and
prereq:

```make
FANOUT_ELPS := $(shell find targets -name '*$$service*.elp')
MANIFEST_TARGETS := $(patsubst targets/debian/%.elp,config/%.manifest,\
                      $(subst $$service,mediaserver,$(FANOUT_ELPS)))

.SECONDEXPANSION:
config/%.manifest: $$(subst mediaserver,$$$$service,targets/debian/%.elp) $(RENDER_BIN)
	@> $@
	@for svc in $(ALL_SERVICES); do f=$$(echo "$*" | sed "s|mediaserver|$$svc|"); \
	  c=$$($(RENDER_BIN) --service $$svc --root . $<); \
	  [ -z "$$c" ] || { printf '%s' "$$c" > "config/$$f" && echo "$$f" >> $@; }; \
	done
```

Why this works: Make doesn't need to enumerate per-service outputs.
The manifest is the target; its recipe creates the files as side
effects. Pure wildcard+patsubst, no `$(shell)` at parse time, no
`-include` of generated Make fragments.

## Other Make rules

- `services/%.elp` → `config/%` (existing, keeps current pattern)
- `services/%` (non-elp) → `config/%` (existing copy)
- `targets/debian/%.elp` (no `$service`) → `config/%` (new singleton)
- `targets/debian/%` (non-elp, no `$service`) → `config/%` (new copy)
- `config/%.manifest: targets/debian/$service%.elp` (new fan-out)

Five pattern rules total. The 11 current dispatch rules collapse.

## Renderer changes

Minimal:
- Drop SYSTEMD_SERVICES / SIGHUP_SERVICES / SERVICES_WITH_CONFIG /
  DOCKERIZED_SERVICES from `--list-make`. Keep ALL_SERVICES (recipe
  needs it).
- `service.path.elp`'s file enumeration moves out of the Make
  `service_files` function and into Lisp. Either: walk the filesystem
  in the template, or expose a derived field. Filesystem walk lives
  next to the existing `service-has-config-p` in cli.lisp — promote
  to a context binding.

No `$service` substitution logic needed in the renderer itself —
Make does the substitution before calling. Renderer just gets a
fully-resolved path and `--service NAME`.

## Templates

Each fan-out template gets a `(when ...)` outer guard. The filter
that used to live in `--list-make`:

| Template | Predicate |
|---|---|
| `$service.service.elp` | dockerized && !has-unit |
| `$service.path.elp` | service has config files (filesystem walk) |
| `$service-compose.path.elp` | dockerized && !has-unit |
| `$service-compose-reload.service.elp` | dockerized && !has-unit |
| `$service-reload.service.elp` | sighup-reload field |
| `$service/docker-compose.yml.elp` | dockerized |

Wrap the existing template body in `<%- (when <pred> -%> ... <%- ) -%>`.

## Verify

```
make clean
make all
cd test && make all
git diff --exit-code test/config/    # must be clean
```

## Skipped / future

- **Stale-file deletion in `make clean`** — manifests enable it
  (anything in `config/` not in any manifest = delete). Edge cases
  (missing manifest, hand-edited config/) need thought. Separate work.
- **`--target` flag** — only one target exists today (debian).
  Hardcode `targets/debian/` as the source root for now. Add the flag
  when nixos lands (`plans/nixos-target.md` Phase B).

## Naming note

`TARGET` in the Makefile (from `plans/remote-deploy.md`) selects the
deploy host (local vs fatlaptop). The "target" here is the render
target (debian vs nixos). Same word, different axis. `nixos-target.md`
already overloads it the same way, so this isn't new.
