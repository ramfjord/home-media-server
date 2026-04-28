#!/usr/bin/env bash
# Build an SBCL binary for one of mediaserver's CLI entry points.
#
# Usage: script/build.sh <system> <toplevel-symbol> <output-path>
#   system           ASDF system to load (e.g. mediaserver, mediaserver/build)
#   toplevel-symbol  package:function for save-lisp-and-die's :toplevel
#   output-path      where to write the binary
set -euo pipefail

SYSTEM="$1"
TOPLEVEL="$2"
OUTPUT="$3"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$OUTPUT")"

sbcl --non-interactive --no-sysinit --no-userinit \
  --load ~/quicklisp/setup.lisp \
  --eval "(push (truename \"$REPO_ROOT/\") asdf:*central-registry*)" \
  --eval "(push (truename \"$REPO_ROOT/elp/\") asdf:*central-registry*)" \
  --eval "(asdf:load-system :$SYSTEM)" \
  --eval "(sb-ext:save-lisp-and-die #p\"$OUTPUT\"
            :toplevel #'$TOPLEVEL
            :executable t
            :save-runtime-options t)"
