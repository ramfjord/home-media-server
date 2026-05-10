#!/bin/bash
# Aggregated host-package installer.
#
# Generated from each service.yml.elp's `host_install:` block. To declare a
# host-installed dependency: add `host_install: |` (a literal multi-line
# shell block) to the service's service.yml.elp; this file picks it up
# automatically. The block is responsible for being idempotent — apt's
# native idempotence covers the simple case (`apt-get install -y X` is
# a no-op when X is current); .deb-from-URL flows should `dpkg -s X` or
# similar to short-circuit when already installed.
#
# Run order matches services' :order field (low first), in case a later
# block depends on tooling installed by an earlier one.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Best-effort: a stale apt cache is fine, but a transient mirror failure
# shouldn't fail the unit and pin the .path watcher in `activating`.
apt-get update || true

