#!/bin/bash

PLEX_URL=$(curl -fsSL 'https://plex.tv/api/downloads/5.json' | \
		jq -r '.computer.Linux.releases[] | select(.distro == "debian" and .build == "linux-x86_64") | .url')
if [[ -z "$PLEX_URL" ]]; then
		error "Could not determine Plex download URL"
fi
echo "Downloading Plex from $PLEX_URL"
curl -fsSL -o /tmp/plexmediaserver.deb "$PLEX_URL"
