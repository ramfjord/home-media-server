#!/bin/bash
set -euo pipefail
export PATH="/usr/sbin:$PATH"

INSTALL_BASE=$(yq -r '.install_base // "/opt/mediaserver"' services.yml)

groupadd --force mediaserver 2>/dev/null || true

yq -r '.services[] | select(.docker_config != null) | .name' services.yml | while read -r name; do
  if ! id -u "$name" &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin "$name"
  fi

  # Add user to any specified groups
  groups=$(yq -r ".services[] | select(.name == \"$name\") | .groups[]?" services.yml)
  if [ -n "$groups" ]; then
    echo "$groups" | while read -r group; do
      usermod -a -G "$group" "$name" 2>/dev/null || true
    done
  fi

  mkdir -p "$INSTALL_BASE/config/$name"
  chown -R "$name:mediaserver" "$INSTALL_BASE/config/$name"
  find "$INSTALL_BASE/config/$name" -type f -exec chmod 640 {} \;
  find "$INSTALL_BASE/config/$name" -type d -exec chmod 750 {} \;
done
