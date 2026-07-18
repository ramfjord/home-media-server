.PHONY: chownall deploy deploy-files preview

STAGING := /opt/fx-mediaserver/staging
INSTALL_BASE := /opt/fx-mediaserver

chownall:
	@chown -R root:$$(id -gn root) fx-wireguard/
	@printf 'SVC_UID=%s\nSVC_GID=%s\nSVC_PUID=%s\n' "$$(id -u root)" "$$(id -g root)" "$$(id -u root 2>/dev/null || echo root)" > fx-wireguard/.env
	@chown -R fx-caddy:$$(id -gn fx-caddy) fx-caddy/
	@printf 'SVC_UID=%s\nSVC_GID=%s\nSVC_PUID=%s\n' "$$(id -u fx-caddy)" "$$(id -g fx-caddy)" "$$(id -u fx-caddy 2>/dev/null || echo fx-caddy)" > fx-caddy/.env
	@chown -R fx-sonarr:$$(id -gn fx-sonarr) fx-sonarr/
	@printf 'SVC_UID=%s\nSVC_GID=%s\nSVC_PUID=%s\n' "$$(id -u fx-sonarr)" "$$(id -g fx-sonarr)" "$$(id -u fx-sonarr 2>/dev/null || echo fx-sonarr)" > fx-sonarr/.env
	@chown -R fx-qbittorrent:$$(id -gn fx-qbittorrent) fx-qbittorrent/
	@printf 'SVC_UID=%s\nSVC_GID=%s\nSVC_PUID=%s\n' "$$(id -u fx-qbittorrent)" "$$(id -g fx-qbittorrent)" "$$(id -u fx-qbittorrent 2>/dev/null || echo fx-qbittorrent)" > fx-qbittorrent/.env
	@chown -R fx-prometheus:$$(id -gn fx-prometheus) fx-prometheus/
	@printf 'SVC_UID=%s\nSVC_GID=%s\nSVC_PUID=%s\n' "$$(id -u fx-prometheus)" "$$(id -g fx-prometheus)" "$$(id -u fx-prometheus 2>/dev/null || echo fx-prometheus)" > fx-prometheus/.env

# First deploy ever — baseline doesn't exist. Materialize an empty file so
# the diff below sees nothing-to-remove. The next rsync overwrites it with
# the real manifest, so this rule fires only once per host.
$(INSTALL_BASE)/config/.manifest /etc/systemd/system/.mediaserver.manifest /etc/.mediaserver.manifest:
	@mkdir -p $(@D) && : > $@

# <name>.manifest.removed = files present in the previous deploy's manifest
# but NOT in the freshly-shipped one — i.e. what this deploy will delete.
# Recipe is shared between both targets via Make's automatic variables:
#   $<            — first prereq (the new, freshly-shipped manifest)
#   $(word 2,$^)  — second prereq (the baseline, from the previous deploy)
#   $(dir ...)    — directory part with trailing slash; the baseline lives
#                   at the destination root, so this gives us the path
#                   prefix to prepend to each removed entry.
# grep -Fxv -f new old: from `old`, drop any line that exactly (-x) matches
# (-F fixed-string) a line in (-f) `new`.
config.manifest.removed:  .manifest                      $(INSTALL_BASE)/config/.manifest
systemd.manifest.removed: systemd/.mediaserver.manifest  /etc/systemd/system/.mediaserver.manifest
etc.manifest.removed:     etc/.manifest                  /etc/.mediaserver.manifest

config.manifest.removed systemd.manifest.removed etc.manifest.removed:
	@grep -Fxv -f $< $(word 2,$^) | sed 's|^|$(dir $(word 2,$^))|' > $@

# --inplace on the config-side rsync is load-bearing for path-unit dispatch.
# Default rsync writes a temp file, fsync's, then renames over the destination
# — which generates inotify MOVED_TO on the watched path, NOT CLOSE_WRITE,
# which is what `PathChanged=` watches. --inplace writes directly to the
# destination, generating the CLOSE_WRITE event the path units expect.
# Trade: not atomic — a concurrent reader catching mid-write sees partial
# content. For our flow that's fine: docker containers don't re-read config
# until restart, and the path unit fires on CLOSE_WRITE (post-write).
#
# The systemd-side rsync stays default (atomic rename) — `daemon-reload` at
# the end picks up unit-file changes regardless of inotify semantics.
preview: chownall config.manifest.removed systemd.manifest.removed etc.manifest.removed
	@rsync -ac --no-times --inplace --dry-run --itemize-changes --exclude=systemd --exclude=etc --exclude='*.manifest.removed' "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times --dry-run --itemize-changes "$(STAGING)/systemd/" /etc/systemd/system/
	@for f in $(ETC_FILES); do cmp -s "$(STAGING)$$f" "$$f" 2>/dev/null || echo "$$f differs"; done
	@echo "=== files that would be removed from $(INSTALL_BASE)/config/ ==="
	@cat config.manifest.removed
	@echo "=== unit files that would be removed from /etc/systemd/system/ ==="
	@cat systemd.manifest.removed
	@echo "=== /etc/ files that would be removed ==="
	@cat etc.manifest.removed

# /etc/ files get one explicit rule per file, with `cmp -s` gating both
# the file copy and the reload side-effect. Make fires the recipe on every
# install (since staging mtime advances each render), but `cmp` short-
# circuits to a no-op when bytes are identical. Adding a new /etc/ file
# means adding a rule here — that's the intent: every /etc/ entry needs
# a deliberate decision about what reload it triggers.
ETC_FILES := /etc/docker/daemon.json

/etc/docker/daemon.json: $(STAGING)/etc/docker/daemon.json
	@cmp -s $< $@ 2>/dev/null || { \
	  echo "==> $@ changed, restarting docker + recreating containers"; \
	  install -m 0644 -o root -g root $< $@; \
	  systemctl restart docker; \
	  docker compose -f /opt/fx-mediaserver/config/fx-wireguard/docker-compose.yml up -d --force-recreate fx-wireguard; \
	  docker compose -f /opt/fx-mediaserver/config/fx-caddy/docker-compose.yml up -d --force-recreate fx-caddy; \
	  docker compose -f /opt/fx-mediaserver/config/fx-sonarr/docker-compose.yml up -d --force-recreate fx-sonarr; \
	  docker compose -f /opt/fx-mediaserver/config/fx-qbittorrent/docker-compose.yml up -d --force-recreate fx-qbittorrent; \
	  docker compose -f /opt/fx-mediaserver/config/fx-prometheus/docker-compose.yml up -d --force-recreate fx-prometheus; \
	  true; \
	}

deploy-files: chownall config.manifest.removed systemd.manifest.removed etc.manifest.removed $(ETC_FILES)
	@rsync -ac --no-times --inplace --exclude=systemd --exclude=etc --exclude='*.manifest.removed' "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times "$(STAGING)/systemd/" /etc/systemd/system/
	@xargs -r rm -f < config.manifest.removed
	@xargs -r rm -f < systemd.manifest.removed
	@xargs -r rm -f < etc.manifest.removed
	@systemctl daemon-reload

# Real file target: if the cert is on disk, this is up-to-date and
# the recipe doesn't run. If it's missing (fresh box, or operator
# rm'd it to force re-issuance), systemctl start fires
# tailscale-cert.service which writes the cert. Order-only dep on
# deploy-files (the `|`) means we run *after* the rsync+daemon-reload
# but the always-phony deploy-files doesn't propagate "always rebuild"
# semantics to the cert target — so subsequent deploys are no-ops
# here while the timer handles renewal. Fails loudly if tailscale
# isn't authenticated yet, prompting `tailscale up` + retry.
$(INSTALL_BASE)/certs/fx-host.crt: | deploy-files
	@echo "Bootstrapping tailscale cert for fx-host..."
	@systemctl start tailscale-cert.service

deploy: $(INSTALL_BASE)/certs/fx-host.crt
