.PHONY: chownall deploy preview

STAGING := /opt/fx-mediaserver/staging
INSTALL_BASE := /opt/fx-mediaserver

chownall:
	@chown -R root:mediaserver fx-wireguard/
	@printf 'SVC_UID=%s\n' "$$(id -u root)" > fx-wireguard/.env
	@chown -R fx-caddy:mediaserver fx-caddy/
	@printf 'SVC_UID=%s\n' "$$(id -u fx-caddy)" > fx-caddy/.env
	@chown -R fx-sonarr:mediaserver fx-sonarr/
	@printf 'SVC_UID=%s\n' "$$(id -u fx-sonarr)" > fx-sonarr/.env
	@chown -R fx-qbittorrent:mediaserver fx-qbittorrent/
	@printf 'SVC_UID=%s\n' "$$(id -u fx-qbittorrent)" > fx-qbittorrent/.env
	@chown -R fx-prometheus:mediaserver fx-prometheus/
	@printf 'SVC_UID=%s\n' "$$(id -u fx-prometheus)" > fx-prometheus/.env

preview: DRY := --dry-run --itemize-changes
preview: deploy

deploy: chownall
	@rsync -ac --no-times $(DRY) --exclude=systemd "$(STAGING)/" "$(INSTALL_BASE)/config/"
	@rsync -ac --no-times $(DRY) "$(STAGING)/systemd/" /etc/systemd/system/
	@[ -n "$(DRY)" ] || systemctl daemon-reload
