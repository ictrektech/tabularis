#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Automatic migration test failed at line $LINENO" >&2' ERR

IMAGE=""
OLD_IMAGE=""
SCHEDULER_IMAGE=""
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --old-image) OLD_IMAGE="${2:-}"; shift 2 ;;
    --scheduler-image) SCHEDULER_IMAGE="${2:-}"; shift 2 ;;
    *) echo 'Usage: verify_pg17_auto_migration.sh --image PG17 --old-image PG16 [--scheduler-image V_SCHEDULER]' >&2; exit 1 ;;
  esac
done
[[ -n "$IMAGE" && -n "$OLD_IMAGE" ]] || { echo 'Both images are required' >&2; exit 1; }

name="pgv-auto-test-$$"
old="$name-old"
new="$name-new"
volume="$name-data"
fresh="$name-fresh"
scheduler="$name-scheduler"
network="$name-network"
cleanup() {
  docker rm -f "$old" "$new" "$scheduler" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$fresh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ready() {
  local container="$1" user="$2"
  for _ in $(seq 1 90); do
    if [[ "$(docker exec "$container" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
       docker exec "$container" pg_isready -U "$user" -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

migrate() {
  local database="$1" password="${2:-verify-rotated}"
  docker run --rm --network none --name "$new" \
    -e POSTGRES_USER=postgres -e "POSTGRES_PASSWORD=$password" -e "POSTGRES_DB=$database" \
    -e WEKNORA_DB_NAME=WeKnora -e WEKNORA_DB_USER=weknora -e WEKNORA_DB_PASSWORD=verify \
    -e IMMICH_DB_NAME=immich -e IMMICH_DB_USER=immich -e IMMICH_DB_PASSWORD=verify \
    -e IMMICH_DB_SUPERUSER=true -e NOWEN_DB_NAME=nowen_video \
    -e NOWEN_DB_USER=nowen -e NOWEN_DB_PASSWORD=verify \
    -v "$volume":/pgv-storage \
    -v "$repo/ictrek.app/src/init":/init:ro \
    --entrypoint /bin/bash "$IMAGE" /init/auto-migrate.sh
}

docker volume create "$volume" >/dev/null
docker run -d --name "$old" -e POSTGRES_PASSWORD=verify \
  -e PGDATA=/pgv-storage/data -v "$volume":/pgv-storage \
  "$OLD_IMAGE" -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$old" postgres
docker exec -i "$old" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE retained_probe (id integer PRIMARY KEY, value text);
INSERT INTO retained_probe VALUES (42, 'preserved');
SQL
docker exec "$old" createdb -U postgres -T template0 WeKnora
docker exec "$old" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE v_scheduler_migration LOGIN PASSWORD 'verify-scheduler'" >/dev/null
docker exec "$old" createdb -U postgres -O v_scheduler_migration -T template0 v_scheduler
docker exec "$old" psql -U postgres -d v_scheduler -v ON_ERROR_STOP=1 \
  -c 'CREATE TABLE retained_scheduler_probe (id integer PRIMARY KEY)' >/dev/null
docker exec "$old" psql -U postgres -d v_scheduler -v ON_ERROR_STOP=1 \
  -c 'INSERT INTO retained_scheduler_probe VALUES (7)' >/dev/null
docker exec "$old" psql -U postgres -d v_scheduler -v ON_ERROR_STOP=1 \
  -c 'GRANT SELECT ON retained_scheduler_probe TO v_scheduler_migration' >/dev/null
docker exec -i "$old" psql -U postgres -d WeKnora -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION pg_search;
CREATE TABLE embeddings (id bigint PRIMARY KEY, content text);
INSERT INTO embeddings VALUES (1, 'automatic migration search');
CREATE INDEX embeddings_search_idx ON embeddings USING bm25 (id, content)
  WITH (key_field='id', text_fields='{"content":{"tokenizer":{"type":"chinese_lindera"}}}');
SQL
# The PG17 provisioning connection must authenticate with the updated VOS
# password rather than the password restored from the PG16 globals dump.
docker exec "$old" sed -i '1i host all all 127.0.0.1/32 scram-sha-256' \
  /pgv-storage/data/pg_hba.conf
docker stop -t 60 "$old" >/dev/null
docker rm "$old" >/dev/null
# A real VOS storage directory may be 0755 after the old container is gone.
# The migration service must normalize it before starting the PG16 server.
docker run --rm -v "$volume":/pgv-storage --entrypoint chmod "$IMAGE" \
  0755 /pgv-storage/data

# A bad installation database setting must fail before replacing the active
# PG16 path. Retrying with the corrected package settings needs no SQL access.
if migrate missing_database; then
  echo 'Migration unexpectedly accepted a missing database' >&2
  exit 1
fi
if [[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint sh "$IMAGE" \
  -c 'find /pgv-storage/pgv-migration-backups -name globals.sql | wc -l')" -lt 1 ]]; then
  docker run --rm -v "$volume":/pgv-storage --entrypoint sh "$IMAGE" -c \
    'for f in /pgv-storage/pgv-migration-backups/attempt-*/pg16-start.log; do
       if [ -f "$f" ]; then cat "$f"; fi
     done' >&2
fi
[[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint cat "$IMAGE" \
  /pgv-storage/data/PG_VERSION)" == 16 ]]
[[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint sh "$IMAGE" \
  -c 'find /pgv-storage/pgv-migration-backups -name globals.sql | wc -l')" -ge 1 ]]

if ! migrate postgres; then
  docker run --rm -v "$volume":/pgv-storage --entrypoint sh "$IMAGE" -c \
    'for f in /pgv-storage/pgv-migration-backups/attempt-*/provision.log \
              /pgv-storage/pgv-migration-backups/attempt-*/disable-bootstrap.log; do
       if [ -f "$f" ]; then tail -20 "$f"; fi
     done' >&2
  exit 1
fi
[[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint cat "$IMAGE" \
  /pgv-storage/data/PG_VERSION)" == 17 ]]
[[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint cat "$IMAGE" \
  /pgv-storage/data-pg16-backup/PG_VERSION)" == 16 ]]
migrate postgres # idempotent PG17 no-op

# Simulate a power loss after the old directory was moved aside but before
# the restored PG17 directory reached the active path.
docker run --rm -v "$volume":/pgv-storage --entrypoint sh "$IMAGE" -ec '
  mv /pgv-storage/data /pgv-storage/data-pg17-staging
  touch /pgv-storage/.pgv-cutover-in-progress /pgv-storage/.pgv-stage-ready
'
migrate postgres
[[ "$(docker run --rm -v "$volume":/pgv-storage --entrypoint cat "$IMAGE" \
  /pgv-storage/data/PG_VERSION)" == 17 ]]

docker run -d --name "$new" -e PGDATA=/pgv-storage/data \
  -v "$volume":/pgv-storage "$IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$new" postgres
[[ "$(docker exec "$new" env PGPASSWORD=verify-rotated psql -h 127.0.0.1 \
  -U postgres -d postgres -Atqc 'SELECT 1')" == 1 ]]
[[ "$(docker exec "$new" env PGPASSWORD=verify-scheduler psql -h 127.0.0.1 \
  -U v_scheduler_migration -d v_scheduler -Atqc \
  'SELECT id FROM retained_scheduler_probe')" == 7 ]]
[[ "$(docker exec "$new" psql -U postgres -d postgres -Atqc \
  'SELECT id FROM retained_probe WHERE value='\''preserved'\''')" == 42 ]]
[[ "$(docker exec "$new" psql -U postgres -d WeKnora -Atqc \
  "SELECT id FROM embeddings WHERE content ||| 'automatic'")" == 1 ]]

if [[ -n "$SCHEDULER_IMAGE" ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"; cleanup' EXIT
  cat > "$work/controller.json" <<'JSON'
{"principals":[{"token":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","role":"submitter","app_id":"smoke"}],"nodes":[{"id":"test-node","capacities":{"cpu_millicores":2000,"memory_mib":4096}}],"executors":[{"id":"test.execute","contract_version":"1","task_type":"test.execute","node_id":"test-node","app_id":"smoke","resources":{"cpu_millicores":100,"memory_mib":128}}]}
JSON
  docker network create "$network" >/dev/null
  docker network connect --alias pgv "$network" "$new"
  pg_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$new")"
  docker run -d --name "$scheduler" --network "$network" --add-host "pgv:$pg_ip" \
    -e SCHEDULER_DATABASE_URL='postgres://v_scheduler_migration:verify-scheduler@pgv:5432/v_scheduler' \
    -v "$work/controller.json":/config/controller.json:ro "$SCHEDULER_IMAGE" \
    controller --config /config/controller.json --listen 0.0.0.0:38120 \
    --ui-dir /opt/v-scheduler/ui >/dev/null
  for _ in $(seq 1 90); do
    if docker exec "$scheduler" curl -fsS --max-time 2 http://127.0.0.1:38120/health >/dev/null 2>&1; then break; fi
    sleep 1
  done
  status="$(docker exec "$scheduler" curl -sS -o /tmp/pgv-scheduler-task.json -w '%{http_code}' \
    -H 'Authorization: Bearer BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' \
    -H 'Content-Type: application/json' -H 'Idempotency-Key: pgv-migrated-smoke' \
    -d '{"protocol_version":1,"app_task_id":"pgv-migrated-smoke","executor":{"id":"test.execute","contract_version":"1","task_type":"test.execute"},"parameters":{},"inputs":[]}' \
    http://127.0.0.1:38120/api/v1/tasks)"
  [[ "$status" == 202 ]]
  [[ "$(docker exec "$new" psql -U postgres -d v_scheduler -Atqc \
    "SELECT count(*) FROM vrs_tasks WHERE body->>'app_task_id'='pgv-migrated-smoke'")" == 1 ]]
  echo 'Existing V-Scheduler credentials, controller startup and task persistence passed'
fi

docker volume create "$fresh" >/dev/null
docker run --rm --network none -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=verify \
  -e POSTGRES_DB=postgres -v "$fresh":/pgv-storage \
  -v "$repo/ictrek.app/src/init":/init:ro \
  --entrypoint /bin/bash "$IMAGE" /init/auto-migrate.sh >/dev/null
echo 'Automatic fresh install, PG16 failure/retry, cutover recovery, restored credentials and PG17 data checks passed'
