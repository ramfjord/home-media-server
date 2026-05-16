#!/bin/sh
# Route qBittorrent's FileLogger to container stdout (-> docker -> journald
# -> Alloy -> Loki) instead of a rotating file journald never sees. Paired
# with Backup=false in qBittorrent.conf so qbit never tries to rename the
# symlink. /proc/1/fd/1 is s6's init stdout, which docker pipes to its log
# driver.
set -eu
LOG_DIR=/config/qBittorrent/logs
mkdir -p "$LOG_DIR"
ln -sfn /proc/1/fd/1 "$LOG_DIR/qbittorrent.log"
