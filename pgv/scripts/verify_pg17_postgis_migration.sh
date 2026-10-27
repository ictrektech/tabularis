#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
image= old_image=
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:?}"; shift 2 ;;
    --old-image) old_image="${2:?}"; shift 2 ;;
    *) echo 'Usage: verify_pg17_postgis_migration.sh --image PG17 --old-image PGV_0.0.33_IMAGE' >&2; exit 1 ;;
  esac
done
[[ -n "$image" && -n "$old_image" ]] || exit 1
# Catch extensions dropped between historical base images even if the sample
# database has not loaded them yet. This includes pg_ivm on the ARM legacy base.
python3 - "$old_image" "$image" <<'PY'
import subprocess, sys
def inventory(image, root, pattern):
    r = subprocess.run(['docker', 'run', '--rm', '--entrypoint', 'find', image,
                        root, '-maxdepth', '1', '-name', pattern, '-printf', '%f\n'],
                       capture_output=True, text=True, check=True)
    return set(r.stdout.splitlines())
for root, pattern in [('/usr/share/postgresql/16/extension', '*.control'),
                      ('/usr/lib/postgresql/16/lib', '*.so')]:
    missing = inventory(sys.argv[1], root, pattern) - inventory(sys.argv[2], root, pattern)
    if missing:
        raise SystemExit('Historical PG16 runtime files are missing: ' + ', '.join(sorted(missing)))
print('Historical PG16 extension/library inventory retained')
PY
build_root="${PGV_BUILD_ROOT:-$HOME/dev/build/pgv}"
mkdir -p "$build_root"
work="$(mktemp -d "$build_root/postgis-test-XXXXXXXX")"
old="pgv-postgis-old-$$"
new="pgv-postgis-new-$$"
cleanup() {
  docker rm -f "$old" "$new" >/dev/null 2>&1 || true
  # PGDATA is owned by the container's postgres user.
  docker run --rm -v "$work":/test --entrypoint sh "$image" -c 'rm -rf /test/storage /test/backups' >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
ready() {
  for _ in $(seq 1 90); do
    if [[ "$(docker exec "$1" ps -p 1 -o comm= 2>/dev/null || true)" == postgres ]] &&
       docker exec "$1" pg_isready -U postgres -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}
mkdir "$work/storage" "$work/backups"
chmod 0755 "$work/storage"
cat > "$work/migration.env" <<'ENV'
POSTGRES_USER=postgres
VOS_POSTGRES_PASSWORD=verify-postgis
ENV
docker run -d --name "$old" -e POSTGRES_PASSWORD=verify-postgis \
  -e PGDATA=/pgv-storage/data -v "$work/storage":/pgv-storage "$old_image" >/dev/null
ready "$old"
docker exec -i "$old" psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;
CREATE EXTENSION IF NOT EXISTS pg_ivm;
CREATE TABLE spatial_probe (id integer PRIMARY KEY, geom geometry(Point,4326), geog geography(Point,4326));
INSERT INTO spatial_probe VALUES (1, ST_SetSRID(ST_MakePoint(120,30),4326), ST_SetSRID(ST_MakePoint(120,30),4326)::geography);
CREATE INDEX spatial_probe_gist ON spatial_probe USING gist (geom);
CREATE TABLE raster_probe (id integer PRIMARY KEY, image raster);
INSERT INTO raster_probe VALUES (1, ST_AddBand(ST_MakeEmptyRaster(2,2,0,0,1,-1,0,0,4326),'8BUI'::text,42,0));
SELECT topology.CreateTopology('migration_topology',4326);
CREATE TABLE ivm_source (id integer PRIMARY KEY, value integer);
INSERT INTO ivm_source VALUES (1,42);
SELECT pgivm.create_immv('ivm_probe', 'SELECT id, value FROM ivm_source');
CREATE VIEW ivm_dependent AS SELECT value FROM ivm_probe;
SQL
docker exec -u postgres "$old" sh -c 'kill -INT 1'
docker wait "$old" >/dev/null
docker rm "$old" >/dev/null

# Recovery refuses a running process with access to the same storage.
docker run -d --name "$old" -v "$work/storage":/pgv-storage --entrypoint sleep "$image" 120 >/dev/null
if "$repo/scripts/migrate_pg16_storage.sh" --image "$image" --storage "$work/storage" \
  --env-file "$work/migration.env" --backup-root "$work/backups" > "$work/running-refusal.log" 2>&1; then
  echo 'Recovery unexpectedly accepted storage mounted by a running container' >&2; exit 1
fi
grep -q 'Storage is mounted by a running container' "$work/running-refusal.log"
docker rm -f "$old" >/dev/null

"$repo/scripts/migrate_pg16_storage.sh" --image "$image" --storage "$work/storage" \
  --env-file "$work/migration.env" --backup-root "$work/backups"
docker run --rm -v "$work":/test --entrypoint bash "$image" -ec '
  test "$(cat /test/storage/data/PG_VERSION)" = 17
  test "$(cat /test/storage/data-pg16-backup/PG_VERSION)" = 16
  for archive in /test/backups/pg16-*/data-pg16.tar; do
    cd "$(dirname "$archive")"
    sha256sum -c data-pg16.tar.sha256
    test "$(tar -xOf data-pg16.tar ./PG_VERSION)" = 16
  done
  test -n "$(find /test/storage/pgv-migration-backups -name backup-complete -print -quit)"
  test -z "$(find /test/storage/pgv-migration-backups -name "*.dump" -size 0 -print -quit)"
'
docker run -d --name "$new" -e PGDATA=/pgv-storage/data \
  -v "$work/storage":/pgv-storage "$image" \
  -c shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so >/dev/null
ready "$new"
# Simulate VOS retaining the old shared-preload setting. The migrated database
# must still load pg_ivm through its session setting and maintain its IMMVs.
[[ "$(docker exec "$new" psql -U postgres -Atqc 'SHOW session_preload_libraries')" == pg_ivm ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc "SELECT ST_AsText(geom) FROM spatial_probe WHERE id=1")" == 'POINT(120 30)' ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc "SELECT ST_DWithin(geog,geog,1) FROM spatial_probe")" == t ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc 'SELECT ST_Value(image,1,1,1) FROM raster_probe')" == 42 ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc "SELECT srid FROM topology.topology WHERE name='migration_topology'")" == 4326 ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc "SELECT count(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster','postgis_topology','postgis_sfcgal')")" == 4 ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc 'SELECT value FROM ivm_probe WHERE id=1')" == 42 ]]
docker exec "$new" psql -U postgres -v ON_ERROR_STOP=1 -c 'INSERT INTO ivm_source VALUES (2,84)' >/dev/null
[[ "$(docker exec "$new" psql -U postgres -Atqc 'SELECT value FROM ivm_probe WHERE id=2')" == 84 ]]
[[ "$(docker exec "$new" psql -U postgres -Atqc 'SELECT max(value) FROM ivm_dependent')" == 84 ]]
echo 'PGV 0.0.33 PostGIS spatial data, pg_ivm updates and offline recovery passed'
