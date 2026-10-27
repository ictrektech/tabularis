#!/usr/bin/env bash
set -euo pipefail

# Isolated PG16 old-volume upgrade gate. No installed app or user volume is used.
IMAGE=""
OLD_IMAGE=""
PULL_OLD_IMAGE=true
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="pgv-upgrade-verify-$$"
VOLUME="${NAME}-data"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --old-image) OLD_IMAGE="$2"; shift 2 ;;
    --local-old-image) PULL_OLD_IMAGE=false; shift ;;
    *) echo 'Usage: verify_pg_search_upgrade.sh --image NEW --old-image OLD' >&2; exit 1 ;;
  esac
done
[[ -n "$IMAGE" && -n "$OLD_IMAGE" ]]
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
start() {
  docker run -d --name "$NAME" -e POSTGRES_PASSWORD=verify \
    -v "$VOLUME":/var/lib/postgresql/data -v "$ROOT/ictrek.app/src/init":/init:ro \
    "$1" -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
  for _ in $(seq 1 90); do
    if docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; then return; fi
    if [[ "$(docker inspect -f '{{.State.Status}}' "$NAME")" == exited ]]; then
      docker logs "$NAME" >&2; return 1
    fi
    sleep 1
  done
  docker logs "$NAME" >&2; return 1
}
sql() {
  local input=()
  [[ $# -gt 0 ]] || input=(-i)
  docker exec "${input[@]}" "$NAME" psql -U postgres -d WeKnora -v ON_ERROR_STOP=1 -At "$@"
}
provision() {
  docker exec -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGUSER=postgres \
    -e PGPASSWORD=verify -e PGDATABASE=postgres \
    -e WEKNORA_DB_NAME=WeKnora -e WEKNORA_DB_USER=weknora -e WEKNORA_DB_PASSWORD=verify \
    -e IMMICH_DB_NAME=immich -e IMMICH_DB_USER=immich -e IMMICH_DB_PASSWORD=verify \
    -e IMMICH_DB_SUPERUSER=true -e NOWEN_DB_NAME=nowen_video \
    -e NOWEN_DB_USER=nowen -e NOWEN_DB_PASSWORD=verify \
    "$NAME" bash /init/provision.sh
}
if [[ "$PULL_OLD_IMAGE" == true ]]; then
  docker pull "$OLD_IMAGE" >/dev/null
fi
docker volume create "$VOLUME" >/dev/null
start "$OLD_IMAGE"
docker exec "$NAME" createdb -T template0 -U postgres WeKnora
sql <<'SQL'
CREATE EXTENSION pg_search;
CREATE ROLE weknora LOGIN NOSUPERUSER;
CREATE EXTENSION vector;
CREATE TABLE embeddings (
 id SERIAL PRIMARY KEY, content TEXT, knowledge_id TEXT, knowledge_base_id TEXT,
 chunk_id TEXT, is_enabled BOOLEAN, embedding halfvec(3),
 created_at TIMESTAMPTZ DEFAULT now(), updated_at TIMESTAMPTZ DEFAULT now(),
 source_id TEXT, source_type INT DEFAULT 0, dimension INT DEFAULT 3, tag_id TEXT
);
INSERT INTO embeddings(content, knowledge_id, knowledge_base_id, chunk_id, is_enabled, embedding)
 SELECT 'portable search 中文检索 ' || repeat('document ', 80), 'doc-' || (i / 1000), 'kb', i::text,
        i % 2 = 1, '[1,0,0]' FROM generate_series(1,10553) i;
CREATE INDEX embeddings_search_idx ON embeddings USING bm25
 (id, knowledge_base_id, content, knowledge_id, chunk_id)
 WITH (key_field='id', text_fields='{"content":{"tokenizer":{"type":"chinese_lindera"}}}');
UPDATE embeddings SET source_id=id::text;
CREATE UNIQUE INDEX embeddings_unique_source ON embeddings(source_id, source_type);
CREATE INDEX embeddings_vector_idx ON embeddings USING hnsw (embedding halfvec_cosine_ops);
CREATE TABLE retained_data(id INT PRIMARY KEY, value TEXT);
INSERT INTO retained_data VALUES (1, 'must survive upgrade');
SQL
for db in immich nowen_video; do
  docker exec "$NAME" createdb -T template0 -U postgres "$db"
  docker exec "$NAME" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -c \
    "CREATE EXTENSION vector; CREATE TABLE vector_probe(id INT PRIMARY KEY, embedding vector(3)); INSERT INTO vector_probe VALUES (1,'[1,0,0]');"
done
[[ "$(sql -c "SELECT extversion FROM pg_extension WHERE extname='pg_search'")" == 0.22.2 ]]
old_index="$(sql -c "SELECT relfilenode FROM pg_class WHERE oid='embeddings_search_idx'::regclass")"
docker stop -t 60 "$NAME" >/dev/null
docker rm "$NAME" >/dev/null
start "$IMAGE"
if [[ -n "${HYBRAG_PG_MIGRATION_SQL:-}" ]]; then
  docker cp "$HYBRAG_PG_MIGRATION_SQL" "$NAME":/tmp/hybrag-pg-search-migration.sql
  docker exec "$NAME" psql -U weknora -d WeKnora -v ON_ERROR_STOP=1 -f /tmp/hybrag-pg-search-migration.sql
  [[ "$(sql -c "SELECT extversion FROM pg_extension WHERE extname='pg_search'")" == 0.22.2 ]]
fi
provision
[[ "$(sql -c "SELECT extversion FROM pg_extension WHERE extname='pg_search'")" == 0.22.6 ]]
[[ "$(sql -c 'SELECT count(*) FROM embeddings')" == 10553 ]]
[[ "$(sql -c 'SELECT value FROM retained_data WHERE id=1')" == 'must survive upgrade' ]]
new_index="$(sql -c "SELECT relfilenode FROM pg_class WHERE oid='embeddings_search_idx'::regclass")"
[[ "$new_index" != "$old_index" ]]
provision
[[ "$(sql -c "SELECT relfilenode FROM pg_class WHERE oid='embeddings_search_idx'::regclass")" == "$new_index" ]]
# A blocked rebuild must fail without marking repair complete.
marker="$(sql -c "SELECT completed_at FROM ictrek_pgv.maintenance WHERE name='bm25-0.22.6'")"
sql -c "BEGIN; LOCK TABLE embeddings IN ROW EXCLUSIVE MODE; SELECT pg_sleep(20); COMMIT;" >/dev/null &
locker=$!
for _ in $(seq 1 30); do
  [[ "$(sql -c "SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%LOCK TABLE embeddings%' AND wait_event='PgSleep'")" != 0 ]] && break
  sleep 1
done
if docker exec "$NAME" psql -U postgres -d WeKnora -v ON_ERROR_STOP=1 \
  -v force_rebuild=true -f /init/pg-search-upgrade.sql; then
  echo 'blocked REINDEX unexpectedly succeeded' >&2; exit 1
fi
wait "$locker"
[[ "$(sql -c "SELECT completed_at FROM ictrek_pgv.maintenance WHERE name='bm25-0.22.6'")" == "$marker" ]]
[[ "$(sql -c "SELECT relfilenode FROM pg_class WHERE oid='embeddings_search_idx'::regclass")" == "$new_index" ]]
# Explicit repair remains available even after the one-time upgrade marker.
docker exec "$NAME" psql -U postgres -d WeKnora -v ON_ERROR_STOP=1 \
  -v force_rebuild=true -f /init/pg-search-upgrade.sql
[[ "$(sql -c "SELECT relfilenode FROM pg_class WHERE oid='embeddings_search_idx'::regclass")" != "$new_index" ]]
heap_size_before="$(sql -c "SELECT pg_relation_size('embeddings')")"
sql <<'SQL'
DELETE FROM embeddings WHERE id > 553;
VACUUM (TRUNCATE ON, ANALYZE) embeddings;
SELECT id, paradedb.score(id) FROM embeddings
 WHERE content ||| 'portable' AND (is_enabled IS NULL OR is_enabled=true)
   AND knowledge_base_id='kb' ORDER BY paradedb.score(id) DESC LIMIT 5;
SELECT id FROM embeddings ORDER BY embedding <=> '[1,0,0]'::halfvec LIMIT 5;
INSERT INTO embeddings(content, knowledge_id, knowledge_base_id, chunk_id, is_enabled, embedding)
 VALUES ('portable reprocessed document', 'reprocessed', 'kb', 'new', true, '[0,1,0]');
DO $$ BEGIN
 IF (SELECT count(*) FROM embeddings) <> 554 OR
    NOT EXISTS (SELECT 1 FROM embeddings WHERE content ||| 'reprocessed' AND is_enabled=true) THEN
   RAISE EXCEPTION 'delete/VACUUM/reingestion verification failed';
 END IF;
END $$;
SQL
[[ "$(sql -c "SELECT pg_relation_size('embeddings')")" -lt "$heap_size_before" ]]
if [[ -n "${HYBRAG_PG_TEST_BIN:-}" ]]; then
  dict_dir="${HYBRAG_PG_TEST_DICT_DIR:-$(dirname "$HYBRAG_PG_TEST_BIN")/jieba-dict}"
  [[ -f "$dict_dir/jieba.dict.utf8" ]]
  docker cp "$dict_dir" "$NAME":/tmp/jieba-dict
  docker cp "$HYBRAG_PG_TEST_BIN" "$NAME":/tmp/hybrag-postgres.test
  docker exec -e JIEBA_DICT_DIR=/tmp/jieba-dict -e HYBRAG_POSTGRES_TEST_DSN="host=127.0.0.1 port=5432 user=weknora password=verify dbname=WeKnora sslmode=disable" \
    "$NAME" /tmp/hybrag-postgres.test -test.v -test.run TestPGVBM25Integration
fi
for db in immich nowen_video; do
  [[ "$(docker exec "$NAME" psql -U postgres -d "$db" -Atc "SELECT embedding::text FROM vector_probe WHERE id=1")" == '[1,0,0]' ]]
  docker exec "$NAME" psql -U "$([[ "$db" == immich ]] && echo immich || echo nowen)" -d "$db" -v ON_ERROR_STOP=1 -c \
    "INSERT INTO vector_probe VALUES (2,'[0,1,0]'); SELECT embedding <-> '[0,1,0]'::vector FROM vector_probe ORDER BY id;"
done
docker exec "$NAME" psql -U postgres -d immich -Atc \
  "SELECT extname || ':' || extversion FROM pg_extension WHERE extname IN ('vector','vectors','vchord');"
[[ "$(docker inspect -f '{{.State.Status}}' "$NAME")" == running ]]
echo "PG16 old-volume upgrade, rebuild, idempotency, delete/VACUUM, retrieval and shared extensions passed: $IMAGE"
