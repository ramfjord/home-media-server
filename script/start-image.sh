#!/usr/bin/env bash
# Start a dev SBCL image with :mediaserver loaded, the manifest read,
# and (when available) swank-lsp listening so editors with LSP support
# can attach. The single canonical entry point for human-driven dev
# work in this repo.
#
# Usage:
#   script/start-image.sh                        # interactive REPL
#   SWANK_PORT=4005 script/start-image.sh        # also start swank for vlime/SLIME-attach
#   LISP_LAUNCHER='script/dev sbcl' script/start-image.sh  # run inside the dev container
#
# $LISP_LAUNCHER lets users override how SBCL is invoked without editing
# this script. Defaults to host-native qlot + sbcl, since that's the
# fast path for anyone with the toolchain installed (see CLAUDE.md).
# Container/nix users override accordingly.
#
# Why cd into lisp/: qlot scans the cwd for *.asd to plan its load. With
# everything Lisp confined to lisp/, the scan is fast and complete.
# See CLAUDE.md "Bumping elp" for the longer story.

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INIT_FILE="$PROJECT_ROOT/script/dev-image.lisp"

LAUNCHER=${LISP_LAUNCHER:-"qlot exec sbcl"}

cd "$PROJECT_ROOT/lisp"
exec $LAUNCHER --load "$INIT_FILE"
