#!/usr/bin/env bash
set -euo pipefail
umask 077

# Read-only source dump and isolated PG17 restore; never switches installed data.
SOURCE=""
IMAGE=""
TARGET_DATA_DIR=""
BACKUP_ROOT=""
WRITES_PAUSED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-container) SOURCE="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --target-data-dir) TARGET_DATA_DIR="${2:-}"; shift 2 ;;
    --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
    --writes-paused) WRITES_PAUSED=true; shift ;;
    *) echo 'Usage: verify_pg17_live_clone.sh --source-container PG16 --image PG17 [--target-data-dir ABSOLUTE_NEW_DIR --backup-root ABSOLUTE_DIR --writes-paused]' >&2; exit 1 ;;
  esac
done
[[ -n "$SOURCE" && -n "$IMAGE" ]] || { echo 'Both arguments are required' >&2; exit 1; }
[[ "$(docker exec "$SOURCE" psql -U postgres -d postgres -Atqc 'SHOW server_version_num')" == 16* ]] || {
  echo 'Source is not a PostgreSQL 16 cluster' >&2; exit 1;
}

if [[ -n "$TARGET_DATA_DIR" ]]; then
  [[ "$TARGET_DATA_DIR" = /* && "$BACKUP_ROOT" = /* && "$WRITES_PAUSED" == true ]] || {
    echo 'Persistent migration requires absolute target/backup paths and --writes-paused' >&2; exit 1;
  }
  [[ "$BACKUP_ROOT" != "$TARGET_DATA_DIR" && "$BACKUP_ROOT" != "$TARGET_DATA_DIR/"* ]] || {
    echo 'Backup root must be outside the new data directory' >&2; exit 1;
  }
  [[ ! -e "$TARGET_DATA_DIR" ]] || { echo 'Target data directory already exists' >&2; exit 1; }
  mkdir -m 700 "$TARGET_DATA_DIR"
elif [[ -n "$BACKUP_ROOT" || "$WRITES_PAUSED" == true ]]; then
  echo '--backup-root and --writes-paused require --target-data-dir' >&2; exit 1
fi

root="${BACKUP_ROOT:-${PGV_TEST_WORKDIR:-$HOME/dev/build/pgv-migration-tests}}"
mkdir -p "$root"
work="$(mktemp -d "$root/pgv-live-XXXXXX")"
name="pgv-17-clone-$$"
volume="${name}-data"
migrator="pgv_clone_$$"
cleanup() {
  local result=$?
  if [[ -n "$TARGET_DATA_DIR" ]]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    if [[ "$result" -ne 0 ]]; then
      echo "Migration incomplete; inspect protected target=$TARGET_DATA_DIR backup=$work" >&2
    fi
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    rm -rf "$work"
  fi
}
trap cleanup EXIT

mapfile -t databases < <(docker exec "$SOURCE" psql -U postgres -d postgres -Atqc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
[[ ${#databases[@]} -gt 0 ]] || { echo 'No source databases found' >&2; exit 1; }
docker exec "$SOURCE" pg_dumpall -U postgres --globals-only > "$work/globals.sql"
for i in "${!databases[@]}"; do
  docker exec "$SOURCE" pg_dump -U postgres -Fc -d "${databases[i]}" > "$work/db-$i.dump"
done

if [[ -n "$TARGET_DATA_DIR" ]]; then
  volume="$TARGET_DATA_DIR"
else
  docker volume create "$volume" >/dev/null
fi
docker run -d --name "$name" -e "POSTGRES_USER=$migrator" \
  -e POSTGRES_PASSWORD=verify -e "POSTGRES_DB=$migrator" \
  -v "$volume":/var/lib/postgresql/data "$IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
for _ in $(seq 1 90); do
  if [[ "$(docker exec "$name" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
     docker exec "$name" pg_isready -U "$migrator" -d "$migrator" >/dev/null 2>&1; then break; fi
  if [[ "$(docker inspect -f '{{.State.Status}}' "$name")" == exited ]]; then
    echo 'PG17 clone exited during startup' >&2; exit 1
  fi
  sleep 1
done
docker exec -i "$name" psql -U "$migrator" -d "$migrator" -v ON_ERROR_STOP=1 \
  < "$work/globals.sql" > "$work/globals.log"

for i in "${!databases[@]}"; do
  db="${databases[i]}"
  owner="$(docker exec -i "$SOURCE" psql -U postgres -d postgres -v db="$db" -At <<'SQL'
SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'db';
SQL
)"
  [[ -n "$owner" ]] || { echo 'Database owner lookup failed' >&2; exit 1; }
  if [[ "$db" != postgres ]]; then
    # ParadeDB's image bootstraps its own paradedb database. This fresh
    # target must instead contain the source database with its original owner.
    if [[ "$db" == paradedb ]]; then
      docker exec "$name" psql -U "$migrator" -d "$migrator" -v ON_ERROR_STOP=1 \
        -c 'DROP DATABASE IF EXISTS paradedb WITH (FORCE)' >/dev/null
    fi
    docker exec -i "$name" psql -U "$migrator" -d "$migrator" \
      -v ON_ERROR_STOP=1 -v db="$db" -v owner="$owner" >/dev/null <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0', :'db', :'owner') \gexec
SQL
  fi
  # The PG16 archive can create pg_search before vector, but pg_search 0.25
  # requires vector at creation time. Only pre-create it where relevant.
  needs_vector="$(docker exec "$SOURCE" psql -U postgres -d "$db" -Atqc \
    "SELECT count(*) FROM pg_extension WHERE extname IN ('vector','pg_search','vchord')")"
  if [[ "$needs_vector" != 0 ]]; then
    docker exec "$name" psql -U "$migrator" -d "$db" -v ON_ERROR_STOP=1 \
      -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
  fi
  # PG17 changes the pg_stat_statements_reset signature. The PG16 function
  # grant cannot be replayed; PGV provisioning re-grants current public
  # functions to its application roles after cutover.
  docker exec -i "$name" pg_restore -l < "$work/db-$i.dump" > "$work/db-$i.list"
  grep -vF 'ACL public FUNCTION pg_stat_statements_reset(userid oid, dbid oid, queryid bigint)' \
    "$work/db-$i.list" > "$work/db-$i.filtered.list"
  docker cp "$work/db-$i.filtered.list" "$name:/tmp/db-$i.list"
  docker exec -i "$name" pg_restore -U "$migrator" --exit-on-error \
    -L "/tmp/db-$i.list" -d "$db" < "$work/db-$i.dump" > "$work/db-$i.log"
  docker exec "$name" psql -U "$migrator" -d "$db" -v ON_ERROR_STOP=1 \
    -Atqc 'SELECT count(*) FROM pg_class WHERE relkind IN ('\''r'\'','\''p'\'')' >/dev/null
done

if [[ -n "$TARGET_DATA_DIR" ]]; then
  echo "PG17 migration prepared for ${#databases[@]} databases; source unchanged; target=$TARGET_DATA_DIR backup=$work"
else
  echo "PG17 isolated restore passed for ${#databases[@]} databases; installed PG16 container and volume were not changed"
fi
