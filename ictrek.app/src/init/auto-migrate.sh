#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Runs once before the PGV database service. The active data path is never
# replaced until a private PG17 restore and provisioning have both succeeded.
storage=/pgv-storage
active="$storage/data"
stage="$storage/data-pg17-staging"
legacy="$storage/data-pg16-backup"
archives="$storage/pgv-migration-backups"
cutover="$storage/.pgv-cutover-in-progress"
stage_owned="$storage/.pgv-stage-owned"
stage_ready="$storage/.pgv-stage-ready"
socket16=/tmp/pgv-migrate-pg16
socket17=/tmp/pgv-migrate-pg17
pg16=/usr/lib/postgresql/16/bin
pg17=/usr/lib/postgresql/17/bin
phase=detect
old_running=false
new_running=false

log() { echo "[pgv-migrate] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
version_at() { [[ -f "$1/PG_VERSION" ]] && cat "$1/PG_VERSION" || true; }

stop_server() {
  local bin="$1" dir="$2"
  gosu postgres "$bin/pg_ctl" -D "$dir" -m fast -w stop >/dev/null 2>&1 || true
}

on_exit() {
  local status=$?
  trap - EXIT
  [[ "$new_running" == false ]] || stop_server "$pg17" "$stage"
  [[ "$old_running" == false ]] || stop_server "$pg16" "$active"
  if [[ $status -ne 0 ]]; then
    # A failed rename must leave the old PG16 path usable by the old package.
    if [[ -f "$cutover" && ! -e "$active" && "$(version_at "$legacy")" == 16 ]]; then
      mv "$legacy" "$active" || true
      rm -f "$cutover" || true
    fi
    log "ERROR: automatic migration stopped during $phase; existing data retained; partial exports are not complete backups" >&2
  fi
  exit "$status"
}
trap on_exit EXIT

[[ -d "$storage" ]] || fail 'storage mount is missing'
[[ "$(id -u)" == 0 ]] || fail 'migration service must run as root'
exec 9>"$storage/.pgv-migration.lock"
flock -n 9 || fail 'another migration is already using this storage'
[[ -x "$pg16/postgres" && -x "$pg17/postgres" ]] || fail 'PG16 and PG17 binaries are required'
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

# Complete or undo a power interruption between the two same-filesystem moves.
if [[ -e "$cutover" ]]; then
  if [[ "$(version_at "$active")" == 17 && "$(version_at "$legacy")" == 16 ]]; then
    rm -f "$cutover" "$stage_owned" "$stage_ready"
    log 'previous PG17 cutover is complete'
    exit 0
  fi
  if [[ ! -e "$active" && "$(version_at "$legacy")" == 16 ]]; then
    if [[ "$(version_at "$stage")" == 17 && -f "$stage_ready" ]]; then
      mv "$stage" "$active"
      rm -f "$cutover" "$stage_owned" "$stage_ready"
      log 'completed interrupted PG17 cutover'
      exit 0
    fi
    mv "$legacy" "$active"
    rm -f "$cutover"
    log 'restored PG16 data after interrupted cutover; retrying migration'
  elif [[ "$(version_at "$active")" == 16 && ! -e "$legacy" ]]; then
    rm -f "$cutover"
  else
    fail 'ambiguous interrupted cutover; existing data was not changed'
  fi
fi

case "$(version_at "$active")" in
  17)
    rm -f "$stage_owned" "$stage_ready"
    log 'PG17 data detected; migration is unnecessary'
    exit 0
    ;;
  16) ;;
  '')
    [[ ! -e "$legacy" && ! -e "$stage" && ! -e "$stage_owned" ]] ||
      fail 'data path is missing while migration artifacts exist'
    [[ ! -e "$active" || ! -n "$(ls -A "$active")" ]] ||
      fail 'data path is nonempty but has no PG_VERSION'
    log 'new installation detected; PG17 will initialize normally'
    exit 0
    ;;
  *) fail 'unsupported or unreadable PostgreSQL data directory' ;;
esac

for key in WEKNORA_DB_NAME WEKNORA_DB_USER WEKNORA_DB_PASSWORD \
           IMMICH_DB_NAME IMMICH_DB_USER IMMICH_DB_PASSWORD \
           NOWEN_DB_NAME NOWEN_DB_USER NOWEN_DB_PASSWORD; do
  [[ -n "${!key:-}" ]] || fail "$key is required"
done

[[ ! -e "$legacy" ]] || fail 'a PG16 backup already exists; refusing to overwrite it'
[[ ! -f "$active/postmaster.pid" ]] || fail 'PG16 still has a postmaster.pid; refusing concurrent access'
# Administrator recovery can request an independent physical backup before
# even starting PG16. The normal installer retains its original PG16 directory.
if [[ -n "${PGV_OFFLINE_BACKUP_DIR:-}" ]]; then
  phase=offline-backup
  [[ -d "$PGV_OFFLINE_BACKUP_DIR" ]] || fail 'offline backup mount is missing'
  offline="$(mktemp -d "$PGV_OFFLINE_BACKUP_DIR/pg16-XXXXXXXX")"
  chmod 0700 "$offline"
  tar -cpf "$offline/data-pg16.tar.partial" -C "$active" .
  tar -tf "$offline/data-pg16.tar.partial" >/dev/null
  mv "$offline/data-pg16.tar.partial" "$offline/data-pg16.tar"
  (cd "$offline" && sha256sum data-pg16.tar > data-pg16.tar.sha256)
  log 'independent offline PG16 backup completed'
fi
# Existing VOS storage can expose the PostgreSQL directory as 0755 after the
# old container is removed. PostgreSQL itself requires 0700 or 0750.
chown postgres:postgres "$active"
chmod 0700 "$active"
if [[ -e "$stage" ]]; then
  [[ -f "$stage_owned" ]] || fail 'unknown PG17 staging directory; refusing to remove it'
  rm -rf -- "$stage"
fi
rm -f "$stage_owned" "$stage_ready"
install -d -m 700 -o postgres -g postgres "$archives"
work="$(mktemp -d "$archives/attempt-XXXXXXXX")"
chown postgres:postgres "$work"
install -d -m 700 -o postgres -g postgres "$socket16" "$socket17"

phase=start-pg16
log 'PG16 data detected; starting local read-only dump'
old_running=true
gosu postgres "$pg16/pg_ctl" -D "$active" -l "$work/pg16-server.log" \
  -o "-c listen_addresses='' -c unix_socket_directories=$socket16 -c port=5433 -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so,pg_ivm" \
  -w start > "$work/pg16-start.log" 2>&1
export PGHOST="$socket16" PGPORT=5433 PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD" PGDATABASE=postgres
"$pg16/psql" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" \
  > "$work/databases.txt"
mapfile -t databases < "$work/databases.txt"
[[ ${#databases[@]} -gt 0 ]] || fail 'PG16 contains no connectable databases'
printf '16\n' > "$work/source-major"
phase=extension-preflight
# Inspect the actual cluster, not the PGV app version: users can enable
# extensions independently of an app update. Do this before creating dumps.
for i in "${!databases[@]}"; do
  db="${databases[i]}"
  "$pg16/psql" -X -v ON_ERROR_STOP=1 -d "$db" -At -F $'\t' -c \
    'SELECT extname, extversion FROM pg_extension ORDER BY extname' \
    > "$work/extensions-$i.tsv"
  while IFS=$'\t' read -r extension extension_version; do
    [[ -s "/usr/share/postgresql/17/extension/$extension.control" ]] ||
      fail "database #$i requires unsupported PG17 extension $extension ($extension_version)"
  done < "$work/extensions-$i.tsv"
  "$pg16/psql" -X -v ON_ERROR_STOP=1 -d "$db" -Atqc \
    "SELECT DISTINCT probin FROM pg_proc WHERE prolang = (SELECT oid FROM pg_language WHERE lanname='c') ORDER BY probin" \
    > "$work/libraries-$i.txt"
  while IFS= read -r library; do
    case "$library" in
      '$libdir/'*) library="/usr/lib/postgresql/16/lib/${library#\$libdir/}" ;;
      /*) ;;
      *) continue ;;
    esac
    [[ -s "$library" || -s "$library.so" ]] ||
      fail "database #$i requires missing PG16 library $(basename "$library"); use a complete migration image"
  done < "$work/libraries-$i.txt"
done
phase=dump
if ! "$pg16/pg_dumpall" --globals-only > "$work/globals.sql.partial" 2> "$work/globals-dump.log"; then
  fail "PG16 role dump failed; see $work/globals-dump.log"
fi
[[ -s "$work/globals.sql.partial" ]] || fail 'PG16 role dump is empty'
mv "$work/globals.sql.partial" "$work/globals.sql"
for i in "${!databases[@]}"; do
  db="${databases[i]}"
  if grep -q $'^pg_ivm\t' "$work/extensions-$i.tsv"; then
    "$pg16/psql" -X -qAt -v ON_ERROR_STOP=1 -d "$db" \
      -f /init/pg-ivm-export.sql > "$work/pg-ivm-$i.sql.partial" 2> "$work/pg-ivm-$i.export.log"
    mv "$work/pg-ivm-$i.sql.partial" "$work/pg-ivm-$i.sql"
    "$pg16/psql" -X -At -v ON_ERROR_STOP=1 -d "$db" -c \
      'SELECT count(*) FROM pgivm.pg_ivm_immv' > "$work/pg-ivm-$i.count"
  fi
  "$pg16/psql" -X -v ON_ERROR_STOP=1 -v db="$db" -At <<'SQL' > "$work/owner-$i"
SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'db';
SQL
  "$pg16/psql" -X -v ON_ERROR_STOP=1 -d "$db" -Atqc \
    "SELECT count(*) FROM pg_extension WHERE extname IN ('vector','pg_search','vchord')" \
    > "$work/vector-$i"
  if ! "$pg16/pg_dump" -Fc -d "$db" -f "$work/db-$i.dump.partial" 2> "$work/db-$i.dump.log"; then
    fail "PG16 database #$i dump failed; see $work/db-$i.dump.log (partial files are not backups)"
  fi
  [[ -s "$work/db-$i.dump.partial" ]] || fail 'PG16 database dump is empty'
  "$pg17/pg_restore" -l "$work/db-$i.dump.partial" > "$work/db-$i.list"
  mv "$work/db-$i.dump.partial" "$work/db-$i.dump"
done
stop_server "$pg16" "$active"
old_running=false
touch "$work/backup-complete"

phase=restore
log "restoring ${#databases[@]} databases into an isolated PG17 directory"
install -d -m 700 -o postgres -g postgres "$stage"
touch "$stage_owned"
bootstrap="pgv_auto_$(date +%s)_$$"
openssl rand -hex 32 > "$work/bootstrap-password"
chown postgres:postgres "$work/bootstrap-password"
init_args=()
read -r -a init_args <<< "${POSTGRES_INITDB_ARGS:---data-checksums}"
gosu postgres "$pg17/initdb" -D "$stage" -U "$bootstrap" \
  --pwfile="$work/bootstrap-password" --auth-local=trust --auth-host=scram-sha-256 \
  "${init_args[@]}" > "$work/pg17-init.log" 2>&1
cp "$active/pg_hba.conf" "$active/pg_ident.conf" "$stage/"
chown postgres:postgres "$stage/pg_hba.conf" "$stage/pg_ident.conf"
new_running=true
gosu postgres "$pg17/pg_ctl" -D "$stage" -l "$work/pg17-server.log" \
  -o "-c listen_addresses=127.0.0.1 -c unix_socket_directories=$socket17 -c port=5434 -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so,pg_ivm" \
  -w start > "$work/pg17-start.log" 2>&1
export PGHOST="$socket17" PGPORT=5434 PGUSER="$bootstrap" PGDATABASE=postgres
export PGPASSWORD="$(cat "$work/bootstrap-password")"
"$pg17/psql" -X -v ON_ERROR_STOP=1 < "$work/globals.sql" > "$work/globals-restore.log" 2>&1
"$pg17/psql" -X -v ON_ERROR_STOP=1 -v role="$POSTGRES_USER" -d postgres <<'SQL' > "$work/superuser-password.log" 2>&1
\getenv password POSTGRES_PASSWORD
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'password') \gexec
SQL
for i in "${!databases[@]}"; do
  db="${databases[i]}"
  owner="$(cat "$work/owner-$i")"
  [[ -n "$owner" ]] || fail 'database owner lookup failed'
  if [[ "$db" == postgres ]]; then
    "$pg17/psql" -X -v ON_ERROR_STOP=1 -v owner="$owner" -d postgres <<'SQL' > "$work/create-$i.log" 2>&1
SELECT format('ALTER DATABASE postgres OWNER TO %I', :'owner') \gexec
SQL
  else
    "$pg17/createdb" -T template0 -O "$owner" "$db" > "$work/create-$i.log" 2>&1
  fi
  if [[ "$(cat "$work/vector-$i")" != 0 ]]; then
    "$pg17/psql" -X -v ON_ERROR_STOP=1 -d "$db" -c \
      'CREATE EXTENSION IF NOT EXISTS vector' > "$work/vector-restore-$i.log" 2>&1
  fi
  "$pg17/pg_restore" -l "$work/db-$i.dump" > "$work/db-$i.list"
  grep -vF 'ACL public FUNCTION pg_stat_statements_reset(userid oid, dbid oid, queryid bigint)' \
    "$work/db-$i.list" | grep -vE 'TABLE DATA pgivm pg_ivm_immv ' > "$work/db-$i.filtered.list"
  "$pg17/pg_restore" --exit-on-error -L "$work/db-$i.filtered.list" \
    -d "$db" "$work/db-$i.dump" > "$work/db-$i.restore.log" 2>&1
  if [[ -s "$work/pg-ivm-$i.sql" ]]; then
    "$pg17/psql" -X -v ON_ERROR_STOP=1 -d "$db" \
      -f "$work/pg-ivm-$i.sql" > "$work/pg-ivm-$i.restore.log" 2>&1
  fi
  if [[ -f "$work/pg-ivm-$i.count" ]]; then
    restored_immvs="$("$pg17/psql" -X -At -v ON_ERROR_STOP=1 -d "$db" -c 'SELECT count(*) FROM pgivm.pg_ivm_immv')"
    [[ "$restored_immvs" == "$(cat "$work/pg-ivm-$i.count")" ]] || fail "database #$i pg_ivm metadata count mismatch"
    if [[ "$restored_immvs" != 0 ]]; then
      # Old VOS configs can retain their previous shared_preload_libraries.
      # Database-level session preload keeps migrated IMMVs maintained there.
      "$pg17/psql" -X -v ON_ERROR_STOP=1 -v db="$db" -d "$db" <<'SQL' > "$work/pg-ivm-$i.preload.log" 2>&1
SELECT format('ALTER DATABASE %I SET session_preload_libraries = %L', :'db', 'pg_ivm') \gexec
SQL
    fi
  fi
done

phase=provision
# Validate the credentials and app-specific grants while PG17 is still private.
PGHOST=127.0.0.1 PGPORT=5434 PGUSER="$POSTGRES_USER" \
  PGPASSWORD="$POSTGRES_PASSWORD" PGDATABASE="$POSTGRES_DB" \
  bash /init/provision.sh > "$work/provision.log" 2>&1
phase=verify
PGHOST=127.0.0.1 PGPORT=5434 PGUSER="$POSTGRES_USER" \
  PGPASSWORD="$POSTGRES_PASSWORD" "$pg17/psql" -X -v ON_ERROR_STOP=1 \
  -d "$POSTGRES_DB" -Atqc 'SHOW server_version_num' \
  | grep -q '^17'
phase=retire-bootstrap
"$pg17/psql" -X -v ON_ERROR_STOP=1 -v role="$bootstrap" -d postgres <<'SQL' > "$work/disable-bootstrap.log" 2>&1
SELECT format('ALTER ROLE %I NOLOGIN PASSWORD NULL', :'role') \gexec
SQL
stop_server "$pg17" "$stage"
new_running=false

phase=cutover
touch "$stage_ready" "$cutover"
mv "$active" "$legacy"
mv "$stage" "$active"
rm -f "$cutover" "$stage_owned" "$stage_ready"
log "PG17 cutover complete; PG16 directory and protected dumps retained"
