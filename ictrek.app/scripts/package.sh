#!/usr/bin/env bash
set -euo pipefail

APP_NAME="pgv"
APP_ID="com.ictrek.pgv"
ROUTER_PAGE_ID="pgv"
ROUTER_IFRAME_SRC="/app/com.ictrek.pgv/"
ROUTER_HASH_PATH="#/app/com.ictrek.pgv/pgv"
FRONTEND_BASE_PATH="/app/com.ictrek.pgv"
SPREADSHEET_TOKEN="${FEISHU_SPREADSHEET_TOKEN:-Htotsn3oahO1zxt73YMcaB1zn8e}"
FEISHU_CONFIG_FILE="${FEISHU_CONFIG_FILE:-${HOME}/.feishu.components.json}"
FEISHU_FALLBACK_CONFIG_FILE="${FEISHU_FALLBACK_CONFIG_FILE:-${HOME}/.feishu.json}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/src"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="${DIST_DIR}/staging"
PACKAGE_ROOT="${DIST_DIR}/package-root"
VERSION_FILE="${ROOT_DIR}/VERSION"
LOCK_DIR="${DIST_DIR}/.package.lock"

PROFILES=(
  "arm|ARM_without_cuda"
  "amd|AMD_with_cuda"
)
COMPONENTS=(
  "TABULARIS|tabularis|swr.cn-southwest-2.myhuaweicloud.com/ictrek/tabularis"
  "POSTGRES|pgv|swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv"
)

# Reuse the same published SWR base images as HybRAG.
BASE_IMAGES=(
  "REDIS_AMD_IMAGE=swr.cn-southwest-2.myhuaweicloud.com/ictrek/redis:7.0-alpine"
  "REDIS_ARM_IMAGE=swr.cn-southwest-2.myhuaweicloud.com/ictrek-arm/redis:7.0-alpine"
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package.sh

This builds one VOS app tarball for all supported Docker Compose profiles.
The package is always pull mode: it contains app.tar.gz only, writes image
names into app.tar.gz/.env, and never embeds docker image archives.
EOF
}

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 1
  done
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

read_version() {
  [[ -f "$VERSION_FILE" ]] || echo "0.0.0" > "$VERSION_FILE"
  tr -d '[:space:]' < "$VERSION_FILE"
}

read_feishu_field() {
  local config_file="$1"
  local field="$2"
  python3 - "$config_file" "$field" <<'PYJSON'
import json
import sys
path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
val = data.get(field, "")
print(val if isinstance(val, str) else str(val))
PYJSON
}

feishu_api_json() {
  local method="$1"
  local url="$2"
  local token="$3"
  curl --fail -sS -X "$method" "$url" -H "Authorization: Bearer ${token}"
}

get_feishu_token() {
  local app_id="$1"
  local app_secret="$2"
  local resp
  resp="$(
    curl --fail -sS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
      -H "Content-Type: application/json" \
      -d "{\"app_id\":\"${app_id}\",\"app_secret\":\"${app_secret}\"}"
  )"
  python3 - "$resp" <<'PYJSON'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"get_feishu_token failed: {data}")
print(data["tenant_access_token"])
PYJSON
}

get_sheet_id_by_title() {
  local token="$1"
  local target_title="$2"
  local resp
  resp="$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${SPREADSHEET_TOKEN}/sheets/query" \
    "$token")"
  python3 - "$target_title" "$resp" <<'PYJSON'
import json
import sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"query sheets failed: {data}")
for sheet in data.get("data", {}).get("sheets", []):
    if sheet.get("title") == target:
        print(sheet["sheet_id"])
        raise SystemExit(0)
raise SystemExit(f"sheet title not found: {target}")
PYJSON
}

get_range_values() {
  local token="$1"
  local range="$2"
  feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${SPREADSHEET_TOKEN}/values/${range}" \
    "$token"
}

find_component_column_letter() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local resp
  resp="$(get_range_values "$token" "${sheet_id}!A1:ZZ1")"
  python3 - "$component" "$resp" <<'PYJSON'
import json
import sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read header failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
row = values[0] if values else []

def text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        return str(value.get("text") or value.get("link") or "").strip()
    if isinstance(value, list):
        return "".join(text(v) for v in value).strip()
    return str(value).strip()

def col(num):
    out = ""
    while num > 0:
        num, rem = divmod(num - 1, 26)
        out = chr(ord("A") + rem) + out
    return out

for index, value in enumerate(row, start=1):
    if text(value) == target:
        print(col(index))
        raise SystemExit(0)
raise SystemExit(f"component column not found in row1: {target}")
PYJSON
}

find_latest_tag() {
  local token="$1"
  local sheet_id="$2"
  local column="$3"
  local resp
  resp="$(get_range_values "$token" "${sheet_id}!${column}4:${column}2000")"
  python3 - "$resp" <<'PYJSON'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"read version column failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
for row in values:
    if not row:
        continue
    value = row[0]
    if value is None:
        continue
    text = str(value).strip()
    if text:
        print(text)
        raise SystemExit(0)
raise SystemExit("latest version not found")
PYJSON
}

latest_image() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local repository="$4"
  local column tag
  column="$(find_component_column_letter "$token" "$sheet_id" "$component")" || return 1
  tag="$(find_latest_tag "$token" "$sheet_id" "$column")" || return 1
  [[ -n "$tag" ]] || return 1
  echo "${repository}:${tag}"
}

load_feishu_auth() {
  local config_file tried=""
  for config_file in "$FEISHU_CONFIG_FILE" "$FEISHU_FALLBACK_CONFIG_FILE"; do
    [[ -n "$config_file" && "$tried" != *"|$config_file|"* ]] || continue
    tried="${tried}|${config_file}|"
    [[ -r "$config_file" ]] || { log "Skip unreadable Feishu config: ${config_file}"; continue; }
    log "Read component versions with Feishu config: ${config_file}"
    if FEISHU_APP_ID="$(read_feishu_field "$config_file" "feishu_app_id")" \
      && FEISHU_APP_SECRET="$(read_feishu_field "$config_file" "feishu_app_secret")" \
      && [[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] \
      && FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"; then
      return 0
    fi
    log "Cannot read Feishu auth from ${config_file}; trying fallback"
  done
  die "failed to read Feishu credentials"
}

render_text_file() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" "$APP_VERSION" <<'PYRENDER'
import sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text(encoding="utf-8").replace("__APP_VERSION__", sys.argv[3])
dst.write_text(text, encoding="utf-8")
PYRENDER
}

render_compose_file() {
  local src="$1"
  local dst="$2"
  local env_file="$3"
  python3 - "$src" "$dst" "$APP_VERSION" "$env_file" <<'PYRENDER'
import re
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
version, env_path = sys.argv[3], Path(sys.argv[4])
env = {}
for line in env_path.read_text(encoding="utf-8").splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    env[key] = value

text = src.read_text(encoding="utf-8").replace("__APP_VERSION__", version)

def replace_image_var(match):
    key = match.group(1)
    if key.endswith("_IMAGE") and key in env:
        return env[key]
    return match.group(0)

text = re.sub(r"\$\{([A-Z0-9_]+)(?::-[^}]*)?\}", replace_image_var, text)
dst.write_text(text, encoding="utf-8")
PYRENDER
}

validate_icon_file() {
  local file="$1"
  python3 - "$file" <<'PYICON' || die "icon.png validation failed"
import struct
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 33 or data[12:16] != b"IHDR":
    raise SystemExit("icon.png must be a valid PNG file")
width, height, bit_depth, color_type = struct.unpack(">IIBB", data[16:26])
if (width, height) != (256, 256):
    raise SystemExit(f"icon.png must be 256x256, got {width}x{height}")
if bit_depth != 8 or color_type not in (4, 6):
    raise SystemExit("icon.png must be 8-bit with an alpha channel")
PYICON
}

verify_package() {
  local package_path="$1"
  local app_tarball="$2"
  local package_text
  local archive_files
  local manifest_text
  local routers_text
  local compose_text
  local sidebar_route
  log "Verify app.tar.gz contents"
  archive_files="$(tar tzf "$app_tarball")"
  printf '%s\n' "$archive_files" | grep -x "manifest.yml" >/dev/null
  printf '%s\n' "$archive_files" | grep -x "icon.png" >/dev/null
  for required in recover-pg16.sh init/auto-migrate.sh init/pg-ivm-export.sql init/provision.sh; do
    printf '%s\n' "$archive_files" | grep -Fx "$required" >/dev/null || die "missing migration/recovery file: $required"
  done
  tar tf "$package_path" | grep -qx "app.tar.gz"
  ! tar tf "$package_path" | grep -q "^assets/"
  package_text="$(for file in .env manifest.yml docker-compose.yml configs.yml routers.yml README.zh-CN.md README.en.md; do
    printf '%s\n' "$archive_files" | grep -x "$file" >/dev/null || continue
    tar xOf "$app_tarball" "$file"
    printf '\n'
  done)"
  if printf '%s' "$package_text" | grep -q '__[A-Z0-9_]\+__'; then
    die "unrendered placeholder remains"
  fi
  manifest_text="$(tar xOf "$app_tarball" manifest.yml)"
  if ! printf '%s\n' "$manifest_text" | grep -Fq 'icon: icon.png'; then
    die "manifest.yml must declare icon: icon.png"
  fi
  if ! printf '%s\n' "$manifest_text" | grep -q '^[[:space:]]*frontend:[[:space:]]*$'; then
    die "manifest.yml must declare frontend for VOS open button compatibility"
  fi
  if ! printf '%s\n' "$manifest_text" | grep -q '^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$'; then
    die "manifest.yml frontend.enabled must be true"
  fi
  if ! printf '%s\n' "$manifest_text" | grep -Fq "  basePath: ${FRONTEND_BASE_PATH}"; then
    die "manifest.yml frontend.basePath must be ${FRONTEND_BASE_PATH}"
  fi
  compose_text="$(tar xOf "$app_tarball" docker-compose.yml)"
  if printf '%s\n' "$compose_text" | grep -q '\${[^}]*_IMAGE[^}]*}'; then
    die "unrendered image variable remains in docker-compose.yml"
  fi
  if printf '%s\n' "$compose_text" | awk '/^[[:space:]]*image:/ {print $2}' | grep -v '^[^/[:space:]]\+\.[^/[:space:]]\+/' | grep -q .; then
    die "docker-compose.yml contains short image reference"
  fi
  if printf '%s\n' "$compose_text" | grep -Eq '^[[:space:]]{2}postgres:([[:space:]]*|$)|^[[:space:]]*container_name:[[:space:]]*postgres[[:space:]]*$|^[[:space:]]*-[[:space:]]*postgres[[:space:]]*$|^[[:space:]]*PGHOST:[[:space:]]*postgres[[:space:]]*$'; then
    die "docker-compose.yml must not expose PGV as bare postgres on vos_default"
  fi
  if ! printf '%s\n' "$compose_text" | grep -Fq 'PGHOST: pgv'; then
    die "docker-compose.yml provision service must connect through PGV alias pgv"
  fi
  if ! printf '%s\n' "$compose_text" | grep -Fq 'HeadersRegexp(`Sec-Fetch-Dest`, `document`)'; then
    die "docker-compose.yml must redirect top-level document opens to VOS hash route"
  fi
  if ! printf '%s\n' "$compose_text" | grep -Fq "${ROUTER_HASH_PATH}"; then
    die "docker-compose.yml redirect must target ${ROUTER_HASH_PATH}"
  fi
  routers_text="$(tar xOf "$app_tarball" routers.yml)"
  if ! printf '%s\n' "$routers_text" | grep -Fq "  - id: ${ROUTER_PAGE_ID}"; then
    die "routers.yml must declare top-level page id ${ROUTER_PAGE_ID}"
  fi
  if ! printf '%s\n' "$routers_text" | grep -Fq "    iframe-src: ${ROUTER_IFRAME_SRC}"; then
    die "routers.yml sidebar iframe-src must be ${ROUTER_IFRAME_SRC}"
  fi
  if printf '%s\n' "$routers_text" | grep -Eq 'iframe-src:[[:space:]]*https?://'; then
    die "routers.yml iframe-src must use a VOS same-origin /app/<app-id>/ path"
  fi
  if ! printf '%s\n' "$routers_text" | grep -q 'entry-point:[[:space:]]*true'; then
    die "routers.yml sidebar page must declare entry-point: true"
  fi
  if ! printf '%s\n' "$routers_text" | grep -q 'embed:[[:space:]]*true'; then
    die "routers.yml must declare embed: true for sidebar iframe"
  fi
  sidebar_route="#/app/${APP_ID}/${ROUTER_PAGE_ID}"
  log "VOS sidebar route: ${sidebar_route}"
}


env_key() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -c 'A-Z0-9_' '_'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-source)
      [[ "${2:-}" == "pull" ]] || die "only pull mode is supported"
      shift 2
      ;;
    --platform|--profile)
      die "platform/profile is selected during VOS install; package.sh now creates one tarball for all profiles"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd curl
require_cmd python3
require_cmd tar
mkdir -p "$DIST_DIR"
acquire_lock

if [[ -n "${PACKAGE_VERSION:-}" ]]; then
  [[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid PACKAGE_VERSION: $PACKAGE_VERSION"
  APP_VERSION="$PACKAGE_VERSION"
else
  APP_VERSION="$(read_version)"
fi
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid VERSION: $APP_VERSION"
log "Package version: ${APP_VERSION}"
log "Image source: pull"
load_feishu_auth

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ENV_FILE="${STAGE_DIR}/.env"
printf '%s\n' "${BASE_IMAGES[@]}" > "$ENV_FILE"
for profile_spec in "${PROFILES[@]}"; do
  IFS='|' read -r profile sheet_title <<< "$profile_spec"
  sheet_title="${sheet_title:-$profile}"
  profile_key="$(env_key "$profile")"
  for component_spec in "${COMPONENTS[@]}"; do
    IFS='|' read -r env_prefix component repository <<< "$component_spec"
    image=""
    IFS=',' read -ra candidate_sheets <<< "$sheet_title"
    for candidate_sheet in "${candidate_sheets[@]}"; do
      sheet_id="$(get_sheet_id_by_title "$FEISHU_TOKEN" "$candidate_sheet")"
      if image="$(latest_image "$FEISHU_TOKEN" "$sheet_id" "$component" "$repository")"; then
        log "$profile ($candidate_sheet) $component -> $image"
        break
      fi
      log "$profile cannot read $component from $candidate_sheet; trying fallback"
    done
    [[ -n "$image" ]] || die "failed to resolve image for profile=$profile component=$component sheets=$sheet_title"
    printf '%s_%s_IMAGE=%s
' "$env_prefix" "$profile_key" "$image" >> "$ENV_FILE"
  done
done

for file in manifest.yml configs.yml routers.yml README.zh-CN.md README.en.md; do
  if [[ -f "${SRC_DIR}/${file}" ]]; then
    render_text_file "${SRC_DIR}/${file}" "${STAGE_DIR}/${file}"
  fi
done
render_compose_file "${SRC_DIR}/docker-compose.yml" "${STAGE_DIR}/docker-compose.yml" "$ENV_FILE"
cp "${SRC_DIR}/icon.png" "${STAGE_DIR}/icon.png"
validate_icon_file "${STAGE_DIR}/icon.png"
if [[ -d "${SRC_DIR}/init" ]]; then
  cp -R "${SRC_DIR}/init" "${STAGE_DIR}/init"
fi
cp "${ROOT_DIR}/../pgv/scripts/migrate_pg16_storage.sh" "${STAGE_DIR}/recover-pg16.sh"

APP_TARBALL="${DIST_DIR}/app.tar.gz"
PACKAGE_NAME="${APP_NAME}_${APP_VERSION}_pull.tar"
PACKAGE_PATH="${DIST_DIR}/${PACKAGE_NAME}"

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
TAR_FILES=(.env manifest.yml docker-compose.yml configs.yml routers.yml icon.png README.zh-CN.md)
[[ -f "${STAGE_DIR}/README.en.md" ]] && TAR_FILES+=(README.en.md)
[[ -d "${STAGE_DIR}/init" ]] && TAR_FILES+=(init)
TAR_FILES+=(recover-pg16.sh)
tar czf "$APP_TARBALL" -C "$STAGE_DIR" "${TAR_FILES[@]}"
cp "$APP_TARBALL" "${PACKAGE_ROOT}/app.tar.gz"
tar cf "$PACKAGE_PATH" -C "$PACKAGE_ROOT" app.tar.gz
verify_package "$PACKAGE_PATH" "$APP_TARBALL"

log "Done: ${PACKAGE_PATH}"
