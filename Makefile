.SECONDEXPANSION:

# Deploy target. `local` (default) keeps current behavior — rsync and
# side-effecting commands run on this host. Set TARGET=<ssh-host> to
# rsync over ssh and run side-effects on the remote host.
TARGET ?= local
-include Makefile.local
RSYNC_DEST = $(if $(filter local,$(TARGET)),,$(TARGET):)
REMOTE     = $(if $(filter local,$(TARGET)),,ssh $(TARGET))

# Anchor: directory containing this Makefile, after symlink resolution.
# When invoked via test/Makefile -> ../Makefile, this still points at
# the repo root — so bin/render and the systemd/*.elp templates resolve
# the same way regardless of cwd. cwd-relative things (services/,
# globals.yml, config.local.yml, config/) resolve to the invocation dir,
# which is what makes the same Makefile drive both production and goldens.
REPO_ROOT  := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))
RENDER_BIN := $(REPO_ROOT)/bin/render
SYSTEMD    := $(REPO_ROOT)/systemd
LISP_SRCS  := $(wildcard $(REPO_ROOT)/lisp/src/*.lisp) $(REPO_ROOT)/mediaserver.asd

# ELP source → target mapping:
#   services/<svc>/<path>.elp  →  config/<svc>/<path>
#   <aggregator>.elp           →  config/<aggregator>
SERVICE_ELPS := $(shell find services -name '*.elp' 2>/dev/null)
TOP_ELPS     := $(wildcard *.elp)
ELPS := $(patsubst services/%.elp,config/%,$(SERVICE_ELPS)) \
        $(patsubst %.elp,config/%,$(TOP_ELPS))

# Cached service lists. bin/render bakes in the merged config, so its
# mtime is the right trigger — re-running --list-make against a fresh
# binary picks up any service.yml change automatically.
.make.services: $(RENDER_BIN)
	@$(RENDER_BIN) --list-make --root . > $@

-include .make.services

# Files under services/ to copy verbatim (not templates, not service.yml,
# not legacy .erb shadows kept around for reference).
NON_TPL_CONFIGS := $(patsubst services/%,%,$(shell find services -type f ! -name '*.elp' ! -name '*.erb' ! -name 'service.yml' 2>/dev/null))
NON_TPL_TARGETS := $(addprefix config/,$(NON_TPL_CONFIGS))

# Per-service docker-compose.yml targets
COMPOSE_TARGETS := $(foreach s,$(DOCKERIZED_SERVICES),config/$(s)/docker-compose.yml)

# Systemd unit variables (derived from cached service lists above)
SYSTEMD_SERVICE_UNITS := $(addprefix config/systemd/,$(addsuffix .service,$(SYSTEMD_SERVICES)))
SYSTEMD_PATH_UNITS    := $(addprefix config/systemd/,$(addsuffix .path,$(SERVICES_WITH_CONFIG)))
SYSTEMD_COMPOSE_PATH_UNITS := $(addprefix config/systemd/,$(addsuffix -compose.path,$(SYSTEMD_SERVICES)))
SYSTEMD_COMPOSE_RELOAD_UNITS := $(addprefix config/systemd/,$(addsuffix -compose-reload.service,$(SYSTEMD_SERVICES)))
SIGHUP_RELOAD_UNITS   := $(addprefix config/systemd/,$(addsuffix -reload.service,$(SIGHUP_SERVICES)))
STATIC_SYSTEMD_UNITS := config/systemd/mediaserver-network.service
AGGREGATOR_SYSTEMD_UNITS := config/systemd/mediaserver.target
SYSTEMD_UNITS := $(STATIC_SYSTEMD_UNITS) $(AGGREGATOR_SYSTEMD_UNITS) $(SYSTEMD_SERVICE_UNITS) $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS) $(SYSTEMD_COMPOSE_RELOAD_UNITS) $(SIGHUP_RELOAD_UNITS)

.PHONY: clean check test users install install-systemd render-bin $(addprefix systemd-,start stop restart enable disable status)

test: render-bin
	ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].reject { |f| f == "test/golden_test.rb" }.each { |f| require "./#{f}" }'
	@cd test && $(MAKE) all > /dev/null
	@git diff --exit-code test/config/ > /dev/null && echo "goldens clean" || \
	  (echo "GOLDEN DIFF in test/config/. Inspect via 'git diff test/config/'."; exit 1)

# Lisp render binary. Builds in ~2s; per-call render is ~25ms because
# the merged config (services + globals + local overrides) is baked
# into the saved core, so cl-yaml load + ELP preprocessing happen once
# at build time, not per call.
#
# Deps are anchored to $(REPO_ROOT) so the binary doesn't get rebuilt
# spuriously when invoked from test/ (different cwd, different
# services/ tree). Test cwd uses the cold load-config path anyway.
render-bin: $(RENDER_BIN)
$(RENDER_BIN): $(LISP_SRCS) $(REPO_ROOT)/script/build-render.sh \
               $(wildcard $(REPO_ROOT)/services/*/service.yml) \
               $(REPO_ROOT)/globals.yml \
               $(wildcard $(REPO_ROOT)/config.local.yml)
	$(REPO_ROOT)/script/build-render.sh

all: $(ELPS) $(NON_TPL_TARGETS) $(COMPOSE_TARGETS) $(SYSTEMD_UNITS) config/list-make.txt

# Snapshot of service-list make variables. Same data as .make.services
# (the cached, gitignored copy used for Make dispatch) — checked-in
# under test/config/ for goldens so format changes are reviewable.
config/list-make.txt: $(RENDER_BIN) | $(@D)/
	$(RENDER_BIN) --list-make --root . > $@

clean:
	rm -rf config/ .make.services

users:
	script/make_users.sh

# Order-only directory creation. One mkdir per dir, never repeated;
# render rules say `| $(@D)` so Make ensures the dir exists without
# rebuilding the target on dir mtime ticks.
DIRS := $(sort $(dir $(ELPS) $(NON_TPL_TARGETS) $(COMPOSE_TARGETS) $(SYSTEMD_UNITS) config/list-make.txt))
$(DIRS):
	mkdir -p $@

# --- Render rules ---
#
# bin/render bakes the merged config (services + globals + locals) into
# its saved core, so every render output transitively depends on the
# binary — no need for per-rule SERVICE_YAMLS / globals.yml / config.local.yml
# deps. When any of those change, bin/render rebuilds (per the
# $(RENDER_BIN) rule above) and Make re-runs every render that depends
# on it.
svc_of = $(firstword $(subst /, ,$(1)))

# Per-service ELP rendering. Covers both per-service templates
# (services/qbittorrent/qBittorrent/qBittorrent.conf.elp ->
# config/qbittorrent/qBittorrent/qBittorrent.conf) and aggregators
# (services/caddy/Caddyfile.elp -> config/caddy/Caddyfile) — the
# template knows whether to iterate over `services` or use the bound
# `service`; Make doesn't.
config/%: services/%.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$(call svc_of,$*) $(RENDER_BIN) --root . $< > $@

# Top-level *.elp at repo root (e.g. deploy.sh.elp).
config/%: %.elp $(RENDER_BIN) | $$(@D)/
	$(RENDER_BIN) --root . $< > $@

# Copy non-template files from services/<svc>/... to config/<svc>/...
config/%: services/% | $$(@D)/
	cp $< $@

# Per-service docker-compose.yml: shared template, SERVICE_NAME per file.
config/%/docker-compose.yml: $(SYSTEMD)/service.compose.yml.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

# mediaserver.target is the one aggregator template that lives under
# systemd/ (not services/), so it doesn't fit the per-service pattern.
# Explicit rule for it; everything else collapses.
config/systemd/mediaserver.target: $(SYSTEMD)/mediaserver.target.elp $(RENDER_BIN) | $$(@D)/
	$(RENDER_BIN) --root . $< > $@

# Static systemd units (no rendering, just copy).
config/systemd/%.service: $(SYSTEMD)/%.service | $$(@D)/
	cp $< $@

config/systemd/%-compose-reload.service: $(SYSTEMD)/service-compose-reload.service.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%-compose.path: $(SYSTEMD)/service-compose.path.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%-reload.service: $(SYSTEMD)/sighup-reload.service.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%.service: $(SYSTEMD)/service.service.elp $(RENDER_BIN) | $$(@D)/
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

# .path units enumerate the service's deployed files. Make computes
# the list here (it's the dispatcher), passes via SERVICE_FILES env
# var, which the .elp template walks. Excludes service.yml, .erb
# shadows, .elp extension stripped to match the deployed filename.
service_files = $(shell cd services/$(1) 2>/dev/null && find . -type f ! -name 'service.yml' ! -name '*.erb' -printf '%P\n' | sed 's/\.elp$$//' | tr '\n' ' ')
config/systemd/%.path: $(SYSTEMD)/service.path.elp $(RENDER_BIN) $$(shell find services/$$* -type f 2>/dev/null) | $$(@D)/
	SERVICE_NAME=$* SERVICE_FILES="$(call service_files,$*)" $(RENDER_BIN) --root . $< > $@

check: all
	# TODO convert these to use the container versions of promtool/amtool
	promtool check config config/prometheus/prometheus.yml
	amtool check-config config/alertmanager/alertmanager.yml
	@for f in $(COMPOSE_TARGETS); do \
	  docker compose -f "$$f" config > /dev/null || (echo "FAIL: $$f" && exit 1); \
	done
	docker run --rm \
		-v $(CURDIR)/config/otelcol:/etc/otelcol \
		otel/opentelemetry-collector-contrib:latest \
		validate --config=/etc/otelcol/otelcol-config.yaml
	@for f in config/systemd/*.service config/systemd/*.path; do \
	  systemd-analyze verify "$$f" > /dev/null || (echo "FAIL: $$f" && exit 1); \
	done

SYSTEMD_DIR := /etc/systemd/system

install: check
	@for svc in $(ALL_SERVICES); do \
	  if [ -d config/$$svc ]; then \
	    rsync -av --rsync-path="sudo rsync" --mkpath --chown=$$svc:mediaserver --chmod=Dg+s config/$$svc/ $(RSYNC_DEST)/opt/mediaserver/config/$$svc/; \
	  fi; \
	done
	rsync -av --rsync-path="sudo rsync" certs/ $(RSYNC_DEST)/opt/mediaserver/certs/

PATH_UNITS := $(notdir $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS))

install-systemd: install $(SYSTEMD_UNITS)
	$(REMOTE) sudo mkdir -p $(SYSTEMD_DIR)
	rsync -av --rsync-path="sudo rsync" config/systemd/ $(RSYNC_DEST)$(SYSTEMD_DIR)/
	$(REMOTE) sudo systemctl daemon-reload

systemd-start systemd-stop systemd-restart systemd-status:
	@$(REMOTE) sudo systemctl $(patsubst systemd-%,%,$@) mediaserver.target

systemd-enable:
	$(REMOTE) sudo systemctl enable --now mediaserver-network.service
	$(REMOTE) sudo systemctl enable --force mediaserver.target
	$(REMOTE) sudo systemctl enable --now --force $(PATH_UNITS)

systemd-disable:
	$(REMOTE) sudo systemctl disable mediaserver.target
	$(REMOTE) sudo systemctl disable $(PATH_UNITS)

# Force-restart a single service. Path units already redeploy on
# `make install`; use this when you want to bounce a service without
# changing config. Combine: `make install restart-radarr`.
restart-%:
	@$(REMOTE) sudo systemctl restart $*.service
