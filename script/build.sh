#!/usr/bin/env bash
# Build an SBCL binary from a CLI entry point.
# Usage (from repo root): script/build.sh lisp/cli/<name>.lisp
#   Produces bin/<name>; toplevel is mediaserver/<name>:main.
set -euo pipefail

NAME="$(basename "$1" .lisp)"
mkdir -p bin

qlot install --no-color
sbcl --non-interactive --no-sysinit --no-userinit \
  --load .qlot/setup.lisp \
  --eval "(push (truename \"$PWD/\") asdf:*central-registry*)" \
  --eval '(ql:quickload :mediaserver)' \
  --eval "(sb-ext:save-lisp-and-die #p\"$PWD/bin/$NAME\"
            :toplevel #'mediaserver/$NAME:main
            :executable t
            :save-runtime-options t)"
