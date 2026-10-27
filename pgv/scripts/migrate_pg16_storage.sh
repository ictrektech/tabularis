#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Administrator fallback. Uses the exact same migration implementation as VOS.
# It never stops containers or guesses the application's persistent data path.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image= storage= env_file= backup_root=
if [[ -f "$script_dir/init/auto-migrate.sh" ]]; then
  init_dir="$script_dir/init" # extracted VOS package
else
  init_dir="$script_dir/../ictrek.app/src/init" # source checkout
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:?}"; shift 2 ;;
    --storage) storage="${2:?}"; shift 2 ;;
    --env-file) env_file="${2:?}"; shift 2 ;;
    --backup-root) backup_root="${2:?}"; shift 2 ;;
    --init-dir) init_dir="${2:?}"; shift 2 ;;
    *) echo 'Usage: migrate_pg16_storage.sh --image FIXED_PGV_IMAGE --storage APP_STORAGE --env-file ENV --backup-root BACKUP_DIR [--init-dir INIT_DIR]' >&2; exit 1 ;;
  esac
done
[[ -n "$image" && -d "$storage" && -f "$env_file" && -n "$backup_root" && -f "$init_dir/auto-migrate.sh" ]] || {
  echo 'Image, existing application storage, environment file, backup directory and migration init files are required' >&2
  exit 1
}
storage="$(realpath "$storage")"
[[ "$storage" != / ]] || { echo 'Refusing root storage path' >&2; exit 1; }
source_major="$(docker run --rm --network none -v "$storage":/pgv-storage:ro \
  --entrypoint cat "$image" /pgv-storage/data/PG_VERSION 2>/dev/null)" || {
  echo 'No readable data/PG_VERSION; select the original application storage root' >&2
  exit 1
}
case "$source_major" in
  16) ;;
  17) echo 'PG17 is already active; no recovery migration or backup was performed'; exit 0 ;;
  *) echo "Unsupported PostgreSQL major: $source_major" >&2; exit 1 ;;
esac
mkdir -p "$backup_root"
backup_root="$(realpath "$backup_root")"
env_file="$(realpath "$env_file")"
init_dir="$(realpath "$init_dir")"
case "$backup_root/" in "$storage/"*) echo 'Backup directory must be outside application storage' >&2; exit 1 ;; esac

# A healthy container or another app mounting the same cluster must be stopped
# by its owner before this recovery command runs. Do not expose its environment.
python3 - "$storage" <<'PY'
import json, os, subprocess, sys
storage = sys.argv[1]
ids = subprocess.check_output(['docker', 'ps', '-q'], text=True).split()
if ids:
    containers = json.loads(subprocess.check_output(['docker', 'inspect', *ids]))
    for container in containers:
        command = [container.get('Path', ''), *container.get('Args', [])]
        postgres = any(os.path.basename(arg) in ('postgres', 'postmaster') for arg in command)
        for mount in container.get('Mounts', []):
            source = os.path.realpath(mount.get('Source', ''))
            common = os.path.commonpath([storage, source])
            # Broad platform mounts (e.g. /share) do not make VOS itself a
            # database process. Exact storage/data mounts always block.
            if common == storage or (common == source and postgres):
                raise SystemExit('Storage is mounted by a running container; stop the application before recovery')
PY

docker run --rm --network none --env-file "$env_file" \
  -e PGV_OFFLINE_BACKUP_DIR=/pgv-offline-backup \
  -v "$storage":/pgv-storage -v "$backup_root":/pgv-offline-backup \
  -v "$init_dir":/init:ro --entrypoint /bin/bash "$image" -ec '
  export POSTGRES_USER="${POSTGRES_USER:-${POSTGRES_SUPERUSER:-postgres}}"
  export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${VOS_POSTGRES_PASSWORD:-}}"
  export POSTGRES_DB="${POSTGRES_DB:-postgres}"
  export WEKNORA_DB_NAME="${WEKNORA_DB_NAME:-WeKnora}" WEKNORA_DB_USER="${WEKNORA_DB_USER:-weknora}" WEKNORA_DB_PASSWORD="${WEKNORA_DB_PASSWORD:-weknora}"
  export IMMICH_DB_NAME="${IMMICH_DB_NAME:-immich}" IMMICH_DB_USER="${IMMICH_DB_USER:-immich}" IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-immich}" IMMICH_DB_SUPERUSER="${IMMICH_DB_SUPERUSER:-true}"
  export NOWEN_DB_NAME="${NOWEN_DB_NAME:-nowen_video}" NOWEN_DB_USER="${NOWEN_DB_USER:-nowen}" NOWEN_DB_PASSWORD="${NOWEN_DB_PASSWORD:-nowen_password}"
  exec bash /init/auto-migrate.sh
  '
echo 'Migration completed. Keep the independent archive, original PG16 directory and protected dumps until the application is verified.'
