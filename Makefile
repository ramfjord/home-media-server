.SECONDEXPANSION:

include Makefile.local

MAKEFLAGS += -j$(shell nproc)

# Only directories with a service.yml are real services. Other dirs under
# services/ (e.g. arr-config/) carry templates whose output is consumed
# by external tools, not by the systemd/docker pipeline — they shouldn't
# trigger __service__ fanout (no .service unit, no path watcher).
ALL_SERVICES := $(patsubst services/%/service.yml,%,$(wildcard services/*/service.yml))

# services/<svc>/<path>.elp -> config/<svc>/<path>
# mindepth 2 skips services/manifest.yaml.elp (the manifest intermediate
# is a build output, not a per-service template).
SERVICE_ELPS := $(shell find services -mindepth 2 -name '*.elp' 2>/dev/null)
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

.PHONY: clean distclean check test sync install preview all cert $(addprefix systemctl-,start stop restart enable disable status)

# Lisp binaries. One CLI entry point per file in lisp/cli/; each
# produces bin/<name>. All Lisp sources, the .asd, and qlot's state
# live under lisp/ so qlot's project root is lisp/ — keeps stray
# .asd files elsewhere in the tree (elp/, etc.) out of qlot's
# scanning path. The test tree's script/build.sh is a symlink shim
# instead of a real build, so the same rule works in both trees;
# test/lisp -> ../lisp gives test/'s Makefile-symlink-resolved view
# the same lisp/* paths as the parent.
bin/%: lisp/cli/%.lisp lisp/src/* lisp/mediaserver.asd script/build.sh lisp/.qlot/installed.stamp
	@script/build.sh lisp/cli/$*.lisp

lisp/.qlot/installed.stamp: lisp/qlfile.lock
	cd lisp && qlot install --no-color
	@mkdir -p lisp/.qlot && touch $@

# The services manifest is the single source of truth at render time.
# Built from the per-service yamls + override files. Cwd-relative so
# test/ builds its own manifest from test/services/.
SERVICE_YMLS := $(wildcard services/*/service.yml)
OVERRIDE_YMLS := $(wildcard config.local.yml)
# build-service-config writes both files in one run: manifest.yaml.elp is
# the merged-but-unrendered intermediate (cross-service tags still live);
# manifest.yaml is the ELP-rendered final form templates consume.
services/manifest.yaml services/manifest.yaml.elp &: bin/build-service-config $(SERVICE_YMLS) $(OVERRIDE_YMLS)
	@bin/build-service-config \
	  $(addprefix --override=,$(OVERRIDE_YMLS)) \
	  -o services/manifest.yaml.elp \
	  $(SERVICE_YMLS)

clean:
	rm -rf config/ services/manifest.yaml services/manifest.yaml.elp

# Wipe everything regenerable, including built binaries and the qlot
# dist. Use before validating a from-scratch dev-container build (e.g.
# `script/dev make all`).
distclean: clean
	rm -rf bin/ lisp/.qlot/

# Order-only directory creation. One mkdir per dir, never repeated.
$(DIRS):
	mkdir -p $@

# --- Render rules ---

all: $(ALL_OUTPUTS)
	@echo ""
	@rsync -ac --exclude='*.elp' --exclude='service.yml' --exclude='/manifest.yaml' services/ config/
	@rsync -ac --exclude='*.elp' --exclude='*__service__*' targets/debian/ config/
	@# Drop empty rendered files. Fanout templates that don't apply to a
	@# service (e.g. <svc>-reload.service when sighup_reload is unset)
	@# render to whitespace; without this, those zero-byte files ship and
	@# land as no-op stubs in /etc/systemd/system/. Harmless when names
	@# are project-local, but they'd shadow upstream package units for
	@# host-installed services.
	@find config -type f -empty -delete
	@find config -type f -not -path 'config/systemd/*' -not -name .manifest -printf '%P\n' | sort > config/.manifest
	@cd config/systemd && find . -type f -not -name .mediaserver.manifest -printf '%P\n' | sort > .mediaserver.manifest

# Per-service ELPs in services/. Today no per-service template references
# its own service's fields at file-scope — bare-symbol fields in these
# templates appear inside loop-services bodies, which establish their own
# per-iteration scope. So no --service kwarg is needed here. If a future
# template wants its file-top fields bound, add `<%- (for-service :NAME -%>`
# at the top and `<%- ) -%>` at the bottom; no Makefile change required.
config/%: services/%.elp bin/render services/manifest.yaml | $$(@D)/
	@bin/render $< > $@ && printf .

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

# Apply declared config to upstream HTTP APIs (qBit + Servarr today).
# api-config is a regular service — see services/api-config/. The
# image (tools/api-config/) is kept out of the Lisp toolchain so
# per-API quirks (Servarr's forceSave, qBit's qbit-form encoding)
# live in idiomatic Python with structured error reporting; it ships
# via GHCR and the deploy host pulls it like any other image.
API_CONFIG_TAG   ?= ghcr.io/ramfjord/api-config:latest
API_CONFIG_STAMP := tools/api-config/.image-built
$(API_CONFIG_STAMP): tools/api-config/Dockerfile tools/api-config/configure.py
	@docker build -t $(API_CONFIG_TAG) tools/api-config/
	@touch $@

# Push the api-config image to GHCR. Run `docker login ghcr.io -u <user>`
# once with a PAT that has write:packages scope before invoking. Override
# the tag via API_CONFIG_TAG=... if pushing somewhere else.
api-config-publish: $(API_CONFIG_STAMP)
	@docker push $(API_CONFIG_TAG)

# Run tests against "golden" config - validate changes to render code mostly
test: $(patsubst lisp/cli/%.lisp,bin/%,$(wildcard lisp/cli/*.lisp))
	@cd test && $(MAKE) all > /dev/null
	@git diff --exit-code test/config/ > /dev/null && echo "goldens clean" || \
	  (echo "GOLDEN DIFF in test/config/. Inspect via 'git diff test/config/'."; exit 1)

# --- Deployment and systemctl-helpers

ifneq (,$(filter cert sync install preview restart-% systemctl-%,$(MAKECMDGOALS)))
ifndef TARGET
$(error TARGET must be set (e.g. TARGET=fatlaptop, or via Makefile.local))
endif
endif

# Push the rendered bundle to the target's staging dir. --delete is safe here:
# /opt/mediaserver/staging/ is fully owned by us and rebuilt every deploy.
sync: all
	@rsync -acv --delete --rsync-path="sudo rsync" --mkpath --no-owner --no-group \
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
	@ssh $(TARGET) sudo systemctl enable --now $(notdir $(wildcard config/systemd/*.path))
	@ssh $(TARGET) sudo systemctl enable --now tailscale-cert.timer

# One-shot manual run of the tailscale-cert renewal unit. Useful as a
# bootstrap step before `make systemctl-start` so the cert exists at
# <install_base>/certs/<hostname>.{crt,key} by the time caddy starts.
# Subsequent renewals are handled by tailscale-cert.timer.
cert:
	@ssh $(TARGET) sudo systemctl start tailscale-cert.service

systemctl-disable:
	@ssh $(TARGET) sudo systemctl disable mediaserver.target
	@ssh $(TARGET) sudo systemctl disable $(notdir $(wildcard config/systemd/*.path))

# Force-restart a single service. Path units already redeploy on
# `make install`; use this when you want to bounce a service without
# changing config.
restart-%:
	@ssh $(TARGET) sudo systemctl restart $*.service
