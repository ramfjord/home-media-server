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

**Single-consumer optional fields:** when a field is declared by some services but not all, AND is read by only one template, keep it local to that consumer rather than adding a default in `lisp/src/derive.lisp` (promote to a derive default only when a second consumer appears). Either access form works, uniformly, in `for-service` / `service-where` / `loop-services` *and* per-service fanout templates — `with-service-scope` binds both the field symbols and `service` (the raw plist):

- `(getf service :field_name)` — returns nil cleanly where a service doesn't declare the field, and keeps the field out of `*known-fields*`-driven hover for unrelated services. The locality-preserving choice; `targets/debian/systemd/__service__.path.elp` reading `path_exclude` is the canonical example.
- bare symbol (`<%= field_name %>`) — also works, because the declaring service(s) put the key in `*known-fields*` so `with-service-scope` binds it for every service (value where declared, nil where not). `services/caddy/Caddyfile.elp` reading `proxy_preserve_host` is the canonical example. A bare symbol only errors *unbound* when **no** service declares the field anywhere — i.e. a typo, not the "service doesn't have it" case.

(`service` is bound uniformly across all scope macros — historically it was reachable only in fanout templates, making `(getf service …)` a silent nil inside `loop-services`; `with-service-scope` now binds it everywhere, so that trap is gone.)

**Required fields (including secrets) — do the opposite, on purpose.** When a field is *required* for the service to function (typically a secret living in git-ignored `config.local.yml` under `service_overrides.<name>`: smtp's `relay_password`, authelia's `jwt_secret`/`session_secret`/`storage_encryption_key`/`user_*`), read it via bare-symbol / `for-service` access — **not** `getf`. `make all` then fails the render fast whenever `config.local.yml` is incomplete: field-scope access (both the bare-symbol `<%= jwt_secret %>` and the `for-service` form `<%= (for-service :authelia jwt_secret) %>` — `for-service` binds fields as bare symbols too) signals `unbound variable <KEY>` with the offending template's `file:line`. (The `Unknown field :<key>` typo-guard is a *different*, narrower path — the explicit `(field :key svc)` accessor — not what these idioms use; in practice no required secret reaches the missing case because it's always supplied.) Either way it's a hard render failure naming the missing key, giving one uniform "your `config.local.yml` is incomplete" experience across every service at the same stage. Softening a required field with `getf` is a bug, not a courtesy: it renders structurally-broken config (empty secret) that passes `make all` and only fails much later at the service's own startup/validate step — worst on a security component. Rule of thumb: *required* fields (every instance must supply it) use bare-symbol / `for-service` so absence fails the render — never `getf` (with `service` now bound everywhere, `(getf service :missing)` reliably returns nil, which is exactly the silent-broken outcome you don't want for a required secret). *Optional* fields: either form, both work in all scopes (see above). See `services/authelia/` for the canonical required-secret set.

## Controller-only rendered files: `sync_exclude:`

Some rendered files belong on the controller (the machine running
`make sync`) but should never reach the deploy target — e.g.
`services/vaultwarden/passwords.csv.elp` (plaintext bootstrap creds),
`services/ollama/aider.conf.yml.elp` (aider config for the dev
container, points at `<%= hostname %>:11434`). Declare them with
`sync_exclude:` in the service's `service.yml.elp`:

```yaml
sync_exclude:
- passwords.csv
- aider.conf.yml          # any rsync-style glob also works
```

Patterns are anchored at `config/<svc>/` and feed both `make sync`'s
`--exclude-from=` AND the `.manifest` enumeration — so excluded files
are unmanaged on both sides: never shipped, and never subject to
manifest-diff deletion on the host. The list is rendered to
`config/.sync-exclude` from `targets/debian/.sync-exclude.elp`; you
don't need to touch the template to add entries.

## Per-service systemd drop-ins

The default `__service__.service.elp` template generates a `Type=simple` + `Restart=on-failure` unit suitable for long-running containers. To override directives without forking the template, set `systemd_override:` in `service.yml.elp` to a literal drop-in body — it's emitted to `<svc>.service.d/override.conf` and composed by systemd at load time. To replace an inherited `ExecStart` (a list-valued directive), reset it with an empty `ExecStart=` line before the new one. ELP tags in the body render in the manifest's **top-level scope**: globals like `<%= install_base %>` resolve, but per-service and derived fields (`compose_file`, `name`) do **not** bind there — build paths from a global plus the literal service name. See `services/api-config/service.yml.elp` for the canonical use (oneshot reconcile job, ExecStart→`compose run --rm` so the exit code propagates).

## Gating a service behind the auth gateway: `gateway_auth:`

A service opts into the single sign-on gateway by declaring
`gateway_auth:` in its `service.yml.elp`. Absent it, the service is
reached directly as before — opt-in, never automatic. Three forms:

```yaml
gateway_auth: true            # gated, any one-factor authenticated user
```

```yaml
gateway_auth:                 # gated with overrides
  policy: two_factor          # "one_factor" (default) | "two_factor"
  public_paths:               # path prefixes that bypass the gate —
  - /api                      # e.g. a machine-consumed API while the
                              # UI stays gated
```

`derive.lisp` normalizes any of these into a canonical plist on
`gateway_auth` plus a derived boolean `gateway_protected` (mirrors
`proxied`; use `(service-where gateway_protected)` to fan out over the
gated set). The field names *intent only* — which gateway enforces it
lives entirely in that gateway's config template, never in `lisp/src`,
so the engine stays stack-agnostic. Leave a service un-declared to
keep it on the direct path; **Prometheus alone** is intentionally
left un-gated so it stays reachable to debug the gateway itself.
Grafana and Alertmanager *are* gated — neither is a break-glass
surface, and un-gated they leak/permit more than they help (Grafana:
a UI, anonymous Viewer past Authelia, see `services/grafana/README.md`;
Alertmanager: silences + Discord-webhook/SMTP disclosure, see
`services/alertmanager/README.md`). Break-glass for a gateway incident
is un-gated Prometheus (`/api/v1/alerts`) + Discord (out-of-band) +
`ssh journalctl`.

## Dev REPL

`script/start-image.sh` boots an SBCL image with `:mediaserver` loaded and the manifest read, so `for-service`/`loop-services` macros work and editor LSPs can attach. See [docs/dev-environment.md](docs/dev-environment.md) for editor wiring (Emacs SLIME via `.dir-locals.el`, vim/vlime, nvim+swank-lsp, container/nix overrides).

## Native vs. dev container

You can work either natively (with the tooling listed in the root `Dockerfile` installed on your host) or inside the dev container (`script/dev` wraps `docker compose run --rm dev`; pass a command or get a bash shell). The `Makefile` and `script/build.sh` don't care which — they just call `sbcl` and `qlot`, expecting them on `PATH`. Native is faster for tight inner loops; the container is the friction-free path for anyone who'd rather not set up SBCL.

To validate the dev container end-to-end from a clean slate: `make distclean && script/dev make all`. Note the host/container glibc skew — binaries built on one usually can't run on the other; `distclean` wipes `bin/` so they get rebuilt against whichever you're using next.

`script/dev make check` works too, but on Linux you need to tell compose what gid owns the host's docker socket so the in-container user can read it. Look it up with `stat -c %g /var/run/docker.sock` and put `DOCKER_GID=<that>` in `.env` (gitignored). Docker Desktop on Windows/macOS doesn't gate the socket by Unix gid, so this is Linux-only.

## Inspecting rendered output

`config/` is git-ignored but almost always populated — `make all` (a few seconds) refreshes it without deploying. When reasoning about how a template expands, what ends up in a generated `docker-compose.yml`, prometheus config, systemd unit, etc., reading `config/<path>` directly is usually faster and more reliable than tracing the template by hand. Re-run `make all` after edits to keep it in sync, then read the rendered file to confirm the change looks right before `make install`.

## Debugging a running stack

No service is host-published except caddy (443). Monitoring services are not on `$TARGET:<port>`; they are reached through caddy over the tailnet at `https://<tailnet-fqdn>/<route-prefix>/...` from a tailnet-connected machine. Prometheus alone is un-gated by design (the gateway-debug break-glass — see services/prometheus/README.md); Grafana and Alertmanager are Authelia-gated, so for break-glass reach for Prometheus (`/api/v1/alerts` covers firing alerts), not Grafana or the Alertmanager UI. The SNI/Host must be the tailnet FQDN — that is caddy's only site block and cert. Each service keeps its route-prefix in the path, e.g.:

```sh
curl -s "https://<tailnet-fqdn>/prometheus/api/v1/query?query=up"
```

When something looks wrong, querying Prometheus this way is usually faster than ssh-ing in to read logs. From a non-tailnet machine (e.g. ssh'd onto the host itself), hit caddy with `curl -sk --resolve <fqdn>:443:127.0.0.1 https://<fqdn>/prometheus/...`, or curl the Prometheus container IP directly at `http://<ip>:9090/prometheus/...`.

## Make targets

```bash
make all               # Render all .elp templates → config/
make clean             # Remove config/
make distclean         # clean + remove bin/ and lisp/.qlot/ (full from-scratch state)
make check             # Validate prometheus, alertmanager, docker-compose syntax
make test              # api-config pytest + unit tests + golden renderer tests
make test-api-config   # just the api-config Python suite (skips if pytest absent)
make install           # check + render + rsync to $TARGET; path units pick up changes
make systemctl-enable  # enable mediaserver-network, mediaserver.target, all path units, cert timer
make systemctl-{start,stop,restart,status,disable}
make restart-<service> # force-restart one service (no install)
```

`make install` automatically runs `make check` and `make all`. With path units enabled, it's the deploy verb — file changes trigger reload automatically.

## Removing a service or template

When deploying, the host computes which files to delete by diffing a manifest shipped with this deploy against the previous deploy's manifest. The manifest is generated by `make all` from whatever's currently in `config/`.

This means **deleting a service or template requires `make clean` before `make sync`/`install`** — otherwise the stale rendered files from your last incremental build still sit in `config/`, get shipped, and remain on the host. Incremental builds are great for tight inner loops; just clean before deploying when you've removed something.
