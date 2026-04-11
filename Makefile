# Standard ERB files (1:1 mapping), exclude systemd templates (handled by separate rules)
ERBS := $(filter-out config/systemd/%,$(addprefix config/,$(patsubst %.erb,%,$(wildcard *.erb */*.erb */*/*.erb */*/*/*.erb))))

# Generate .make.services with service lists (cached until services.yml changes)
# This caches the results of expensive $(shell yq ...) queries so they're not re-executed
# on every 'make' invocation. Without this, Make would spawn yq every time, making
# repeated 'make all' calls slow. By generating a file with the results, Make sees
# a stable dependency and skips re-evaluation until services.yml actually changes.
.make.services: services.yml $(wildcard config.local.yml)
	@mkdir -p $(@D)
	@{ \
	  echo "# Generated service lists - do not edit"; \
	  echo "ALL_SERVICES := $$(yq -r '.services[] | .name' services.yml 2>/dev/null | tr '\n' ' ')"; \
	  echo "DOCKERIZED_SERVICES := $$(yq -r '.services[] | select(.docker_config != null) | .name' services.yml 2>/dev/null | tr '\n' ' ')"; \
	  echo "SYSTEMD_SERVICES := $$(yq -r '.services[] | select(.docker_config != null) | select(.unit == null) | .name' services.yml 2>/dev/null | tr '\n' ' ')"; \
	  echo "SIGHUP_SERVICES := $$(yq -r '.services[] | select(.sighup_reload == true) | .name' services.yml 2>/dev/null | tr '\n' ' ')"; \
	  echo -n "SERVICES_WITH_CONFIG := "; \
	  for svc in $$(yq -r '.services[] | select(.docker_config != null) | select(.unit == null) | .name' services.yml 2>/dev/null); do \
	    [ -n "$$(find $$svc -type f 2>/dev/null)" ] && printf "%s " "$$svc"; \
	  done; \
	  echo ""; \
	} > $@

-include .make.services

# Non-ERB config files (images, static assets, etc) to copy to config/
# Finds all non-ERB files in service directories
NON_ERB_CONFIGS := $(shell for svc in $(ALL_SERVICES); do find $$svc -type f ! -name "*.erb" 2>/dev/null; done | sed 's|^\./||')

NON_ERB_CONFIG_TARGETS := $(addprefix config/,$(NON_ERB_CONFIGS))

# Systemd unit variables (derived from cached service lists above)
SYSTEMD_SERVICE_UNITS := $(addprefix config/systemd/,$(addsuffix .service,$(SYSTEMD_SERVICES)))
SYSTEMD_PATH_UNITS    := $(addprefix config/systemd/,$(addsuffix .path,$(SERVICES_WITH_CONFIG)))
SYSTEMD_COMPOSE_PATH_UNITS := $(addprefix config/systemd/,$(addsuffix -compose.path,$(SYSTEMD_SERVICES)))
SYSTEMD_COMPOSE_RELOAD_UNITS := $(addprefix config/systemd/,$(addsuffix -compose-reload.service,$(SYSTEMD_SERVICES)))
SIGHUP_RELOAD_UNITS   := $(addprefix config/systemd/,$(addsuffix -reload.service,$(SIGHUP_SERVICES)))
SYSTEMD_UNITS := $(SYSTEMD_SERVICE_UNITS) $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS) $(SYSTEMD_COMPOSE_RELOAD_UNITS) $(SIGHUP_RELOAD_UNITS)

.PHONY: clean check users install install-systemd $(addprefix systemd-,start stop restart enable disable status)

all: $(ERBS) $(NON_ERB_CONFIG_TARGETS) $(SYSTEMD_UNITS)

clean:
	rm -rf config/

users:
	script/make_users.sh

config:
	mkdir config
	chown $(USER):mediaserver config

# Standard ERB rendering - this defines the ERBS targets
config/%: %.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	./render.rb < $(patsubst config/%,%,$@).erb > $@
	@service=$$(echo $@ | cut -d'/' -f2); \
	if grep -q "name: $$service" services.yml; then sudo chown -R $$service:mediaserver config/$$service; fi

# Copy non-ERB files as-is to config/
config/%: %
	mkdir -p $(dir $@)
	cp $< $@

# Systemd unit pattern rules
config/systemd/%-reload.service: systemd/sighup-reload.service.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%.service: systemd/service.service.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%.path: systemd/service.path.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%-compose.path: systemd/service-compose.path.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%-compose-reload.service: systemd/service-compose-reload.service.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

config/systemd/%-reload.service: systemd/sighup-reload.service.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	SERVICE_NAME=$* ./render.rb < $< > $@

check: all
	# TODO convert these to use the container versions of promtool/amtool
	promtool check config config/prometheus/prometheus.yml
	amtool check-config config/alertmanager/alertmanager.yml
	docker-compose -f config/docker-compose.yml config > /dev/null
	docker run --rm \
		-v $(CURDIR)/config/otelcol:/etc/otelcol \
		otel/opentelemetry-collector-contrib:latest \
		validate --config=/etc/otelcol/otelcol-config.yaml
	@for f in config/systemd/*.service config/systemd/*.path; do \
	  systemd-analyze verify "$$f" > /dev/null || (echo "FAIL: $$f" && exit 1); \
	done

SYSTEMD_DIR := /etc/systemd/system

install: check
	sudo rsync -av --exclude='systemd/' config/ /opt/mediaserver/config/

install-systemd: install $(SYSTEMD_UNITS)
	sudo mkdir -p $(SYSTEMD_DIR)
	sudo rsync -av config/systemd/ $(SYSTEMD_DIR)/
	sudo systemctl daemon-reload
	@echo "Starting path units to monitor config changes..."
	@sudo systemctl start $(notdir $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS))

systemd-start systemd-stop systemd-restart systemd-status:
	@cmd=$$(echo $@ | sed 's/systemd-//'); \
	units=$$(echo $(SYSTEMD_SERVICES) | sed 's/ /.service /g').service; \
	echo "Running systemctl $$cmd on all services..."; \
	sudo systemctl $$cmd $$units

systemd-enable:
	@echo "Enabling docker services..."; \
	for svc in $(SYSTEMD_SERVICES); do \
	  echo "  systemctl enable $$svc.service"; \
	  sudo systemctl enable --force $$svc.service; \
	done; \
	echo "Enabling path units for auto-reload on config changes..."; \
	for unit in $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS); do \
	  echo "  systemctl enable $$(basename $$unit)"; \
	  sudo systemctl enable --force $$unit; \
	done

systemd-disable:
	@echo "Disabling docker services..."; \
	for svc in $(SYSTEMD_SERVICES); do \
	  echo "  systemctl disable $$svc.service"; \
	  sudo systemctl disable $$svc.service; \
	done; \
	echo "Disabling path units..."; \
	for unit in $(SYSTEMD_PATH_UNITS) $(SYSTEMD_COMPOSE_PATH_UNITS); do \
	  echo "  systemctl disable $$(basename $$unit)"; \
	  sudo systemctl disable $$unit; \
	done
