#!/usr/bin/env bash
# Build bin/render: a standalone SBCL executable that drops in for
# render.rb. Loads the mediaserver system, then save-lisp-and-die's
# the image with mediaserver/cli:main as the entrypoint.
#
# Usage: script/build-render.sh [OUTPUT]
#   OUTPUT defaults to bin/render relative to repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/bin/render}"
mkdir -p "$(dirname "$OUTPUT")"

sbcl --non-interactive --no-sysinit --no-userinit \
  --load ~/quicklisp/setup.lisp \
  --eval "(push (truename \"$REPO_ROOT/\") asdf:*central-registry*)" \
  --eval "(push (truename \"$REPO_ROOT/elp/\") asdf:*central-registry*)" \
  --eval "(asdf:load-system :mediaserver)" \
  --eval "(mediaserver::bake-config \"$REPO_ROOT/\")" \
  --eval "(sb-ext:save-lisp-and-die #p\"$OUTPUT\"
            :toplevel #'mediaserver/cli:main
            :executable t
            :save-runtime-options t)"
