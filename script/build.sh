#!/usr/bin/env bash
# Build an SBCL binary from a CLI entry point, inside the lisp image.
# Usage (from repo root): script/build.sh lisp/cli/<name>.lisp
#   Produces bin/<name>; toplevel is mediaserver/<name>:main.
set -euo pipefail
IMAGE=mediaserver-lisp:latest

docker build -q -t "$IMAGE" "$(dirname "$0")" >/dev/null

mkdir -p bin
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/workspace" -w /workspace \
  -e HOME=/tmp -e XDG_CACHE_HOME=/workspace/.qlot-cache -e XDG_CONFIG_HOME=/tmp/.config "$IMAGE" \
  bash -c "
    set -euo pipefail
    # Populate .qlot/ from qlfile (+ qlfile.lock if present). Idempotent;
    # cheap on subsequent builds because deps are already cloned.
    qlot install --no-color
    sbcl --non-interactive --no-sysinit --no-userinit \
      --load .qlot/setup.lisp \
      --eval '(push (truename \"/workspace/\") asdf:*central-registry*)' \
      --eval '(ql:quickload :mediaserver)' \
      --eval '(sb-ext:save-lisp-and-die #p\"/workspace/bin/$(basename "$1" .lisp)\"
                :toplevel #'\''mediaserver/$(basename "$1" .lisp):main
                :executable t
                :save-runtime-options t)'
  "
