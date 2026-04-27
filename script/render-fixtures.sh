#!/usr/bin/env bash
# Drive bin/render over the test/ fixture tree and emit all rendered
# files into a target dir. The target defaults to test/config-lisp/ so
# the diff against checked-in test/config/ goldens stays clean.
#
# Mirrors test/golden_test.rb's per-service iteration — same templates,
# same output paths — but invokes the Lisp renderer instead of the
# Ruby one. The two trees should be byte-identical.
#
# Usage:
#   script/render-fixtures.sh [DST]    # DST defaults to test/config-lisp/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$REPO_ROOT/bin/render"
ROOT="$REPO_ROOT/test"
DST="${1:-$REPO_ROOT/test/config-lisp}"

[ -x "$RENDER" ] || { echo "missing $RENDER — run script/build-render.sh"; exit 1; }
mkdir -p "$DST/systemd"

# Pull service lists from the renderer itself (--list-make is the same
# data the production Makefile relies on).
eval "$("$RENDER" --list-make --root "$ROOT" | grep -v '^#' | sed 's/ := /=/; s/$/"/; s/=/="/')"

render() {
  mkdir -p "$(dirname "$3")"
  SERVICE_NAME="$1" "$RENDER" --root "$ROOT" "$2" > "$3"
}

# For service.path: list deployed config files (everything in the
# service dir except service.yml; .elp templates land at .elp-stripped
# names). Make would compute this in production via $(shell find ...)
# and pass it via SERVICE_FILES.
service_files() {
  local svc="$1" dir="$ROOT/services/$svc"
  [ -d "$dir" ] || return 0
  # Only .elp templates (the Lisp side); strip the extension to match
  # the deployed filename. .erb shadow files in the fixture tree are
  # ignored — those are the Ruby renderer's input, not deployed output.
  ( cd "$dir" && find . -type f -name '*.elp' -printf '%P\n' | sed 's/\.elp$//' ) | tr '\n' ' '
}

# Per-service systemd templates (one render per service).
for svc in $DOCKERIZED_SERVICES; do
  files="$(service_files "$svc")"
  render "$svc" "$REPO_ROOT/systemd/service.compose.yml.elp"           "$DST/$svc/docker-compose.yml"
  render "$svc" "$REPO_ROOT/systemd/service.service.elp"               "$DST/systemd/$svc.service"
  SERVICE_FILES="$files" render "$svc" "$REPO_ROOT/systemd/service.path.elp" "$DST/systemd/$svc.path"
  render "$svc" "$REPO_ROOT/systemd/service-compose.path.elp"          "$DST/systemd/$svc-compose.path"
  render "$svc" "$REPO_ROOT/systemd/service-compose-reload.service.elp" "$DST/systemd/$svc-compose-reload.service"
done

for svc in $SIGHUP_SERVICES; do
  render "$svc" "$REPO_ROOT/systemd/sighup-reload.service.elp" "$DST/systemd/$svc-reload.service"
done

# Aggregator template (all services in scope, no per-service binding).
"$RENDER" --root "$ROOT" "$REPO_ROOT/systemd/mediaserver.target.elp" > "$DST/systemd/mediaserver.target"

# list-make.txt — same data Make uses, sealed as a golden so the format is locked.
"$RENDER" --root "$ROOT" --list-make > "$DST/list-make.txt"

# Per-service config templates (e.g. fx-caddy/Caddyfile, fx-prometheus/prometheus.yml).
while IFS= read -r tmpl; do
  rel="${tmpl#$ROOT/services/}"               # fx-caddy/Caddyfile.elp
  svc="${rel%%/*}"                             # fx-caddy
  out="${rel%.elp}"                            # fx-caddy/Caddyfile
  mkdir -p "$DST/$(dirname "$out")"
  render "$svc" "$tmpl" "$DST/$out"
done < <(find "$ROOT/services" -name '*.elp' 2>/dev/null)

echo "rendered into $DST"
