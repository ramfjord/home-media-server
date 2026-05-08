# Tailscale cert provisioning on the deploy host

## Goal

After this branch ships:

1. The deploy host (TARGET) runs a systemd timer that calls
   `tailscale cert` periodically and writes
   `<install_base>/certs/<tailnet-host>.{crt,key}`. Renewal is
   automatic and idempotent — `tailscale cert` only rewrites when
   needed.
2. Caddy is the single HTTPS front door for every web-UI service.
   Caddy publishes only 80 + 443 on the host; everything else is
   reached at `https://<tailnet-fqdn>/<name>` where `<name>` is the
   service's directory under `services/`. Homer is served at `/`.
   Plain HTTP on `:80` redirects to HTTPS. Host port publishing for
   each service goes away — caddy reaches them via the docker
   network (and the wireguard-namespaced *arrs via the wireguard
   container as today).
3. Caddy bind-mounts `<install_base>/certs` read-only. The cert no
   longer flows through the deploy's `config/` rsync —
   `services/caddy/certs/` (gitignored fixture on the laptop today)
   is gone. The host owns cert provisioning end-to-end.
4. The tailnet FQDN lives in the existing `hostname` field
   (per-host in `config.local.yml`), not a new global. One value,
   used by caddy + every service that advertises a self-URL.
5. `make check` validates the rendered Caddyfile.
6. A host-bootstrap section in the docs walks "fresh box →
   `make install`": install docker + systemd + tailscale, `tailscale
   up`, create the `cert-readers` group, first deploy.

## Context

Today's flow: a real cert
(`fatlaptop.hippogriff-stonecat.ts.net.{crt,key}`) sits in the
gitignored `services/caddy/certs/` on the laptop, gets rsynced into
`<install_base>/config/caddy/certs/` on TARGET via the per-service
deploy, and is bind-mounted into caddy at `/etc/caddy/certs`. The
hostname is hardcoded in `services/caddy/Caddyfile.elp:8-9`.
`globals.yml`'s `hostname:` is `localhost` and unrelated to the
tailnet hostname.

Two problems with the current setup:

- **Provenance.** The cert was issued by `tailscale cert` once,
  manually, on fatlaptop. It expires (~90 days). There is no
  automatic renewal — the next rotation is a manual step that nobody
  has documented and probably nobody will remember.
- **Wrong layer.** The cert is per-host, not per-service. Caddy
  consuming it is incidental; if homer or anything else later wants
  HTTPS, the cleanest answer is "caddy reverse-proxies it" (single
  TLS terminator), but the cert itself is still a host fact. Putting
  cert *provisioning* under `services/caddy/` couples a host-level
  resource to a service that happens to read it.

The fix: provisioning lives in `targets/debian/` (a systemd
unit+timer), the cert lives at `<install_base>/certs/` (host-level
path), caddy mounts that path read-only, and the deploy never
touches the cert files at all.

## Related plans

Skimmed all of `./plans/` on 2026-05-06.

- **`plans/per-service-chmod.md`** (one-line stub) — flags that the
  generic deploy rsync's `Dg+s,Fg+w` mode leaves cert keys
  group-writable to `mediaserver`. This plan resolves that concern
  *for certs specifically* by removing them from the deploy path
  entirely. The per-service-chmod plan is still relevant for other
  secret-shaped files; not blocked or blocking.
- **`plans/nixos-target.md`** — the NixOS equivalent is
  `services.tailscale.permitCertUid = "caddy"` plus a NixOS-native
  systemd timer. The mechanism this plan introduces is
  Debian-target-specific (lives under `targets/debian/`), which is
  exactly where it belongs given the target-dirs split. NixOS will
  re-emit the same intent in its own idiom.
- **`plans/static-uids.md`** — adds a `uids.yml` manifest. The
  `cert-readers` group introduced here would naturally live there
  once that plan ships. For now allocate it ad-hoc (or pick a fixed
  GID and document); when static-uids lands it's a one-line
  manifest entry. No coordination needed beyond that.
- **`plans/remote-deploy.md`** (shipped) — established the
  `$(REMOTE)` / `$(RSYNC_DEST)` Makefile primitives. The `make cert`
  helper added in commit 4 routes through `$(REMOTE)` the same way.
  Also flagged "certs/ rsync still runs as a single batch with
  implicit ownership" as a future concern — this plan addresses it
  by removing certs from the rsync.
- **`plans/buildarr.md`**, **`plans/lisp-render.md`**, others — no
  interaction.

## Design notes

**Per-host, not per-service.** `tailscale cert` issues per-hostname
certs that are valid for any port on that host. So one cert per
TARGET is enough, regardless of how many services want HTTPS. Caddy
fronts everything that needs TLS (today: Vaultwarden; tomorrow:
maybe Homer); other services stay plain HTTP and let caddy
terminate. This keeps the cert consumed in one place.

**Cert path: `<install_base>/certs/<host>.{crt,key}`.** Sibling of
`<install_base>/config/`, not under it. The deploy rsync targets
`<install_base>/config/`, so a sibling directory is invisible to it
— the cert is never deleted by manifest-diff, never overwritten by a
deploy. Owned entirely by the timer.

**`cert-readers` group, mode 0640 on key, 0644 on cert.** Cheap
insurance: any future container UID that needs to read the key joins
this group. Caddy in the standard `caddy:latest` image runs as root
inside the container, so it can read the key regardless of group —
the group is forward-compat for less-privileged consumers. The
systemd unit's `ExecStartPost` does the chgrp + chmod after
`tailscale cert` writes (which by default writes 0600 root:root).

**Hostname as a global.** Add `tailnet_hostname:` to `globals.yml`
(default empty / placeholder; real value via `config.local.yml`
override). Caddyfile and the cert systemd unit both read it. No
service should hardcode a hostname.

**Manual seed, then automatic renewal.** `tailscale cert` requires
tailscale to be up and authenticated — that's a one-time host
setup, not something the deploy can do. So the bootstrap sequence
is: install tailscale, `tailscale up`, then run the cert service
once (`make cert` or `systemctl start tailscale-cert.service`) to
seed. The timer keeps it renewed afterward. This split means
`make install` on a fresh box doesn't fail mysteriously when the
timer hasn't run yet; the operator runs `make cert` explicitly.

**Caddy reload on cert change.** The systemd service's
`ExecStartPost` checks whether the cert file changed (compare
mtimes, or just always reload — caddy's reload is cheap and
idempotent). On change, `docker exec caddy caddy reload` (or
`systemctl reload caddy.service` if caddy's unit is wired for
SIGHUP — it already has `sighup_reload: true` per
`services/caddy/service.yml:5`).

**Test fixtures stay as-is.** `test/services/fx-caddy/certs/` keeps
its dummy certs; the goldens test the *renderer*, not the deploy.
The fixture's Caddyfile path can be updated to match the new
convention (cert path comes from a global) but otherwise the test
tree is independent of host provisioning.

## Commits

Estimated total: ~150–250 LoC across ~6–8 files. Mostly YAML +
small systemd units + a Makefile target + docs.

1. ✅ **Templatize Caddyfile hostname via existing `hostname` global.**
   Replace the hardcoded `fatlaptop.hippogriff-stonecat.ts.net` in
   `services/caddy/Caddyfile.elp` with `<%= hostname %>` (site
   address + cert filenames). Repurpose the existing `hostname`
   field — used today by jellyfin's `PublishedServerUrl`,
   prometheus's `--web.external-url`, and homer's card URLs — to
   carry the tailnet FQDN. Update `config.local.yml.example` so
   users know to set the FQDN.
   *Verify:* `make all` clean; rendered `config/caddy/Caddyfile`
   byte-identical to today; `make test` passes; `make install`
   deploys without behavior change.
   **Decisions:**
   - Reuse `hostname`, don't add a second key. Drafted plan
     proposed a new `tailnet_hostname` global; user pushed back
     that `hostname` (already in `globals.yml`, already used by
     jellyfin/prometheus/homer for service URLs) is the same
     concept. One field is cleaner.
   - **Side effect surfaced and accepted:** with `hostname` set
     to the FQDN, jellyfin's PublishedServerUrl, prometheus's
     external URL, and homer's card URLs all become tailnet-FQDN.
     LAN-only devices without tailscale/MagicDNS would no longer
     resolve them. Acceptable on this single-host setup where
     tailscale is the access path; aligns with wanting Homer
     cards to point at HTTPS-capable URLs anyway.
   - `globals.yml` left untouched (`hostname: localhost` default
     stays). Per-host FQDN belongs in `config.local.yml`; user
     does not want new keys in `globals.yml`.
   - Fixture (`test/services/fx-caddy/`) untouched — its
     `Caddyfile.elp` doesn't include the Vaultwarden block.
     `make test` passed without golden refresh.
   - Rendered Caddyfile is byte-identical to pre-change output
     (verified by diff against main checkout's
     `config/caddy/Caddyfile`).
   - Throughout this plan, "tailnet_hostname" in subsequent
     commits' text refers to the same `hostname` field — no new
     global will be introduced.

2. ✅ **Add Caddyfile validation to `make check`.** New
   `checks/caddy.sh.elp` rendering to a script that runs
   `docker run --rm -v $PWD/config/caddy:/etc/caddy:ro caddy:latest
   caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile`.
   Use `caddy adapt` (not `caddy validate --config ...`) so the
   check parses the Caddyfile without trying to load runtime
   resources like cert files — the cert may not exist on the dev
   box. Pattern follows the existing `checks/{prometheus,
   alertmanager,otelcol}.sh.elp` shape. Picks up automatically
   via the Makefile's `check:` rule (`$(wildcard checks/*.sh.elp)`).
   *Verify:* `make check` runs the new step and exits 0 against
   commit 1's rendered Caddyfile; intentionally break the
   Caddyfile (e.g. unmatched brace) → `make check` fails with a
   readable parse error; restore.
   **Decisions:**
   - `caddy adapt` chosen over `caddy validate --config` —
     validate triggers TLS-app provisioning which tries to open
     the cert file; that file isn't present in CI/dev contexts
     (and won't be at all post-commit-7 until the timer runs).
     adapt is parse-only and catches structural Caddyfile errors.
   - Stdout discarded with `> /dev/null` — caddy adapt prints
     the JSON-converted config on success which is noisy. Errors
     still surface via stderr + non-zero exit; `set -euo pipefail`
     preserves the failure mode.
   - Pre-existing caddy-side warnings ("Unnecessary header_up
     X-Forwarded-For", "Caddyfile input is not formatted") are
     non-fatal stderr warnings and don't fail the check. Worth
     a follow-up `caddy fmt`/header cleanup, but out of scope
     here.
   - Negative test: appended `GARBAGE_TOKEN_NOT_VALID }` to a
     rendered Caddyfile, `make check/caddy` failed with `Error:
     subject does not qualify for certificate: '}'` and `make:
     *** [Makefile:104: check/caddy] Error 1`. After re-render,
     check passes.

3. ✅ **Path-routing: monitoring stack on subpaths (cadvisor deferred).**
   Switch prometheus, alertmanager, grafana, blackbox-exporter
   from host-port-publishing to caddy subpath routing under
   `https://<%= hostname %>` (no explicit port — caddy listens on
   443). Cadvisor deferred: its `--url_base_prefix` moves
   `/metrics` to `/cadvisor/metrics`, which requires extending
   `services/otelcol/otelcol-config.yaml.elp` to honor a
   `:metrics_path` field in `scrape_target`. Pulling that into a
   later commit keeps this one focused. Per-service changes:
   - **Caddyfile.elp** — replace the existing structure with a
     single `https://<%= hostname %>` site block containing
     `handle_path /<name>/* { reverse_proxy <name>:<port> }` per
     service (path matches the `services/<name>/` directory). Add
     an `http://<%= hostname %>` block that redirects to https.
     Strip the path prefix on the way upstream when the app reads
     `--web.route-prefix`; preserve it when the app expects to see
     its own external URL.
   - **caddy ports** — replace the per-service published ports
     (`8080`, `7878`, `8989`, `9696`, `8000`) with just `80:80`
     and `443:443`.
   - **prometheus** — already has `--web.external-url=http://<%= hostname %>:9090/`;
     change to `https://<%= hostname %>/prometheus` and add
     `--web.route-prefix=/prometheus`.
   - **grafana** — add `GF_SERVER_ROOT_URL=https://<%= hostname %>/grafana`
     and `GF_SERVER_SERVE_FROM_SUB_PATH=true`.
   - **alertmanager** — add `--web.external-url=https://<%= hostname %>/alertmanager`
     and `--route-prefix=/alertmanager`.
   - **cadvisor** — add `--url_base_prefix=/cadvisor`.
   - **blackbox-exporter** — add `--web.external-url=...` and
     `--web.route-prefix=/blackbox`.
   - Drop `ports:` from each `docker_config` (no host publishing
     once caddy fronts them). Container ports stay reachable on
     the docker network for caddy.
   *Verify:* `make all` clean; `make check` passes (caddy + each
   app's compose validate); the rendered docker-compose for each
   shows the new env/args and no host port; goldens refreshed if
   any fixture exercises these.
   **Decisions:**
   - **`handle` not `handle_path`.** Each app's `--web.route-prefix`
     (or grafana's `serve_from_sub_path`) wants to *see* the prefix
     in the upstream request — preserving it is the correct
     pattern. `handle_path` would strip and would force every app
     to think it's at `/`, which would then re-emit links without
     prefix and break the chain.
   - **Cadvisor deferred** (see commit body). Untouched here;
     still on host port 8081 until a follow-up commit extends
     otelcol's scrape template to support `:metrics_path`.
   - **Existing caddy ports kept, new ones added.** Caddy now
     publishes 80/443 (for the unified site) *and* the legacy
     7878/8989/9696/8080/8000. Pruning the legacy ports happens
     in commits 4 (VPN-arr per-port blocks) and 5 (vault on
     :8000). Doing it incrementally lets each commit's deploy
     stay testable.
   - **No `http://<%= hostname %>` redirect block needed.** Caddy
     auto-issues an HTTP→HTTPS redirect for any site declared
     with a hostname; no explicit `:80` block required. Once
     port 80 is published (this commit), the redirect kicks in
     for free.
   - **prometheus alerting** updated to `path_prefix:
     /alertmanager` so prometheus pushes alerts to the prefixed
     alertmanager endpoint.
   - **`scrape_target: true` for these services unchanged.**
     otelcol scrapes them via docker DNS at the in-container
     port (`prometheus:9090`, etc.) — independent of caddy's
     host-port publishing. Path-routing changes don't affect
     scraping.

4. ✅ **Lift `:displayable` to derived field; loop in Caddyfile;
   cover every UI service.** Single commit collapsing the
   originally-planned commits 4–6. Adds `:displayable` to
   `lisp/src/derive.lisp` (named after the homer macrolet
   predicate). Caddyfile.elp is rewritten as a `loop-services
   (service-where displayable)` emitting `handle /<name>/* {
   reverse_proxy <upstream>:<port> }` per service, where upstream
   is `wireguard` for `use_vpn` services else `<name>`. Homer at
   `/` via a trailing `handle { reverse_proxy homer:8080 }`.
   Per-app URLBase / external-URL settings for each newly-routed
   service: *arrs (`<APP>__SERVER__URLBASE`), jellyfin
   (`JELLYFIN_BaseUrl` + updated `PublishedServerUrl`),
   vaultwarden (`DOMAIN` derived directly from `<%= hostname %>`,
   replacing the old `for-service :vaultwarden public_url`
   indirection), cadvisor (`--url_base_prefix=/cadvisor`).
   Otelcol scrape template (`services/otelcol/otelcol-config.yaml.elp`)
   extended to honor `:metrics_path` in `scrape_target`; cadvisor
   declares `metrics_path: /cadvisor/metrics` to match its prefix.
   Homer card URLs become `https://<%= hostname %>/<%= name %>`
   (was `http://hostname:port`); `public_url` removed from
   vaultwarden's `config.local.yml.example` block. Caddy's `ports:`
   pruned to just `80:80` and `443:443`; cadvisor and homer drop
   their `ports:` mappings (auto-publish would have re-published
   them otherwise). Auto-publish branch in
   `targets/debian/__service__/docker-compose.yml.elp` removed
   (caddy is the sole host-facing service); the corresponding
   port-uniqueness validator in `lisp/src/config.lisp` removed
   along with it. Homer's `port:` corrected from 80 (host-side
   wart) to 8080 (container port).
   *Verify:* `make all` clean; `make check` clean (caddy adapt +
   compose + prometheus + alertmanager); `make test` clean after
   refreshing the fx-prometheus golden (auto-publish removal
   strips the `ports: - 19090:19090` line).

5. ✅ **Render `tailscale-cert.{service,timer}` under `targets/debian/`.**
   New `targets/debian/systemd/tailscale-cert.service.elp` and
   `tailscale-cert.timer.elp` (singletons, no `__service__`
   placeholder). Service runs `tailscale cert --cert-file=...
   --key-file=... <%= hostname %>` writing to
   `<%= install_base %>/certs/`, then chgrps to `cert-readers` and
   chmods 0644/0640. `ExecStartPost` reloads caddy
   (`systemctl reload caddy.service`). Timer fires daily +
   `OnBootSec=5min`. Renders and ships via the existing
   systemd-unit rsync, but is not yet enabled by default. Caddy
   still mounts the old path; this commit only adds the
   *capability*.
   *Verify:* `make all` clean; `make check` includes
   `systemd-analyze verify` for the new units (already pattern-
   driven via `checks/systemd.sh.elp`); `make install` ships the
   units; manual `systemctl start tailscale-cert.service` on
   TARGET creates `<install_base>/certs/<host>.{crt,key}` with
   correct perms.
   **Decisions:**
   - **Singleton in `targets/debian/systemd/`** rather than a
     new `services/caddy-cert-renew/` service. Investigation
     showed the `:has_unit` derived-field path is detected but
     no template currently emits a `unit:` field — wiring it up
     is real work that doesn't help cert provisioning. Singleton
     fits the existing pattern (mediaserver-network.service,
     mediaserver.target.elp live there too).
   - **`cert-readers` group dropped** entirely. Caddy is the
     only consumer (and will be forever per user). Cert files
     are owned `caddy:caddy`, key 0640, cert 0644.
   - **Renewer runs as root.** Simpler than running as caddy
     user, which would require host-side
     `tailscale set --operator=caddy` config. ExecStartPost
     chowns to caddy user.
   - **Caddy reload is best-effort** (`-` prefix on the
     ExecStartPost). If caddy isn't running yet (first boot,
     before bootstrap completes), the renewal still succeeds.
   - **Timer: OnBootSec=5min + OnUnitActiveSec=1d**, with
     `Persistent=true` so missed runs (host off) trigger when
     next online. `tailscale cert` is idempotent — daily fires
     are cheap when fresh.
   - **Systemd check extended** to also validate `*.timer`
     files. Was previously `*.service *.path` only.
   - **Caddy reload via `docker exec caddy caddy reload`**
     rather than `systemctl reload caddy.service`. The
     containerized caddy reload is direct + idiomatic; doesn't
     depend on whatever the auto-generated reload unit's
     mechanics are.

6. ✅ **Add `cap_add: NET_BIND_SERVICE` so caddy can bind 80/443
   as non-root.** The docker-compose template auto-injects
   `user: ${SVC_UID}:${SVC_GID}` for every dockerized service.
   With path-routing now requiring caddy to bind privileged ports,
   the bind would fail without the capability. caddy:latest sets
   file caps on its binary, so cap_add is sufficient (no
   `sysctls: net.ipv4.ip_unprivileged_port_start=0` needed).
   *Verify:* `make all` clean; rendered `config/caddy/docker-compose.yml`
   shows the `cap_add: - NET_BIND_SERVICE` block; `make check`
   clean; goldens unchanged.

7. ✅ **Switch caddy to mount `<install_base>/certs`; drop the
   per-service cert rsync.** Update `services/caddy/service.yml`
   volume from `<%= install_base %>/config/caddy/certs:/etc/caddy/certs:ro`
   to `<%= install_base %>/certs:/certs:ro`. Update Caddyfile
   cert paths to `/certs/<%= hostname %>.{crt,key}`. Remove
   `services/caddy/certs/` from the laptop working tree (drop
   the gitignore entry) and from the deploy. **Bootstrap
   prerequisite:** the operator must have run the new cert
   service once (commit 5's manual verify) so the cert exists at
   the new path before caddy restarts.
   *Verify:* `make all` + `make check` clean; `make test`
   passes; `docker exec caddy ls /certs` (post-deploy) shows
   the tailnet-hostname files; HTTPS still works for every
   subpath-routed service.

8. **Add `make cert` target + bootstrap docs.** New phony target
   in the root Makefile: `cert: ; $(REMOTE) sudo systemctl start
   tailscale-cert.service` (one-shot manual seed/renewal). Enable
   the timer by default in `systemd-enable` so a fresh box gets
   renewal automatically once the cert has been seeded. Document
   the host-bootstrap sequence in `docs/installation.md` (or new
   `docs/host-bootstrap.md`): install docker + systemd +
   tailscale on the target, `tailscale up`, `make install`,
   `make cert`, `systemctl enable --now tailscale-cert.timer`.
   Also document the new "everything-through-caddy" URL scheme
   in README.md (services table needs a refresh — host ports
   become subpaths).
   *Verify:* `make cert` round-trips to TARGET, the unit fires,
   cert file mtime updates; bootstrap sequence reads coherently
   end-to-end.

## Future plans

- **NixOS-native equivalent** — when `plans/nixos-target.md` lands,
  emit `services.tailscale.permitCertUid` + a NixOS systemd timer
  from the same `hostname` global. The Debian-target units
  introduced here are throwaway under NixOS (separate plan, separate
  branch).
- **Multi-target / multi-host** — if a second TARGET ever appears,
  the FQDN becomes per-host config rather than a single global.
  Tied to `plans/nixos-target.md` Phase D's `host.yml` introduction;
  no work needed before then.

## Non-goals

- **Not generating the cert from the laptop.** Provisioning runs on
  TARGET, where tailscale is already authenticated. The renderer
  stays pure (manifest in, text out); no shelling out to
  `tailscale` from the build.
- **Not putting tailscale in a container.** Adds an auth-key flow
  for no win when the host already has tailscale running.
- **Not solving cert-perms for arbitrary future consumers.** The
  `cert-readers` group is the hook; actual usage by non-caddy
  consumers happens whenever such a consumer shows up.
