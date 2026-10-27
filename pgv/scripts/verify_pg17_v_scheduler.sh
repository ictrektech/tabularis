#!/usr/bin/env bash
set -euo pipefail
umask 077

# Disposable V-Scheduler database/API smoke test against a PGV image.
PGV_IMAGE=""
SCHEDULER_IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) PGV_IMAGE="${2:-}"; shift 2 ;;
    --scheduler-image) SCHEDULER_IMAGE="${2:-}"; shift 2 ;;
    *) echo 'Usage: verify_pg17_v_scheduler.sh --image PGV --scheduler-image V_SCHEDULER' >&2; exit 1 ;;
  esac
done
[[ -n "$PGV_IMAGE" && -n "$SCHEDULER_IMAGE" ]] || { echo 'Both images are required' >&2; exit 1; }

root="${PGV_TEST_WORKDIR:-$HOME/dev/build/pgv-migration-tests}"
mkdir -p "$root"
work="$(mktemp -d "$root/pgv-scheduler-XXXXXX")"
name="pgv-scheduler-test-$$"
pg="$name-pg"
app="$name-app"
network="$name-net"
volume="$name-data"
cleanup() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    docker logs "$app" --tail 30 >&2 || true
    docker logs "$pg" --tail 12 >&2 || true
  fi
  docker rm -f "$app" "$pg" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

cat > "$work/controller.json" <<'JSON'
{"principals":[{"token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","role":"admin","app_id":"admin"},{"token":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","role":"submitter","app_id":"smoke"}],"nodes":[{"id":"test-node","capacities":{"cpu_millicores":2000,"memory_mib":4096}}],"executors":[{"id":"test.execute","contract_version":"1","task_type":"test.execute","node_id":"test-node","app_id":"smoke","resources":{"cpu_millicores":100,"memory_mib":128}}]}
JSON
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$pg" --network "$network" --network-alias pgv \
  -e POSTGRES_PASSWORD=verify -v "$volume":/var/lib/postgresql/data "$PGV_IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready=false
for _ in $(seq 1 120); do
  if [[ "$(docker exec "$pg" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
     docker exec "$pg" psql -U postgres -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
    ready=true; break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo 'PGV startup failed' >&2; exit 1; }
docker exec "$pg" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE vscheduler LOGIN PASSWORD 'verify'" >/dev/null
docker exec "$pg" createdb -U postgres -O vscheduler -T template0 v_scheduler
pg_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$pg")"
[[ -n "$pg_ip" ]] || { echo 'PGV test address missing' >&2; exit 1; }

# Pin only this disposable test container's hostname when build-host Docker
# DNS is unavailable; the VOS package still uses the pgv network alias.
docker run -d --name "$app" --network "$network" --add-host "pgv:$pg_ip" \
  -e SCHEDULER_DATABASE_URL='postgres://vscheduler:verify@pgv:5432/v_scheduler' \
  -v "$work/controller.json":/config/controller.json:ro "$SCHEDULER_IMAGE" \
  controller --config /config/controller.json --listen 0.0.0.0:38120 \
  --ui-dir /opt/v-scheduler/ui >/dev/null
ready=false
for _ in $(seq 1 90); do
  if docker exec "$app" curl -fsS --max-time 2 http://127.0.0.1:38120/health >/dev/null 2>&1; then
    ready=true; break
  fi
  [[ "$(docker inspect -f '{{.State.Status}}' "$app")" == running ]] || break
  sleep 1
done
[[ "$ready" == true ]] || { echo 'V-Scheduler health failed' >&2; exit 1; }
status="$(docker exec "$app" curl -sS -o /tmp/pgv-scheduler-task.json -w '%{http_code}' \
  -H 'Authorization: Bearer BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: pgv-pg17-smoke' \
  -d '{"protocol_version":1,"app_task_id":"pgv-pg17-smoke","executor":{"id":"test.execute","contract_version":"1","task_type":"test.execute"},"parameters":{},"inputs":[]}' \
  http://127.0.0.1:38120/api/v1/tasks)"
[[ "$status" == 202 ]] || { echo "V-Scheduler task submission returned HTTP $status" >&2; docker exec "$app" cat /tmp/pgv-scheduler-task.json >&2; exit 1; }
[[ "$(docker exec "$pg" psql -U vscheduler -d v_scheduler -Atqc \
  "SELECT count(*) FROM vrs_tasks WHERE body->>'app_task_id'='pgv-pg17-smoke'")" == 1 ]] || {
  echo 'V-Scheduler task was not persisted' >&2; exit 1;
}
echo 'V-Scheduler PG17 migrations, health, and task persistence passed'
