#!/usr/bin/env bash
# Build an SBCL binary from a CLI entry point, inside the lisp image.
# Usage (from repo root): script/build.sh lisp/cli/<name>.lisp
#   Produces bin/<name>; toplevel is mediaserver/<name>:main.
set -euo pipefail
IMAGE=mediaserver-lisp:latest

docker build -q -t "$IMAGE" "$(dirname "$0")" >/dev/null

mkdir -p bin
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/workspace" -w /workspace -e HOME=/tmp "$IMAGE" \
  sbcl --non-interactive --no-sysinit --no-userinit \
    --load /opt/quicklisp/setup.lisp \
    --eval "(push (truename \"/workspace/\") asdf:*central-registry*)" \
    --eval "(push (truename \"/workspace/elp/\") asdf:*central-registry*)" \
    --eval "(asdf:load-system :mediaserver)" \
    --eval "(sb-ext:save-lisp-and-die #p\"/workspace/bin/$(basename "$1" .lisp)\"
              :toplevel #'mediaserver/$(basename "$1" .lisp):main
              :executable t
              :save-runtime-options t)"
