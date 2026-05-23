.SECONDEXPANSION:

include Makefile.local

MAKEFLAGS += -j$(shell nproc)

# Only directories with a service.yml.elp are real services. Other dirs under
# services/ (e.g. arr-config/) carry templates whose output is consumed
# by external tools, not by the systemd/docker pipeline — they shouldn't
# trigger __service__ fanout (no .service unit, no path watcher).
#
# service.yml.elp is *input data* (parsed as YAML, with <%= %> tags carried
# verbatim into the manifest); the .elp suffix is purely so editors can
# treat it as an ELP-with-yaml-host file. It is NOT rendered to config/.
ALL_SERVICES := $(patsubst services/%/service.yml.elp,%,$(wildcard services/*/service.yml.elp))

# services/<svc>/<path>.elp -> config/<svc>/<path>
# mindepth 2 skips services/manifest.yaml.elp (the manifest intermediate
# is a build output, not a per-service template).
# -not -name 'service.yml.elp' skips per-service input data (see above).
SERVICE_ELPS := $(shell find services -mindepth 2 -name '*.elp' -not -name 'service.yml.elp' 2>/dev/null)
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

.PHONY: clean distclean check test test-api-config sync install preview all cert $(addprefix systemctl-,start stop restart enable disable status)

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

lisp/.qlot/installed.stamp: lisp/qlfile lisp/qlfile.lock
	cd lisp && qlot install --no-cache --no-color
	@mkdir -p lisp/.qlot && touch $@

# The services manifest is the single source of truth at render time.
# Built from the per-service yamls + override files. Cwd-relative so
# test/ builds its own manifest from test/services/.
SERVICE_YMLS := $(wildcard services/*/service.yml.elp)
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

# Static (non-.elp) files under services/ and targets/debian/ are rsynced into
# config/ as-is. Listed as explicit prereqs of the manifest so a hand-edit to
# a static file triggers a rebuild.
STATIC_SOURCES := $(shell find services targets/debian -type f -not -name '*.elp' 2>/dev/null)

all: config/.manifest

# Manifest = files this deploy ships. Enumerated via rsync's own dry-run lister
# so --exclude-from gives byte-identical semantics to the real `make sync` —
# excluded files are unmanaged on both sides (not shipped, not subject to
# manifest-diff deletion on the host).
#
# Empty rendered files (fanout templates that don't apply to a service — e.g.
# <svc>-reload.service when sighup_reload is unset) stay on disk so make's
# incremental logic sees the targets as up-to-date. They're filtered out of
# the manifest here (--min-size=1, find -not -empty) and out of `make sync`
# the same way, so they never ship and can't shadow host-installed unit files.
config/.manifest config/systemd/.mediaserver.manifest &: $(ALL_OUTPUTS) $(STATIC_SOURCES)
	@echo ""
	@rsync -ac --exclude='*.elp' --exclude='/manifest.yaml' services/ config/
	@rsync -ac --exclude='*.elp' --exclude='*__service__*' targets/debian/ config/
	@rsync -an --out-format='%n' --min-size=1 --exclude-from=config/.sync-exclude \
	  --exclude=/.manifest --exclude=/.sync-exclude --exclude='systemd/***' \
	  config/ /tmp/.mediaserver-manifest-probe/ \
	  | grep -v '/$$' | grep -v '^$$' | sort > config/.manifest
	@cd config/systemd && find . -type f -not -empty -not -name .mediaserver.manifest -printf '%P\n' | sort > .mediaserver.manifest

# Per-service ELPs in services/. Today no per-service template references
# its own service's fields at file-scope — bare-symbol fields in these
# templates appear inside loop-services bodies, which establish their own
# per-iteration scope. So no --service kwarg is needed here. If a future
# template wants its file-top fields bound, add `<%- (for-service :NAME -%>`
# at the top and `<%- ) -%>` at the bottom; no Makefile change required.
config/%: services/%.elp bin/render services/manifest.yaml | $$(@D)/
	@bin/render $< > $@ && printf . || (rm -f $@; echo; echo "FAIL: $<" >&2; exit 1)

# Singleton ELPs under targets/debian/ (no service in path).
config/%: targets/debian/%.elp bin/render services/manifest.yaml | $$(@D)/
	@bin/render $< > $@ && printf . || (rm -f $@; echo; echo "FAIL: $<" >&2; exit 1)

# Fanout: each `__service__`-bearing template expands to one explicit rule
# per service. Inline eval — no define needed since the rule fits on one
# logical line via `;`-separated recipe.
#
# `bin/render | success || fail` ensures: on render failure, the partial
# output file is removed (so a half-rendered config can't ship), the
# template path is echoed prominently to stderr (so the failure isn't
# lost in the dot-stream), and the recipe exits non-zero (so make halts
# / parallel jobs report the failure).
$(foreach elp,$(FANOUT_ELPS),$(foreach svc,$(ALL_SERVICES),$(eval \
config/$(subst __service__,$(svc),$(patsubst targets/debian/%.elp,%,$(elp))): $(elp) bin/render services/manifest.yaml | $$$$(@D)/ ; @bin/render --service $(svc) $$< > $$@ && printf . || (rm -f $$@; echo; echo "FAIL: $$<" >&2; exit 1))))

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

# api-config's Python unit suite. Skips cleanly (exit 0) when pytest is
# absent so the Lisp `make test` and the dev container stay green —
# install with `pip install -r tools/api-config/requirements-dev.txt`.
test-api-config:
	@python3 -c 'import pytest, pytest_asyncio' 2>/dev/null \
	  && (cd tools/api-config && python3 -m pytest -q) \
	  || echo "api-config tests skipped (pip install -r tools/api-config/requirements-dev.txt)"

# Run tests against "golden" config - validate changes to render code mostly
test: test-api-config $(patsubst lisp/cli/%.lisp,bin/%,$(wildcard lisp/cli/*.lisp))
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
# config/.sync-exclude lists rendered-but-controller-only files (e.g.
# vaultwarden/passwords.csv); see targets/debian/.sync-exclude.elp. The same
# file is consumed at manifest-build time above, so excluded paths are
# unmanaged on both sides — never shipped, never manifest-diffed for deletion.
sync: all
	@rsync -acv --delete --min-size=1 --rsync-path="sudo rsync" --mkpath --no-owner --no-group \
	  --exclude-from=config/.sync-exclude --exclude=/.sync-exclude \
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
