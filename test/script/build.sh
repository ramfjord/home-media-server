#!/usr/bin/env bash
# In the test tree, "building" a binary means symlinking the parent's.
# Same signature as ../script/build.sh so the shared Makefile rule works.
set -euo pipefail
NAME="$(basename "$1" .lisp)"
mkdir -p bin
ln -sf "../../bin/$NAME" "bin/$NAME"
