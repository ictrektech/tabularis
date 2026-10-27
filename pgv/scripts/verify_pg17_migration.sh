#!/usr/bin/env bash
set -euo pipefail

# Disposable PG16 -> PG17 logical restore. Never points at an installed volume.
IMAGE=""
OLD_IMAGE=""
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --old-image) OLD_IMAGE="${2:-}"; shift 2 ;;
    *) echo 'Usage: verify_pg17_migration.sh --image NEW --old-image PG16' >&2; exit 1 ;;
  esac
done
[[ -n "$IMAGE" && -n "$OLD_IMAGE" ]] || { echo 'Both images are required' >&2; exit 1; }

root="${PGV_TEST_WORKDIR:-$HOME/dev/build/pgv-migration-tests}"
mkdir -p "$root"
work="$(mktemp -d "$root/pgv-17-XXXXXX")"
old="pgv-16-test-$$"
new="pgv-17-test-$$"
old_volume="${old}-data"
new_volume="${new}-data"
cleanup() {
  docker rm -f "$old" "$new" >/dev/null 2>&1 || true
  docker volume rm "$old_volume" "$new_volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

ready() {
  local name="$1" user="$2"
  for _ in $(seq 1 90); do
    # pg_isready can report the entrypoint's temporary bootstrap server ready.
    if [[ "$(docker exec "$name" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
       docker exec "$name" pg_isready -U "$user" >/dev/null 2>&1; then return 0; fi
    if [[ "$(docker inspect -f '{{.State.Status}}' "$name")" == exited ]]; then
      docker logs "$name" >&2
      return 1
    fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}

docker volume create "$old_volume" >/dev/null
docker volume create "$new_volume" >/dev/null
docker run -d --name "$old" -e POSTGRES_PASSWORD=verify \
  -v "$old_volume":/var/lib/postgresql/data "$OLD_IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$old" postgres
[[ "$(docker exec "$old" psql -U postgres -Atqc 'SHOW server_version_num')" == 16* ]]

for db in WeKnora immich nowen_video; do
  docker exec "$old" createdb -T template0 -U postgres "$db"
done
docker exec -i "$old" psql -U postgres -d WeKnora -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION pg_search;
CREATE EXTENSION vector;
CREATE TABLE embeddings(id BIGINT PRIMARY KEY, content TEXT, embedding halfvec(3));
INSERT INTO embeddings VALUES(1,'migration portable document','[1,0,0]'),(2,'unrelated','[0,1,0]');
CREATE INDEX embeddings_search_idx ON embeddings USING bm25 (id, content) WITH (key_field='id', text_fields='{"content":{"tokenizer":{"type":"chinese_lindera"}}}');
CREATE INDEX embeddings_vector_idx ON embeddings USING hnsw (embedding halfvec_cosine_ops);
SQL
docker exec -i "$old" psql -U postgres -d immich -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION vectors;
CREATE EXTENSION vchord CASCADE;
CREATE TABLE smart_search(id BIGINT PRIMARY KEY, embedding vector(3));
INSERT INTO smart_search VALUES(1,'[1,0,0]'),(2,'[0,1,0]');
CREATE INDEX clip_index ON smart_search USING vchordrq (embedding vector_l2_ops);
CREATE TABLE legacy_vectors(id BIGINT PRIMARY KEY, embedding vectors.vector(3));
INSERT INTO legacy_vectors VALUES(1,'[1,0,0]');
SQL
docker exec -i "$old" psql -U postgres -d nowen_video -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION vector;
CREATE TABLE retained_data(id INT PRIMARY KEY, value TEXT);
INSERT INTO retained_data VALUES(1,'preserved');
SQL

# Restore globals and each database independently. pg_dumpall --clean tries
# to drop template1 while the new server is using it.
docker exec "$old" pg_dumpall -U postgres --globals-only > "$work/globals.sql"
for db in WeKnora immich nowen_video postgres; do
  docker exec "$old" pg_dump -U postgres -Fc -d "$db" > "$work/$db.dump"
done
docker stop -t 60 "$old" >/dev/null
docker run -d --name "$new" -e POSTGRES_USER=pgv_migrator \
  -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=pgv_migrator \
  -v "$new_volume":/var/lib/postgresql/data "$IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$new" pgv_migrator
docker exec -i "$new" psql -U pgv_migrator -d pgv_migrator -v ON_ERROR_STOP=1 \
  < "$work/globals.sql" > "$work/restore-globals.log"
for db in WeKnora immich nowen_video; do
  docker exec "$new" createdb -T template0 -U pgv_migrator -O postgres "$db"
  # pg_search 0.25.11 requires pgvector before CREATE EXTENSION pg_search;
  # the PG16 archive's extension order does not encode this new dependency.
  docker exec "$new" psql -U pgv_migrator -d "$db" -v ON_ERROR_STOP=1 \
    -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
  docker exec -i "$new" pg_restore -U pgv_migrator --exit-on-error \
    -d "$db" < "$work/$db.dump" > "$work/restore-$db.log"
done
docker exec "$new" psql -U pgv_migrator -d postgres -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
docker exec -i "$new" pg_restore -U pgv_migrator \
  --exit-on-error -d postgres < "$work/postgres.dump" > "$work/restore-postgres.log"
docker cp "$repo/ictrek.app/src/init" "$new":/init
docker exec -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGUSER=pgv_migrator \
  -e PGPASSWORD=verify -e PGDATABASE=pgv_migrator \
  -e WEKNORA_DB_NAME=WeKnora -e WEKNORA_DB_USER=weknora -e WEKNORA_DB_PASSWORD=verify \
  -e IMMICH_DB_NAME=immich -e IMMICH_DB_USER=immich -e IMMICH_DB_PASSWORD=verify \
  -e IMMICH_DB_SUPERUSER=true -e NOWEN_DB_NAME=nowen_video \
  -e NOWEN_DB_USER=nowen -e NOWEN_DB_PASSWORD=verify \
  "$new" bash /init/provision.sh > "$work/provision.log"

[[ "$(docker exec "$new" psql -U postgres -d WeKnora -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_search'")" == 0.25.11 ]]
[[ "$(docker exec "$new" psql -U postgres -d WeKnora -Atqc "SELECT count(*) FROM ictrek_pgv.maintenance WHERE name='bm25-0.25.11'")" == 1 ]]
[[ "$(docker exec "$new" psql -U postgres -d WeKnora -Atqc 'SELECT count(*) FROM embeddings')" == 2 ]]
[[ "$(docker exec "$new" psql -U postgres -d WeKnora -Atqc "SELECT id FROM embeddings WHERE content ||| 'portable'")" == 1 ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc "SELECT extversion FROM pg_extension WHERE extname='vchord'")" == 0.4.3 ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc "SELECT extversion FROM pg_extension WHERE extname='vectors'")" == 0.3.0 ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc 'SELECT count(*) FROM smart_search')" == 2 ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc 'SELECT count(*) FROM legacy_vectors')" == 1 ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc \
  "SELECT embedding OPERATOR(vectors.<->) '[0,1,0]'::vectors.vector FROM legacy_vectors WHERE id=1")" == 2 ]]
[[ "$(docker exec "$new" psql -U postgres -d nowen_video -Atqc 'SELECT value FROM retained_data WHERE id=1')" == preserved ]]
[[ "$(docker exec "$new" psql -U postgres -d immich -Atqc "SELECT bool_and(indisvalid) FROM pg_index WHERE indexrelid IN ('clip_index'::regclass)")" == t ]]

# A failed cutover can still start the untouched PG16 data volume.
docker rm -f "$old" >/dev/null 2>&1 || true
docker run -d --name "$old" -e POSTGRES_PASSWORD=verify \
  -v "$old_volume":/var/lib/postgresql/data "$OLD_IMAGE" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$old" postgres
[[ "$(docker exec "$old" psql -U postgres -d WeKnora -Atqc 'SELECT count(*) FROM embeddings')" == 2 ]]
echo 'PG16 -> PG17 fixture restore and PG16 rollback passed'
