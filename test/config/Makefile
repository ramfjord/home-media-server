.PHONY: chownall deploy preview

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

preview: DRY := --dry-run --itemize-changes
preview: deploy

deploy: chownall
	@rsync -ac --no-times $(DRY) --exclude=systemd "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times $(DRY) "$(STAGING)/systemd/" /etc/systemd/system/
	@[ -n "$(DRY)" ] || systemctl daemon-reload
