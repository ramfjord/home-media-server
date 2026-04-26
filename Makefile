.SECONDEXPANSION:

# Deploy target. `local` (default) keeps current behavior — rsync and
# side-effecting commands run on this host. Set TARGET=<ssh-host> to
# rsync over ssh and run side-effects on the remote host.
TARGET ?= local
-include Makefile.local
RSYNC_DEST = $(if $(filter local,$(TARGET)),,$(TARGET):)
REMOTE     = $(if $(filter local,$(TARGET)),,ssh $(TARGET))

LIB_FILES := lib/mediaserver/config.rb lib/mediaserver/renderer.rb lib/mediaserver/validator.rb
SERVICE_YAMLS := $(wildcard services/*/service.yml)
RENDER_DEPS := render.rb $(LIB_FILES) globals.yml $(wildcard config.local.yml)

# ERB source → target mapping:
#   services/<svc>/<path>.erb  →  config/<svc>/<path>
#   <aggregator>.erb           →  config/<aggregator>
SERVICE_ERBS := $(shell find services -name '*.erb' 2>/dev/null)
TOP_ERBS     := $(wildcard *.erb)
ERBS := $(patsubst services/%.erb,config/%,$(SERVICE_ERBS)) \
        $(patsubst %.erb,config/%,$(TOP_ERBS))

# Cached service lists. Regenerated when any service.yml or globals.yml changes.
.make.services: $(SERVICE_YAMLS) globals.yml $(wildcard config.local.yml) $(LIB_FILES) render.rb
	@./render.rb --list-make > $@

-include .make.services

# Non-ERB files under services/ to copy to config/ (strip services/ prefix).
NON_ERB_CONFIGS := $(patsubst services/%,%,$(shell find services -type f ! -name '*.erb' ! -name 'service.yml' 2>/dev/null))
NON_ERB_CONFIG_TARGETS := $(addprefix config/,$(NON_ERB_CONFIGS))

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

.PHONY: clean check test users install install-systemd $(addprefix systemd-,start stop restart enable disable status)

test:
	ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].reject { |f| f == "test/golden_test.rb" }.each { |f| require "./#{f}" }'
	ruby test/golden_test.rb

all: $(ERBS) $(NON_ERB_CONFIG_TARGETS) $(COMPOSE_TARGETS) $(SYSTEMD_UNITS)

clean:
	rm -rf config/ .make.services

users:
	script/make_users.sh

config:
	mkdir config
	chown $(USER):mediaserver config

# --- Aggregator ERBs: depend on every service.yml (full iteration at render time). ---
# Explicit rules take precedence over the implicit pattern rule below.
AGGREGATOR_RULE = mkdir -p $(dir $@); ./render.rb < $< > $@

config/caddy/Caddyfile: services/caddy/Caddyfile.erb $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/homer/config.yml: services/homer/config.yml.erb $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/otelcol/otelcol-config.yaml: services/otelcol/otelcol-config.yaml.erb $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/prometheus/rules/mediaserver.yaml: services/prometheus/rules/mediaserver.yaml.erb $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

config/systemd/mediaserver.target: systemd/mediaserver.target.erb $(RENDER_DEPS) $(SERVICE_YAMLS)
	$(AGGREGATOR_RULE)

# --- Per-service ERB rendering (narrow dep). Secondary expansion picks out the owning service. ---
svc_of = $(firstword $(subst /, ,$(1)))

config/%: services/%.erb $(RENDER_DEPS) services/$$(call svc_of,$$*)/service.yml
	mkdir -p $(dir $@)
	./render.rb < $< > $@

# Copy non-ERB files from services/<svc>/... to config/<svc>/...
config/%: services/%
	mkdir -p $(dir $@)
	cp $< $@

# Per-service docker-compose.yml (same template, different SERVICE_NAME per file).
config/%/docker-compose.yml: systemd/service.compose.yml.erb $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

# Static systemd units (no rendering, just copy).
config/systemd/%.service: systemd/%.service
	mkdir -p $(dir $@)
	cp $< $@

# --- Systemd unit pattern rules ---
config/systemd/%-compose-reload.service: systemd/service-compose-reload.service.erb $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%-compose.path: systemd/service-compose.path.erb $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%-reload.service: systemd/sighup-reload.service.erb $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%.service: systemd/service.service.erb $(RENDER_DEPS) services/$$*/service.yml
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

# .path units enumerate the service's source files; dep includes every file in the service dir.
config/systemd/%.path: systemd/service.path.erb $(RENDER_DEPS) services/$$*/service.yml $$(shell find services/$$* -type f 2>/dev/null)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

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
