#!/usr/bin/env bash
set -euo pipefail

# Verify the standard ARM PGV image on the host that will run it.  It always
# uses a new data volume so an old initialized cluster cannot mask an initdb or
# preload failure.

IMAGE=""
PULL_IMAGE=true
DOCKER_BIN="${DOCKER_BIN:-docker}"
NAME="pgv-arm-runtime-verify-$$"
VOLUME="${NAME}-data"

usage() {
  cat <<'USAGE'
Usage: ./scripts/verify_arm_runtime.sh --image registry.example/pgv:arm_17_YYYYMMDD

--local-image uses an already built/loaded candidate without pulling.

Creates a temporary PostgreSQL data volume, starts PGV with its ARM default
preloads, creates pg_search, pg_cron, vector, vectors, vchord and pg_ivm, then runs a
BM25 query. Run this on every ARM target class before publishing a VOS package.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --local-image) PULL_IMAGE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage >&2; exit 1; }
command -v "$DOCKER_BIN" >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

cleanup() {
  "$DOCKER_BIN" rm -f "$NAME" >/dev/null 2>&1 || true
  "$DOCKER_BIN" volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$PULL_IMAGE" == true ]]; then
  "$DOCKER_BIN" pull "$IMAGE" >/dev/null
fi
"$DOCKER_BIN" volume create "$VOLUME" >/dev/null
"$DOCKER_BIN" run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=verify \
  -v "$VOLUME":/var/lib/postgresql/data \
  "$IMAGE" \
  -c 'shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so,pg_ivm' >/dev/null

for _ in $(seq 1 75); do
  if [[ "$("$DOCKER_BIN" exec "$NAME" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
     "$DOCKER_BIN" exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  [[ "$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$NAME")" != "exited" ]] || {
    "$DOCKER_BIN" logs "$NAME" >&2
    exit 1
  }
  sleep 1
done

"$DOCKER_BIN" exec "$NAME" pg_isready -U postgres
"$DOCKER_BIN" exec -e PGPASSWORD=verify "$NAME" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atc \
  "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_search; CREATE EXTENSION IF NOT EXISTS pg_cron; CREATE EXTENSION IF NOT EXISTS vectors; CREATE EXTENSION IF NOT EXISTS vchord; CREATE EXTENSION IF NOT EXISTS pg_ivm; CREATE TABLE pgv_bm25_probe (id BIGINT PRIMARY KEY, content TEXT); INSERT INTO pgv_bm25_probe VALUES (1, 'portable search works'), (2, 'other document'); CREATE INDEX pgv_bm25_probe_idx ON pgv_bm25_probe USING bm25 (id, content) WITH (key_field = 'id'); SELECT id FROM pgv_bm25_probe WHERE content ||| 'portable'; SELECT extname || chr(58) || extversion FROM pg_extension WHERE extname IN (chr(112)||chr(103)||chr(95)||chr(115)||chr(101)||chr(97)||chr(114)||chr(99)||chr(104), chr(112)||chr(103)||chr(95)||chr(99)||chr(114)||chr(111)||chr(110), chr(118)||chr(101)||chr(99)||chr(116)||chr(111)||chr(114), chr(118)||chr(101)||chr(99)||chr(116)||chr(111)||chr(114)||chr(115), chr(118)||chr(99)||chr(104)||chr(111)||chr(114)||chr(100)) ORDER BY extname;"

[[ "$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$NAME")" == "running" ]]
echo "ARM runtime verification passed: $IMAGE"
