# SBCL + quicklisp image with mediaserver's deps pre-loaded.
# Used by script/build.sh as a build sandbox; the produced bin/<name>
# is a normal ELF that runs on any glibc-compatible host with
# libyaml-0.so.2 installed.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      sbcl curl ca-certificates libyaml-0-2 \
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

# Pre-fetch every dependency so first build inside the container does
# not hit the network. Listed explicitly to keep the image cacheable.
RUN sbcl --non-interactive --no-sysinit --no-userinit \
      --load /opt/quicklisp/setup.lisp \
      --eval '(ql:quickload (list :cffi :cl-yaml :str :alexandria :serapeum :clingon :fiveam))' \
 && chmod -R a+rX /opt/quicklisp

WORKDIR /workspace
