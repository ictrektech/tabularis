#!/usr/bin/env bash
set -euo pipefail

log() { echo "[postgres-provision] $*"; }

psql_super() {
  psql -v ON_ERROR_STOP=1 "$@"
}

wait_for_postgres() {
  for _ in $(seq 1 60); do
    if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "postgres did not become ready"
  return 1
}

create_role() {
  local role="$1"
  local password="$2"
  local superuser="${3:-false}"

  local role_exists
  role_exists=$(psql_super -d "$PGDATABASE" -v role="$role" -At <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'role';
SQL
)
  if [[ "$role_exists" == "1" ]]; then
    psql_super -d "$PGDATABASE" -v role="$role" -v password="$password" <<'SQL'
ALTER ROLE :"role" WITH LOGIN PASSWORD :'password';
SQL
  else
    psql_super -d "$PGDATABASE" -v role="$role" -v password="$password" <<'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'password';
SQL
  fi

  if [[ "$superuser" == "true" ]]; then
    psql_super -d "$PGDATABASE" -v role="$role" <<'SQL'
ALTER ROLE :"role" WITH SUPERUSER;
SQL
  else
    psql_super -d "$PGDATABASE" -v role="$role" <<'SQL'
ALTER ROLE :"role" WITH NOSUPERUSER;
SQL
  fi
}

create_database() {
  local db="$1"
  local owner="$2"

  local db_exists
  db_exists=$(psql_super -d "$PGDATABASE" -v db="$db" -At <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db';
SQL
)
  if [[ "$db_exists" != "1" ]]; then
    createdb -T template0 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -O "$owner" "$db"
  fi
  psql_super -d "$PGDATABASE" -v db="$db" -v owner="$owner" <<'SQL'
ALTER DATABASE :"db" OWNER TO :"owner";
GRANT ALL PRIVILEGES ON DATABASE :"db" TO :"owner";
SQL
}

grant_database_ownership() {
  local db="$1"
  local owner="$2"

  log "grant ownership and default privileges for ${owner} in ${db}"
  psql_super -d "$db" -v owner="$owner" <<'SQL'
ALTER SCHEMA public OWNER TO :"owner";
GRANT ALL ON SCHEMA public TO :"owner";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :"owner";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO :"owner";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO :"owner";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT ALL ON TABLES TO :"owner";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT ALL ON SEQUENCES TO :"owner";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT ALL ON FUNCTIONS TO :"owner";
SQL
}

create_extension_if_available() {
  local db="$1"
  local extension="$2"
  local required="${3:-false}"

  local extension_exists
  extension_exists=$(psql_super -d "$db" -v extension="$extension" -At <<'SQL'
SELECT 1 FROM pg_available_extensions WHERE name = :'extension';
SQL
)
  if [[ "$extension_exists" == "1" ]]; then
    log "create extension ${extension} in ${db}"
    psql_super -d "$db" -v extension="$extension" <<'SQL'
CREATE EXTENSION IF NOT EXISTS :"extension" CASCADE;
SQL
  elif [[ "$required" == "true" ]]; then
    log "required extension ${extension} is not available in ${db}"
    return 1
  else
    log "optional extension ${extension} is not available in ${db}; skip"
  fi
}

upgrade_pg_search() {
  local db="$1"
  log "verify pg_search and rebuild the BM25 index when required in ${db}"
  psql_super -d "$db" -v force_rebuild="${PGV_REBUILD_BM25:-false}" \
    -f "$(dirname "${BASH_SOURCE[0]}")/pg-search-upgrade.sql"
}

configure_weknora() {
  create_role "$WEKNORA_DB_USER" "$WEKNORA_DB_PASSWORD" false
  create_database "$WEKNORA_DB_NAME" "$WEKNORA_DB_USER"
  create_extension_if_available "$WEKNORA_DB_NAME" "uuid-ossp" false
  create_extension_if_available "$WEKNORA_DB_NAME" "vector" true
  create_extension_if_available "$WEKNORA_DB_NAME" "pg_trgm" false
  create_extension_if_available "$WEKNORA_DB_NAME" "pg_search" true
  upgrade_pg_search "$WEKNORA_DB_NAME"
  grant_database_ownership "$WEKNORA_DB_NAME" "$WEKNORA_DB_USER"
}

configure_immich() {
  create_role "$IMMICH_DB_USER" "$IMMICH_DB_PASSWORD" "$IMMICH_DB_SUPERUSER"
  create_database "$IMMICH_DB_NAME" "$IMMICH_DB_USER"
  create_extension_if_available "$IMMICH_DB_NAME" "uuid-ossp" false
  create_extension_if_available "$IMMICH_DB_NAME" "unaccent" false
  create_extension_if_available "$IMMICH_DB_NAME" "cube" false
  create_extension_if_available "$IMMICH_DB_NAME" "earthdistance" false
  create_extension_if_available "$IMMICH_DB_NAME" "pg_trgm" false
  create_extension_if_available "$IMMICH_DB_NAME" "vector" true
  create_extension_if_available "$IMMICH_DB_NAME" "vchord" false
  create_extension_if_available "$IMMICH_DB_NAME" "vectors" false
  grant_database_ownership "$IMMICH_DB_NAME" "$IMMICH_DB_USER"
  psql_super -d "$IMMICH_DB_NAME" -v db="$IMMICH_DB_NAME" <<'SQL' || true
ALTER DATABASE :"db" SET vchordrq.probes = 1;
SQL
}

configure_nowen() {
  create_role "$NOWEN_DB_USER" "$NOWEN_DB_PASSWORD" false
  create_database "$NOWEN_DB_NAME" "$NOWEN_DB_USER"
  create_extension_if_available "$NOWEN_DB_NAME" "uuid-ossp" false
  create_extension_if_available "$NOWEN_DB_NAME" "vector" true
  create_extension_if_available "$NOWEN_DB_NAME" "pg_trgm" false
  grant_database_ownership "$NOWEN_DB_NAME" "$NOWEN_DB_USER"
}

wait_for_postgres
configure_weknora
configure_immich
configure_nowen
log "done"
