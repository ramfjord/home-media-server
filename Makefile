.SECONDEXPANSION:

MAKEFLAGS += -j$(shell nproc)

ALL_SERVICES := $(patsubst services/%/,%,$(sort $(dir $(wildcard services/*/.))))

# services/<svc>/<path>.elp -> config/<svc>/<path>
SERVICE_ELPS := $(shell find services -name '*.elp' 2>/dev/null)
SERVICE_OUTPUTS := $(patsubst services/%.elp,config/%,$(SERVICE_ELPS))

# Most .elp files are rendered directly into the config directoy
# If they are in a service directory, they'll be templated with --service <service>
SINGLETON_ELPS := $(shell find targets/debian -name '*.elp' -not -path '*__service__*')
SINGLETON_OUTPUTS := $(patsubst targets/debian/%.elp,config/%,$(SINGLETON_ELPS))

# Create one file per service by naming it __service__.yaml.elp - it will be templated for
# each service foo with bin/render --service <foo> __service__.yaml.elp 
fanout_paths = $(foreach s,$(ALL_SERVICES),$(subst __service__,$(s),$(1)))
FANOUT_ELPS    := $(shell find targets/debian -name '*.elp' -path '*__service__*')
FANOUT_OUTPUTS := $(patsubst targets/debian/%.elp,config/%,$(call fanout_paths,$(FANOUT_ELPS)))

ALL_OUTPUTS := $(SERVICE_OUTPUTS) $(SINGLETON_OUTPUTS) $(FANOUT_OUTPUTS)
DIRS := $(sort $(dir $(ALL_OUTPUTS)))

.PHONY: clean check test sync install preview all $(addprefix systemctl-,start stop restart enable disable status)

# Lisp binaries. One CLI entry point per file in lisp/cli/; each
# produces bin/<name>. The test tree's script/build.sh is a symlink
# shim instead of a real build, so the same rule works in both trees.
bin/%: lisp/cli/%.lisp lisp/src/* mediaserver.asd script/build.sh
	@script/build.sh lisp/cli/$*.lisp

# The services manifest is the single source of truth at render time.
# Built from the per-service yamls + override files. Cwd-relative so
# test/ builds its own manifest from test/services/.
SERVICE_YMLS := $(wildcard services/*/service.yml)
OVERRIDE_YMLS := $(wildcard globals.yml) $(wildcard config.local.yml)
services/manifest.yaml: bin/build-service-config $(SERVICE_YMLS) $(OVERRIDE_YMLS)
	@bin/build-service-config \
	  $(addprefix --override=,$(OVERRIDE_YMLS)) \
	  $(SERVICE_YMLS) > $@

clean:
	rm -rf config/ services/manifest.yaml

# Order-only directory creation. One mkdir per dir, never repeated.
$(DIRS):
	mkdir -p $@

# --- Render rules ---

all: $(ALL_OUTPUTS)
	@echo ""
	@rsync -ac --exclude='*.elp' --exclude='service.yml' --exclude='/manifest.yaml' services/ config/
	@rsync -ac --exclude='*.elp' --exclude='*__service__*' targets/debian/ config/

# Per-service ELPs in services/. Service name implicit from path.
config/%: services/%.elp bin/render services/manifest.yaml | $$(@D)/
	@bin/render --service $(firstword $(subst /, ,$*)) $< > $@ && printf .

# Singleton ELPs under targets/debian/ (no service in path).
config/%: targets/debian/%.elp bin/render services/manifest.yaml | $$(@D)/
	@bin/render $< > $@ && printf .

# Fanout: each `__service__`-bearing template expands to one explicit rule
# per service. Inline eval — no define needed since the rule fits on one
# logical line via `;`-separated recipe.
$(foreach elp,$(FANOUT_ELPS),$(foreach svc,$(ALL_SERVICES),$(eval \
config/$(subst __service__,$(svc),$(patsubst targets/debian/%.elp,%,$(elp))): $(elp) bin/render services/manifest.yaml | $$$$(@D)/ ; @bin/render --service $(svc) $$< > $$@ && printf .)))

# --- Pre-deploy Verification ---

check/%: checks/%.sh.elp all
	@bin/render $< | /bin/bash

check: $(patsubst checks/%.sh.elp,check/%,$(wildcard checks/*.sh.elp))

# Run tests against "golden" config - validate changes to render code mostly
test: $(patsubst lisp/cli/%.lisp,bin/%,$(wildcard lisp/cli/*.lisp))
	@cd test && $(MAKE) all > /dev/null
	@git diff --exit-code test/config/ > /dev/null && echo "goldens clean" || \
	  (echo "GOLDEN DIFF in test/config/. Inspect via 'git diff test/config/'."; exit 1)

# --- Deployment and systemctl-helpers

ifneq (,$(filter sync install preview restart-% systemctl-%,$(MAKECMDGOALS)))
ifndef TARGET
$(error TARGET must be set (e.g. TARGET=fatlaptop, or via Makefile.local))
endif
endif

# Push the rendered bundle to the target's staging dir.
sync: all
	@rsync -acv --rsync-path="sudo rsync" --mkpath \
	  config/ $(TARGET):/opt/mediaserver/staging/
	@ssh $(TARGET) "cd /opt/mediaserver/staging ; sudo make chownall"

# Stage the bundle on the target like install:, but invoke deploy.sh in preview mode
preview: sync
	@ssh $(TARGET) "cd /opt/mediaserver/staging ; sudo make preview"

install: sync
	@ssh $(TARGET) "cd /opt/mediaserver/staging ; sudo make deploy"

systemctl-start systemctl-stop systemctl-restart:
	@ssh $(TARGET) sudo systemctl $(patsubst systemd-%,%,$@) mediaserver.target

# Per-service is-active table. More useful than `systemctl status mediaserver.target`
# when you actually want to know which units are inactive vs failed vs active.
systemctl-status:
	@ssh $(TARGET) "for svc in $(ALL_SERVICES); do printf '%-22s %s\n' \"\$$svc\" \"\$$(systemctl is-active \$$svc.service 2>/dev/null)\"; done"

systemctl-enable:
	@ssh $(TARGET) sudo systemctl enable --now mediaserver-network.service
	@ssh $(TARGET) sudo systemctl enable mediaserver.target
	@ssh $(TARGET) sudo systemctl enable --now $(basename -a config/systemd/*.path)

systemctl-disable:
	@ssh $(TARGET) sudo systemctl disable mediaserver.target
	@ssh $(TARGET) sudo systemctl disable $(basename -a config/systemd/*.path)

# Force-restart a single service. Path units already redeploy on
# `make install`; use this when you want to bounce a service without
# changing config.
restart-%:
	@ssh $(TARGET) sudo systemctl restart $*.service
