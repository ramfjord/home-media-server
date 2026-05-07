.PHONY: chownall deploy deploy-files preview

STAGING := /opt/fx-mediaserver/staging
INSTALL_BASE := /opt/fx-mediaserver

chownall:
	@chown -R root:$$(id -gn root) fx-wireguard/
	@printf 'SVC_UID=%s\nSVC_GID=%s\n' "$$(id -u root)" "$$(id -g root)" > fx-wireguard/.env
	@chown -R fx-caddy:$$(id -gn fx-caddy) fx-caddy/
	@printf 'SVC_UID=%s\nSVC_GID=%s\n' "$$(id -u fx-caddy)" "$$(id -g fx-caddy)" > fx-caddy/.env
	@chown -R fx-sonarr:$$(id -gn fx-sonarr) fx-sonarr/
	@printf 'SVC_UID=%s\nSVC_GID=%s\n' "$$(id -u fx-sonarr)" "$$(id -g fx-sonarr)" > fx-sonarr/.env
	@chown -R fx-qbittorrent:$$(id -gn fx-qbittorrent) fx-qbittorrent/
	@printf 'SVC_UID=%s\nSVC_GID=%s\n' "$$(id -u fx-qbittorrent)" "$$(id -g fx-qbittorrent)" > fx-qbittorrent/.env
	@chown -R fx-prometheus:$$(id -gn fx-prometheus) fx-prometheus/
	@printf 'SVC_UID=%s\nSVC_GID=%s\n' "$$(id -u fx-prometheus)" "$$(id -g fx-prometheus)" > fx-prometheus/.env

# First deploy ever — baseline doesn't exist. Materialize an empty file so
# the diff below sees nothing-to-remove. The next rsync overwrites it with
# the real manifest, so this rule fires only once per host.
$(INSTALL_BASE)/config/.manifest /etc/systemd/system/.mediaserver.manifest:
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

config.manifest.removed systemd.manifest.removed:
	@grep -Fxv -f $< $(word 2,$^) | sed 's|^|$(dir $(word 2,$^))|' > $@

preview: chownall config.manifest.removed systemd.manifest.removed
	@rsync -ac --no-times --inplace --dry-run --itemize-changes --exclude=systemd --exclude='*.manifest.removed' "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times --dry-run --itemize-changes "$(STAGING)/systemd/" /etc/systemd/system/
	@echo "=== files that would be removed from $(INSTALL_BASE)/config/ ==="
	@cat config.manifest.removed
	@echo "=== unit files that would be removed from /etc/systemd/system/ ==="
	@cat systemd.manifest.removed

deploy-files: chownall config.manifest.removed systemd.manifest.removed
	@rsync -ac --no-times --inplace --exclude=systemd --exclude='*.manifest.removed' "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times "$(STAGING)/systemd/" /etc/systemd/system/
	@xargs -r rm -f < config.manifest.removed
	@xargs -r rm -f < systemd.manifest.removed
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
