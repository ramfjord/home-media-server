#!/bin/bash
# Install host-level config under /etc/ on the target.
# Usage: script/install-host-config.sh [local|<ssh-alias>]
#
# Idempotent: only reloads daemons when files actually change.
# Categories:
#   etc/sysctl.d/*.conf   → reload via `sysctl --system`
#   etc/docker/daemon.json → reload via `systemctl restart docker`
#
# Files in host/ become Nix module config at the NixOS cutover.
# See plans/crashloop-recovery.md and plans/nixos-target.md.
set -euo pipefail

TARGET="${1:-local}"
HOST_DIR="$(cd "$(dirname "$0")/.." && pwd)/host"

if [[ ! -d "$HOST_DIR/etc" ]]; then
  echo "No $HOST_DIR/etc/ to install — nothing to do."
  exit 0
fi

# Capture rsync's itemized-changes output. --checksum so we don't reload
# on mtime-only differences. --chown=root:root because /etc/ files must
# be root-owned regardless of the source file owner.
if [[ "$TARGET" == "local" ]]; then
  CHANGES=$(sudo rsync -a --itemize-changes --checksum --chown=root:root \
    "$HOST_DIR/etc/" /etc/)
  RELOAD=(sudo)
else
  CHANGES=$(rsync -a --itemize-changes --checksum --chown=root:root \
    --rsync-path="sudo rsync" \
    "$HOST_DIR/etc/" "$TARGET:/etc/")
  RELOAD=(ssh "$TARGET" sudo)
fi

if [[ -z "$CHANGES" ]]; then
  echo "No changes; nothing to reload."
  exit 0
fi

echo "Changes:"
echo "  ${CHANGES//$'\n'/$'\n  '}"

# `^.f` matches any file change in itemize-changes output.
if echo "$CHANGES" | grep -qE '^.f.*sysctl\.d/'; then
  echo "Reloading sysctl..."
  "${RELOAD[@]}" sysctl --system
fi

if echo "$CHANGES" | grep -q 'docker/daemon\.json'; then
  echo "Restarting docker..."
  "${RELOAD[@]}" systemctl restart docker
fi
