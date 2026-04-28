#!/usr/bin/env bash
# Build a standalone SBCL render binary. Loads the mediaserver system
# and bakes the config tree at BAKE_ROOT into the saved core.
#
# Usage: script/build-render.sh [OUTPUT [BAKE_ROOT]]
#   OUTPUT    defaults to bin/render relative to repo root.
#   BAKE_ROOT defaults to repo root. Pass test/ to build a binary
#             that renders the test fixture tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/bin/render}"
BAKE_ROOT="${2:-$REPO_ROOT}"
mkdir -p "$(dirname "$OUTPUT")"

sbcl --non-interactive --no-sysinit --no-userinit \
  --load ~/quicklisp/setup.lisp \
  --eval "(push (truename \"$REPO_ROOT/\") asdf:*central-registry*)" \
  --eval "(push (truename \"$REPO_ROOT/elp/\") asdf:*central-registry*)" \
  --eval "(asdf:load-system :mediaserver)" \
  --eval "(mediaserver::bake-config \"$BAKE_ROOT/\")" \
  --eval "(sb-ext:save-lisp-and-die #p\"$OUTPUT\"
            :toplevel #'mediaserver/cli:main
            :executable t
            :save-runtime-options t)"
