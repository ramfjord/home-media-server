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

SERVICE_YAMLS := $(wildcard services/*/service.yml)
RENDER_DEPS := $(RENDER_BIN) globals.yml $(wildcard config.local.yml)

# ELP source → target mapping:
#   services/<svc>/<path>.elp  →  config/<svc>/<path>
#   <aggregator>.elp           →  config/<aggregator>
SERVICE_ELPS := $(shell find services -name '*.elp' 2>/dev/null)
TOP_ELPS     := $(wildcard *.elp)
ELPS := $(patsubst services/%.elp,config/%,$(SERVICE_ELPS)) \
        $(patsubst %.elp,config/%,$(TOP_ELPS))

# Cached service lists. Regenerated when any service.yml or globals.yml changes.
.make.services: $(SERVICE_YAMLS) globals.yml $(wildcard config.local.yml) $(RENDER_BIN)
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

test:
	ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].reject { |f| f == "test/golden_test.rb" }.each { |f| require "./#{f}" }'
	ruby test/golden_test.rb

# Lisp render binary. Slow first build (~5s); ~100ms per invocation after.
render-bin: $(RENDER_BIN)
$(RENDER_BIN): $(LISP_SRCS) $(REPO_ROOT)/script/build-render.sh
	$(REPO_ROOT)/script/build-render.sh

all: $(ELPS) $(NON_TPL_TARGETS) $(COMPOSE_TARGETS) $(SYSTEMD_UNITS)

clean:
	rm -rf config/ .make.services

users:
	script/make_users.sh

config:
	mkdir config
	chown $(USER):mediaserver config

# --- Aggregator ELPs: depend on every service.yml (full iteration at render time). ---
# Explicit rules take precedence over the implicit pattern rule below.
AGGREGATOR_RULE = mkdir -p $(dir $@); $(RENDER_BIN) --root . $< > $@

config/caddy/Caddyfile: services/caddy/Caddyfile.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/homer/config.yml: services/homer/config.yml.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/otelcol/otelcol-config.yaml: services/otelcol/otelcol-config.yaml.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/prometheus/rules/mediaserver.yaml: services/prometheus/rules/mediaserver.yaml.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/systemd/mediaserver.target: $(SYSTEMD)/mediaserver.target.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

# Top-level *.elp (e.g. deploy.sh.elp). Renders to config/<basename>.
config/%: %.elp $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

# --- Per-service ELP rendering (narrow dep). Secondary expansion picks out the owning service. ---
svc_of = $(firstword $(subst /, ,$(1)))

config/%: services/%.elp $(RENDER_DEPS) services/$$(call svc_of,$$*)/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$(call svc_of,$*) $(RENDER_BIN) --root . $< > $@

# Copy non-template files from services/<svc>/... to config/<svc>/...
config/%: services/%
	mkdir -p $(dir $@)
	cp $< $@

# Per-service docker-compose.yml (same template, different SERVICE_NAME per file).
config/%/docker-compose.yml: $(SYSTEMD)/service.compose.yml.elp $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

# Static systemd units (no rendering, just copy).
config/systemd/%.service: $(SYSTEMD)/%.service
	mkdir -p $(dir $@)
	cp $< $@

# --- Systemd unit pattern rules ---
config/systemd/%-compose-reload.service: $(SYSTEMD)/service-compose-reload.service.elp $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%-compose.path: $(SYSTEMD)/service-compose.path.elp $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%-reload.service: $(SYSTEMD)/sighup-reload.service.elp $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

config/systemd/%.service: $(SYSTEMD)/service.service.elp $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* $(RENDER_BIN) --root . $< > $@

# .path units enumerate the service's deployed files. Compute the list
# here (Make is the dispatcher); pass via SERVICE_FILES env var, which
# the .elp template walks. Excludes service.yml, .erb shadows, .elp
# extension stripped to match the deployed filename.
service_files = $(shell cd services/$(1) 2>/dev/null && find . -type f ! -name 'service.yml' ! -name '*.erb' -printf '%P\n' | sed 's/\.elp$$//' | tr '\n' ' ')
config/systemd/%.path: $(SYSTEMD)/service.path.elp $(RENDER_DEPS) services/$$*/service.yml $$(shell find services/$$* -type f 2>/dev/null)
	mkdir -p $(dir $@)
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
