#!/usr/bin/env bash
# Build an SBCL binary from a CLI entry point.
# Usage (from repo root): script/build.sh lisp/cli/<name>.lisp
#   Produces bin/<name>; toplevel is mediaserver/<name>:main.
#
# All Lisp state (mediaserver.asd, qlfile, .qlot/) lives under lisp/;
# we cd there so qlot's setup.lisp and asdf's *central-registry*
# resolve relative to lisp/ — and bin/ stays at the repo root.
set -euo pipefail

NAME="$(basename "$1" .lisp)"
ROOT="$PWD"
mkdir -p "$ROOT/bin"

cd lisp
sbcl --non-interactive --no-sysinit --no-userinit \
  --load .qlot/setup.lisp \
  --eval "(push (truename \"$PWD/\") asdf:*central-registry*)" \
  --eval '(ql:quickload :mediaserver)' \
  --eval "(sb-ext:save-lisp-and-die #p\"$ROOT/bin/$NAME\"
            :toplevel #'mediaserver/$NAME:main
            :executable t
            :save-runtime-options t)"
