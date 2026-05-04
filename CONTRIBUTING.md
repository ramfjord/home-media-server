# Contributing

Conventions for editing this repo. Pairs with [README.md](README.md), which covers what the project is and how to deploy it.

## Predicate naming

Boolean-returning Lisp helpers in this project use a Ruby-style `?` suffix (`displayable?`, `dockerized?`) rather than CL's standard `-p`/`p` (`displayable-p`, `dockerizedp`). `?` is a valid CL symbol character with no reader significance, so it works everywhere — the choice is for readability.

## ELP template style

Stack adjacent close-paren-only tags onto a single tag, Lisp-style: prefer `<%- )) -%>` over two consecutive `<%- ) -%>` lines (and `))) ` for three, etc.). The trim semantics are the same and the rendered output is byte-identical, but it reads as the Lisp form it actually is rather than as HTML-like standalone tags.

## Field access in templates

Templates render with every service field bound as a bare symbol (`name`, `port`, `use_vpn`, `compose_file`, ...). Hyphens in field keys become underscores, matching Ruby convention. Inside per-service templates and inside `loop-services`, write `<%= name %>` rather than `(field :name service)`.

For higher-order use, `field` is curried: `(field :name)` returns a lookup function — `(mapcar (field :name) services)` and `(remove-if-not (field :dockerized) services)`. The two-arg form `(field :key svc)` is the explicit lookup; key always comes first.

Three template-scope macros, each expanding through the primitive `with-service-scope`:

- `(loop-services SOURCE ...)` iterates a list of service plists, exposing each service's fields as bare symbols inside the body. Pass `services` to iterate everything, or build a filtered list with `service-where`.
- `(service-where PRED)` evaluates PRED in field-scope per service, returns the matching subset as a list. Compose with plain CL: `(service-where (and dockerized port))`. Common pairing: `(loop-services (service-where ...) ...)`.
- `(for-service :name ...)` resolves `:name` against `services`, then binds fields for the body. The file-top wrap for per-service `.elp` templates: write it once at the top and the rest of the file can use `<%= name %>`, `<%= group %>`, etc.

For predicates reused across several call sites in one template, use `macrolet` at the top of the template to define a named field-scope macro — see `services/homer/config.yml.elp` for an example. New service fields are picked up automatically from any key appearing in service yaml; no per-field declaration step today.

## Dev REPL

`script/start-image.sh` boots an SBCL image with `:mediaserver` loaded and the manifest read, so `for-service`/`loop-services` macros work and editor LSPs can attach. See [docs/dev-environment.md](docs/dev-environment.md) for editor wiring (Emacs SLIME via `.dir-locals.el`, vim/vlime, nvim+swank-lsp, container/nix overrides).

## Native vs. dev container

You can work either natively (with the tooling listed in the root `Dockerfile` installed on your host) or inside the dev container (`script/dev` wraps `docker compose run --rm dev`; pass a command or get a bash shell). The `Makefile` and `script/build.sh` don't care which — they just call `sbcl` and `qlot`, expecting them on `PATH`. Native is faster for tight inner loops; the container is the friction-free path for anyone who'd rather not set up SBCL.

To validate the dev container end-to-end from a clean slate: `make distclean && script/dev make all`. Note the host/container glibc skew — binaries built on one usually can't run on the other; `distclean` wipes `bin/` so they get rebuilt against whichever you're using next.

`script/dev make check` works too, but on Linux you need to tell compose what gid owns the host's docker socket so the in-container user can read it. Look it up with `stat -c %g /var/run/docker.sock` and put `DOCKER_GID=<that>` in `.env` (gitignored). Docker Desktop on Windows/macOS doesn't gate the socket by Unix gid, so this is Linux-only.

## Inspecting rendered output

`config/` is git-ignored but almost always populated — `make all` (a few seconds) refreshes it without deploying. When reasoning about how a template expands, what ends up in a generated `docker-compose.yml`, prometheus config, systemd unit, etc., reading `config/<path>` directly is usually faster and more reliable than tracing the template by hand. Re-run `make all` after edits to keep it in sync, then read the rendered file to confirm the change looks right before `make install`.

## Debugging a running stack

Prometheus runs on the deploy host (the `TARGET`) and is reachable directly over the tailnet — `curl http://$TARGET:9090/api/v1/query?query=...` from any tailnet-connected machine, no port-forwarding needed. Same goes for the other monitoring services on their documented ports. When something looks wrong, querying prometheus directly is usually faster than ssh-ing in to read logs.

## Make targets

```bash
make all               # Render all .elp templates → config/
make clean             # Remove config/
make distclean         # clean + remove bin/ and lisp/.qlot/ (full from-scratch state)
make check             # Validate prometheus, alertmanager, docker-compose syntax
make test              # Run unit tests + golden renderer tests
make install           # check + render + rsync to $TARGET; path units pick up changes
make install-systemd   # rsync unit files + daemon-reload (does NOT enable/start)
make systemd-enable    # enable mediaserver-network, mediaserver.target, and all path units
make systemd-{start,stop,restart,status,disable}
make restart-<service> # force-restart one service (no install)
```

`make install` automatically runs `make check` and `make all`. With path units enabled, it's the deploy verb — file changes trigger reload automatically.

## Removing a service or template

When deploying, the host computes which files to delete by diffing a manifest shipped with this deploy against the previous deploy's manifest. The manifest is generated by `make all` from whatever's currently in `config/`.

This means **deleting a service or template requires `make clean` before `make sync`/`install`** — otherwise the stale rendered files from your last incremental build still sit in `config/`, get shipped, and remain on the host. Incremental builds are great for tight inner loops; just clean before deploying when you've removed something.
