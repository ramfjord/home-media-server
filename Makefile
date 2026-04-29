.SECONDEXPANSION:

# Silence recipe echo by default. Recipes opt back in with explicit `echo`
# lines for the steps worth showing. Override with `make V=1`.
ifndef V
MAKEFLAGS += --silent
endif
MAKEFLAGS += -j$(shell nproc)

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

ALL_SERVICES := $(patsubst services/%/,%,$(sort $(dir $(wildcard services/*/.))))

# services/<svc>/<path>.elp -> config/<svc>/<path>
SERVICE_ELPS := $(shell find services -name '*.elp' 2>/dev/null)
SERVICE_OUTPUTS := $(patsubst services/%.elp,config/%,$(SERVICE_ELPS))

# Non-template files under services/ get copied verbatim.
NON_TPL_CONFIGS := $(patsubst services/%,%,$(shell find services -type f ! -name '*.elp' ! -name 'service.yml' 2>/dev/null))
NON_TPL_TARGETS := $(addprefix config/,$(NON_TPL_CONFIGS))

# Target tree (debian).
#
# Templates with `__service__` in the path = fan-out (one render per
# service, empty output skipped). Templates without it = singleton.
#
# Manifests live at config/<path-with-__service__-replaced-by-mediaserver>.manifest;
# the pattern rule swaps `mediaserver` back to `__service__` via $(subst)
# to find the actual source file.
SINGLETON_ELPS := $(shell find targets/debian -name '*.elp' -not -path '*__service__*')
FANOUT_ELPS    := $(shell find targets/debian -name '*.elp' -path '*__service__*')
TARGET_STATIC  := $(shell find targets/debian -type f -not -name '*.elp' -not -path '*__service__*')

SINGLETON_OUTPUTS     := $(patsubst targets/debian/%.elp,config/%,$(SINGLETON_ELPS))
TARGET_STATIC_OUTPUTS := $(patsubst targets/debian/%,config/%,$(TARGET_STATIC))
MANIFEST_TARGETS      := $(patsubst targets/debian/%.elp,config/%.manifest,$(subst __service__,mediaserver,$(FANOUT_ELPS)))

# Expand a fan-out path (with __service__ placeholder) to one path per service.
fanout_paths = $(foreach s,$(ALL_SERVICES),$(subst __service__,$(s),$(1)))
FANOUT_OUTPUTS := $(patsubst targets/debian/%.elp,config/%,$(call fanout_paths,$(FANOUT_ELPS)))

# Per-manifest output dirs, derived from a manifest stem (e.g. mediaserver/foo).
# Used by the manifest rule via second-expansion so each manifest only declares
# the dirs it actually writes to. Reuses fanout_paths after rewriting the
# `mediaserver` placeholder back to `__service__`.
manifest_dirs = $(sort $(dir $(call fanout_paths,config/$(subst mediaserver,__service__,$(1)))))

ALL_OUTPUTS := $(SERVICE_OUTPUTS) $(NON_TPL_TARGETS) $(SINGLETON_OUTPUTS) $(TARGET_STATIC_OUTPUTS) $(MANIFEST_TARGETS)
DIRS := $(sort $(dir $(ALL_OUTPUTS) $(FANOUT_OUTPUTS)))

.PHONY: clean check test users install preview all $(addprefix systemd-,start stop restart enable disable status)

test: $(patsubst lisp/cli/%.lisp,bin/%,$(wildcard lisp/cli/*.lisp))
	@cd test && $(MAKE) all > /dev/null
	@git diff --exit-code test/config/ > /dev/null && echo "goldens clean" || \
	  (echo "GOLDEN DIFF in test/config/. Inspect via 'git diff test/config/'."; exit 1)

# Lisp binaries. One CLI entry point per file in lisp/cli/; each
# produces bin/<name>. The test tree's script/build.sh is a symlink
# shim instead of a real build, so the same rule works in both trees.
bin/%: lisp/cli/%.lisp lisp/src/* mediaserver.asd script/build.sh
	script/build.sh lisp/cli/$*.lisp

# The services manifest is the single source of truth at render time.
# Built from the per-service yamls + override files. Cwd-relative so
# test/ builds its own manifest from test/services/.
SERVICE_YMLS := $(wildcard services/*/service.yml)
OVERRIDE_YMLS := $(wildcard globals.yml) $(wildcard config.local.yml)

services/manifest.yaml: bin/build-service-config $(SERVICE_YMLS) $(OVERRIDE_YMLS)
	bin/build-service-config \
	  $(addprefix --override=,$(OVERRIDE_YMLS)) \
	  $(SERVICE_YMLS) > $@

all: $(ALL_OUTPUTS)

clean:
	rm -rf config/ services/manifest.yaml

users:
	script/make_users.sh

# Order-only directory creation. One mkdir per dir, never repeated.
$(DIRS):
	mkdir -p $@

# --- Render rules ---

# Per-service ELPs in services/. Service name implicit from path.
config/%: services/%.elp bin/render services/manifest.yaml | $$(@D)/
	bin/render --service $(firstword $(subst /, ,$*)) $< > $@ && printf .

# Non-template service files: copy.
config/%: services/% | $$(@D)/
	cp $< $@

# Singleton ELPs under targets/debian/ (no $service in path).
config/%: targets/debian/%.elp bin/render services/manifest.yaml | $$(@D)/
	bin/render $< > $@ && printf .

# Non-template files under targets/debian/: copy.
config/%: targets/debian/% | $$(@D)/
	cp $< $@

# Pre-deploy check scripts. checks/<name>.sh.elp -> config/checks/<name>.sh.
# Rendered on demand by the check/<name> targets below — not part of `all`.
config/checks/%: checks/%.elp bin/render services/manifest.yaml | $$(@D)/
	bin/render $< > $@ && printf .

# Per-template fan-out manifest. The recipe iterates ALL_SERVICES;
# non-empty renders write the unit file and append its path to the
# manifest. SECONDEXPANSION on the prereq swaps `mediaserver` back
# to `$service` so the actual source file resolves.
config/%.manifest: $$(subst mediaserver,__service__,targets/debian/%.elp) bin/render services/manifest.yaml | $$(@D)/ $$(call manifest_dirs,$$*)
	@> $@
	@for svc in $(ALL_SERVICES); do \
	  f=$$(echo "$*" | sed "s|mediaserver|$$svc|"); out="config/$$f"; \
	  bin/render --service $$svc $< > "$$out"; \
	  [ -s "$$out" ] && { echo "$$f" >> $@; printf .; } || rm "$$out"; \
	done

PATH_MANIFESTS := config/systemd/mediaserver.path.manifest \
                  config/systemd/mediaserver-compose.path.manifest
COMPOSE_MANIFEST := config/mediaserver/docker-compose.yml.manifest

# One `check/<name>` per checks/<name>.sh.elp; the umbrella `check` target
# depends on all of them so -j runs them in parallel. Not declared .PHONY
# (which would disable implicit-rule search); the source .elp prereq pins
# the pattern to stems that actually exist.
check: $(patsubst checks/%.sh.elp,check/%,$(wildcard checks/*.sh.elp))

check/%: all
	@echo "=== check: $* ==="
	@bash $<

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
