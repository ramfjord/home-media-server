.SECONDEXPANSION:

# Deploy target — SSH alias of the host receiving rsync + side-effect
# commands. Required by install/preview/systemd-*/restart-*; unused by
# all/test/check. Set in Makefile.local or pass on the command line:
# `make TARGET=fatlaptop install`.
-include Makefile.local
ifneq (,$(filter install preview restart-% systemd-%,$(MAKECMDGOALS)))
ifndef TARGET
$(error TARGET must be set (e.g. TARGET=fatlaptop, or via Makefile.local))
endif
endif

# Anchor: directory containing this Makefile, after symlink resolution.
# When invoked via test/Makefile -> ../Makefile, this still points at
# the repo root — so the targets/debian templates and Lisp sources
# resolve the same way regardless of cwd. cwd-relative things
# (services/, globals.yml, config.local.yml, config/, bin/render)
# resolve to the invocation dir, which is what makes the same Makefile
# drive both production and goldens: each tree gets its own bin/render
# with that tree's config baked in.
REPO_ROOT  := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))
TARGET_DIR := $(REPO_ROOT)/targets/debian
LISP_SRCS  := $(wildcard $(REPO_ROOT)/lisp/src/*.lisp) $(REPO_ROOT)/mediaserver.asd

ALL_SERVICES := $(notdir $(wildcard services/*))

# services/<svc>/<path>.elp -> config/<svc>/<path>
SERVICE_ELPS := $(shell find services -name '*.elp' 2>/dev/null)
SERVICE_OUTPUTS := $(patsubst services/%.elp,config/%,$(SERVICE_ELPS))

# Non-template files under services/ get copied verbatim.
NON_TPL_CONFIGS := $(patsubst services/%,%,$(shell find services -type f ! -name '*.elp' ! -name '*.erb' ! -name 'service.yml' 2>/dev/null))
NON_TPL_TARGETS := $(addprefix config/,$(NON_TPL_CONFIGS))

# Target tree (debian).
#
# Templates with `__service__` in the path = fan-out (one render per
# service, empty output skipped). Templates without it = singleton.
#
# Manifests live at config/<path-with-__service__-replaced-by-mediaserver>.manifest;
# the pattern rule swaps `mediaserver` back to `__service__` via $(subst)
# to find the actual source file.
SINGLETON_ELPS := $(shell find $(TARGET_DIR) -name '*.elp' -not -path '*__service__*')
FANOUT_ELPS    := $(shell find $(TARGET_DIR) -name '*.elp' -path '*__service__*')
TARGET_STATIC  := $(shell find $(TARGET_DIR) -type f -not -name '*.elp' -not -path '*__service__*')

TARGET_PREFIX  := $(TARGET_DIR)/
SINGLETON_OUTPUTS     := $(patsubst $(TARGET_PREFIX)%.elp,config/%,$(SINGLETON_ELPS))
TARGET_STATIC_OUTPUTS := $(patsubst $(TARGET_PREFIX)%,config/%,$(TARGET_STATIC))
MANIFEST_TARGETS      := $(patsubst $(TARGET_PREFIX)%.elp,config/%.manifest,$(subst __service__,mediaserver,$(FANOUT_ELPS)))

ALL_OUTPUTS := $(SERVICE_OUTPUTS) $(NON_TPL_TARGETS) $(SINGLETON_OUTPUTS) $(TARGET_STATIC_OUTPUTS) $(MANIFEST_TARGETS)
DIRS := $(sort $(dir $(ALL_OUTPUTS)))

.PHONY: clean check test users install preview all $(addprefix systemd-,start stop restart enable disable status)

test: bin/render
	ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].reject { |f| f == "test/golden_test.rb" }.each { |f| require "./#{f}" }'
	@cd test && $(MAKE) all > /dev/null
	@git diff --exit-code test/config/ > /dev/null && echo "goldens clean" || \
	  (echo "GOLDEN DIFF in test/config/. Inspect via 'git diff test/config/'."; exit 1)

# Lisp render binary. Builds in ~2s; per-call render is ~25ms because
# the merged config (services + globals + local overrides) is baked
# into the saved core. Bake-root is cwd, so test/ builds its own
# binary with test/services/ baked in.
bin/render: $(LISP_SRCS) $(REPO_ROOT)/script/build-render.sh \
               $(wildcard services/*/service.yml) \
               globals.yml \
               $(wildcard config.local.yml)
	$(REPO_ROOT)/script/build-render.sh $(CURDIR)/bin/render $(CURDIR)

all: $(ALL_OUTPUTS)

clean:
	rm -rf config/

users:
	script/make_users.sh

# Order-only directory creation. One mkdir per dir, never repeated.
$(DIRS):
	mkdir -p $@

# --- Render rules ---
svc_of = $(firstword $(subst /, ,$(1)))

# Per-service ELPs in services/. Service name implicit from path.
config/%: services/%.elp bin/render | $$(@D)/
	SERVICE_NAME=$(call svc_of,$*) bin/render $< > $@

# Non-template service files: copy.
config/%: services/% | $$(@D)/
	cp $< $@

# Singleton ELPs under targets/debian/ (no $service in path).
config/%: $(TARGET_DIR)/%.elp bin/render | $$(@D)/
	bin/render $< > $@

# Non-template files under targets/debian/: copy.
config/%: $(TARGET_DIR)/% | $$(@D)/
	cp $< $@

# Per-template fan-out manifest. The recipe iterates ALL_SERVICES;
# non-empty renders write the unit file and append its path to the
# manifest. SECONDEXPANSION on the prereq swaps `mediaserver` back
# to `$service` so the actual source file resolves.
config/%.manifest: $$(subst mediaserver,__service__,$(TARGET_DIR)/%.elp) bin/render | $$(@D)/
	@> $@
	@for svc in $(ALL_SERVICES); do \
	  f=$$(echo "$*" | sed "s|mediaserver|$$svc|"); out="config/$$f"; \
	  mkdir -p "$$(dirname "$$out")"; \
	  bin/render --service $$svc $< > "$$out.tmp"; \
	  if [ -s "$$out.tmp" ]; then mv "$$out.tmp" "$$out"; echo "$$f" >> $@; else rm "$$out.tmp"; fi; \
	done

PATH_MANIFESTS := config/systemd/mediaserver.path.manifest \
                  config/systemd/mediaserver-compose.path.manifest
COMPOSE_MANIFEST := config/mediaserver/docker-compose.yml.manifest

check: all
	# TODO convert these to use the container versions of promtool/amtool
	promtool check config config/prometheus/prometheus.yml
	amtool check-config config/alertmanager/alertmanager.yml
	@for f in $$(cat $(COMPOSE_MANIFEST) 2>/dev/null); do \
	  docker compose -f "config/$$f" config > /dev/null || (echo "FAIL: $$f" && exit 1); \
	done
	docker run --rm \
		-v $(CURDIR)/config/otelcol:/etc/otelcol \
		otel/opentelemetry-collector-contrib:latest \
		validate --config=/etc/otelcol/otelcol-config.yaml
	@for f in config/systemd/*.service config/systemd/*.path; do \
	  systemd-analyze verify "$$f" > /dev/null || (echo "FAIL: $$f" && exit 1); \
	done

install: check
	rsync -av --rsync-path="sudo rsync" --delete --mkpath \
	  config/ $(TARGET):/opt/mediaserver/staging/
	ssh $(TARGET) sudo bash /opt/mediaserver/staging/deploy.sh

# Stage the bundle on the target like install:, but invoke deploy.sh in
# preview mode (rsync --dry-run --itemize-changes; no chown -R, no
# daemon-reload). Shows per-file changes that `make install` would apply.
preview: check
	rsync -av --rsync-path="sudo rsync" --delete --mkpath \
	  config/ $(TARGET):/opt/mediaserver/staging/
	ssh $(TARGET) sudo bash /opt/mediaserver/staging/deploy.sh preview

systemd-start systemd-stop systemd-restart:
	@ssh $(TARGET) sudo systemctl $(patsubst systemd-%,%,$@) mediaserver.target

# Per-service is-active table. More useful than `systemctl status mediaserver.target`
# when you actually want to know which units are inactive vs failed vs active.
systemd-status:
	@ssh $(TARGET) "for svc in $(ALL_SERVICES); do printf '%-22s %s\n' \"\$$svc\" \"\$$(systemctl is-active \$$svc.service 2>/dev/null)\"; done"

systemd-enable:
	ssh $(TARGET) sudo systemctl enable --now mediaserver-network.service
	ssh $(TARGET) sudo systemctl enable mediaserver.target
	@units=$$(cat $(PATH_MANIFESTS) 2>/dev/null | xargs -n1 basename | tr '\n' ' '); \
	  ssh $(TARGET) sudo systemctl enable --now $$units

systemd-disable:
	ssh $(TARGET) sudo systemctl disable mediaserver.target
	@units=$$(cat $(PATH_MANIFESTS) 2>/dev/null | xargs -n1 basename | tr '\n' ' '); \
	  ssh $(TARGET) sudo systemctl disable $$units

# Force-restart a single service. Path units already redeploy on
# `make install`; use this when you want to bounce a service without
# changing config. Combine: `make install restart-radarr`.
restart-%:
	@ssh $(TARGET) sudo systemctl restart $*.service
