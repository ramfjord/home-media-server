#!/usr/bin/env bash
# Build an SBCL binary from a CLI entry point.
# Usage: script/build.sh lisp/cli/<name>.lisp
#   Produces bin/<name>; toplevel is mediaserver/<name>:main.
set -euo pipefail

SRC="$1"
NAME="$(basename "$SRC" .lisp)"
OUTPUT="bin/$NAME"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$OUTPUT")"

sbcl --non-interactive --no-sysinit --no-userinit \
  --load ~/quicklisp/setup.lisp \
  --eval "(push (truename \"$REPO_ROOT/\") asdf:*central-registry*)" \
  --eval "(push (truename \"$REPO_ROOT/elp/\") asdf:*central-registry*)" \
  --eval "(asdf:load-system :mediaserver)" \
  --eval "(sb-ext:save-lisp-and-die #p\"$OUTPUT\"
            :toplevel #'mediaserver/$NAME:main
            :executable t
            :save-runtime-options t)"
