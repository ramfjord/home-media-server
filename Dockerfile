# Dev environment for mediaserver: SBCL + Quicklisp + qlot, plus the
# host tooling needed to run `make install` end-to-end (rsync, ssh, make).
#
# Two roles, one image:
#   1. Build sandbox for `script/build.sh` (produces bin/<name> binaries).
#   2. Dev shell for users who don't want to install SBCL on their host —
#      `docker compose run --rm dev` drops them at a bash prompt with the
#      workspace bind-mounted at /workspace.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      sbcl curl ca-certificates git libyaml-0-2 \
      make rsync openssh-client \
      vim nano less \
    && rm -rf /var/lib/apt/lists/*

# Named user at UID 1000 so the dev shell shows a real prompt instead
# of "I have no name!". Compose can override UID/GID via .env for hosts
# where the user isn't 1000 — the username won't resolve in that case,
# which is a cosmetic-only regression.
RUN useradd -m -u 1000 -s /bin/bash mediaserver

# Point ssh at the host-keys mount (compose binds the host's ~/.ssh to
# /run/host-ssh:ro). Keeping the mount outside HOME avoids docker
# auto-creating a root-owned .ssh subdir inside the .devhome bind mount.
RUN printf '%s\n' \
      'Host *' \
      '  IdentityFile /run/host-ssh/id_ed25519' \
      '  IdentityFile /run/host-ssh/id_rsa' \
      '  IdentityFile /run/host-ssh/id_ecdsa' \
      '  UserKnownHostsFile /run/host-ssh/known_hosts ~/.ssh/known_hosts' \
      '  StrictHostKeyChecking accept-new' \
    > /etc/ssh/ssh_config.d/00-mediaserver.conf

# Install quicklisp into /opt/quicklisp as root, then make it readable
# by any UID. Building/loading systems writes fasls under
# ~/.cache/common-lisp which is per-user at runtime.
RUN curl -sSL -o /tmp/ql.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && sbcl --non-interactive --no-sysinit --no-userinit \
      --load /tmp/ql.lisp \
      --eval '(quicklisp-quickstart:install :path "/opt/quicklisp/")' \
 && rm /tmp/ql.lisp \
 && chmod -R a+rX /opt/quicklisp

# Pre-quickload qlot's sources into /opt/quicklisp so the wrapper below
# doesn't hit the network at runtime. We can't dump a qlot binary here:
# save-lisp-and-die would bake the build-time HOME (/root) into uiop's
# cache paths, breaking qlot when run as a non-root UID with HOME=/tmp.
RUN sbcl --non-interactive --no-sysinit --no-userinit \
      --load /opt/quicklisp/setup.lisp \
      --eval '(ql:quickload (list :qlot :qlot/command :qlot/subcommands :qlot/install :qlot/add :qlot/bundle :qlot/check :qlot/main :qlot/cli :qlot/http :qlot/fetch :dexador))' \
 && chmod -R a+rX /opt/quicklisp

RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec sbcl --non-interactive --no-sysinit --no-userinit \' \
      '  --load /opt/quicklisp/setup.lisp \' \
      '  --eval "(ql:quickload (list :qlot :qlot/subcommands :qlot/cli) :silent t)" \' \
      '  --eval "(qlot/cli::main)" \' \
      '  -- "$@"' \
    > /usr/local/bin/qlot \
 && chmod a+rx /usr/local/bin/qlot

# qlot creates a project-local dist under .qlot/ that's separate from
# /opt/quicklisp, so we can't usefully pre-fetch project deps into the
# image — they'd just be ignored at build time. .qlot/ lives in the
# mounted workspace and persists across builds, so the first build is
# slow but subsequent ones are fast.

WORKDIR /workspace
