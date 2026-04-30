# SBCL + quicklisp + qlot image with mediaserver's deps pre-loaded.
# Used by script/build.sh as a build sandbox; the produced bin/<name>
# is a normal ELF that runs on any glibc-compatible host with
# libyaml-0.so.2 installed.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      sbcl curl ca-certificates git libyaml-0-2 \
    && rm -rf /var/lib/apt/lists/*

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

# NOTE: qlot creates a project-local dist under .qlot/ that's separate
# from /opt/quicklisp, so we can't usefully pre-fetch project deps into
# the image — they'd just be ignored at build time. .qlot/ lives in the
# mounted workspace and persists across builds, so the first build is
# slow but subsequent ones are fast.

WORKDIR /workspace
