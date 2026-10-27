#!/usr/bin/env bash
set -euo pipefail

IMG_NAME="pgv"
PG_MAJOR="17"
VCHORD_VERSION="0.4.3"
VECTORS_VERSION="0.3.0"
BUILD_ROOT="${PGV_BUILD_ROOT:-$HOME/dev/build/pgv}"
BUILD_CONTEXT="$BUILD_ROOT/context"

FEISHU_CONFIG_FILE="${FEISHU_CONFIG_FILE:-${HOME}/.feishu.json}"
FEISHU_SPREADSHEET_TOKEN="Htotsn3oahO1zxt73YMcaB1zn8e"
GITHUB_PROXY="${GITHUB_PROXY:-https://ghfast.top/}"

AMD_SHEETS=("AMD_with_cuda" "AMD_with_mxn100")
ARM_SHEETS=("ARM_without_cuda" "ARM_with_cuda" "l4t" "thor_spark" "SOPHON_bm1688")

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

platform_for_profile() {
  case "$1" in
    amd) echo "linux/amd64" ;;
    arm) echo "linux/arm64" ;;
    *) err "Unsupported profile: $1"; return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "missing command: $1"
    exit 1
  }
}

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

read_feishu_field() {
  local field="$1"
  python3 - "$FEISHU_CONFIG_FILE" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
val = data.get(field, "")
print(val if isinstance(val, str) else str(val))
PY
}

get_feishu_token() {
  local app_id="$1"
  local app_secret="$2"
  local resp

  resp=$(
    curl --fail -sS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
      -H "Content-Type: application/json" \
      -d "{\"app_id\":\"${app_id}\",\"app_secret\":\"${app_secret}\"}"
  ) || {
    err "get_feishu_token: curl failed"
    return 1
  }

  python3 - "$resp" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"get_feishu_token failed: {data}")
print(data["tenant_access_token"])
PY
}

feishu_api_json() {
  local method="$1"
  local url="$2"
  local token="$3"
  local body="${4:-}"

  if [[ -n "$body" ]]; then
    curl --fail -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl --fail -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}"
  fi
}

get_sheet_id_by_title() {
  local token="$1"
  local spreadsheet_token="$2"
  local target_title="$3"
  local resp

  resp=$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${spreadsheet_token}/sheets/query" \
    "$token")

  python3 - "$target_title" "$resp" <<'PY'
import json, sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"query sheets failed: {data}")
for sheet in data.get("data", {}).get("sheets", []):
    if sheet.get("title") == target:
        print(sheet["sheet_id"])
        raise SystemExit(0)
raise SystemExit(f"sheet title not found: {target}")
PY
}

get_range_values() {
  local token="$1"
  local spreadsheet_token="$2"
  local range="$3"

  feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${spreadsheet_token}/values/${range}" \
    "$token"
}

write_cell() {
  local token="$1"
  local spreadsheet_token="$2"
  local sheet_id="$3"
  local cell="$4"
  local value="$5"
  local resp

  resp=$(feishu_api_json "PUT" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${spreadsheet_token}/values" \
    "$token" \
    "{\"valueRange\":{\"range\":\"${sheet_id}!${cell}:${cell}\",\"values\":[[\"${value}\"]]}}")

  python3 - "$resp" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"write_cell failed: {data}")
print("ok")
PY
}

download_file() {
  local url="$1"
  local output="$2"
  local tmp="${output}.tmp"

  mkdir -p "$(dirname "$output")"
  curl --fail --silent --show-error -L --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 3 \
    "$url" -o "$tmp"
  mv "$tmp" "$output"
}

github_asset_url() {
  local url="$1"
  if [[ -n "$GITHUB_PROXY" ]]; then
    printf '%s%s\n' "$GITHUB_PROXY" "$url"
  else
    printf '%s\n' "$url"
  fi
}

prepare_vendor_assets() {
  local profile="$1"
  local deb_arch target_arch dir

  case "$profile" in
    amd)
      deb_arch="amd64"
      target_arch="amd64"
      ;;
    arm)
      deb_arch="arm64"
      target_arch="arm64"
      ;;
    *)
      err "Unsupported profile for vendor assets: $profile"
      exit 1
      ;;
  esac

  dir="$BUILD_CONTEXT/vendor/${target_arch}"
  mkdir -p "$dir"

  if [[ ! -f "${dir}/vchord-pg17.deb" ]]; then
    log "Downloading VectorChord ${VCHORD_VERSION} for ${deb_arch}"
    download_file \
      "$(github_asset_url "https://github.com/tensorchord/VectorChord/releases/download/${VCHORD_VERSION}/postgresql-17-vchord_${VCHORD_VERSION}-1_${deb_arch}.deb")" \
      "${dir}/vchord-pg17.deb"
  fi

  if [[ ! -f "${dir}/vectors-pg17.deb" ]]; then
    log "Downloading pgvecto.rs ${VECTORS_VERSION} for ${deb_arch}"
    download_file \
      "$(github_asset_url "https://github.com/tensorchord/pgvecto.rs/releases/download/v${VECTORS_VERSION}/vectors-pg17_${VECTORS_VERSION}_${deb_arch}_vectors.deb")" \
      "${dir}/vectors-pg17.deb"
  fi
}

find_component_column_letter() {
  local token="$1"
  local spreadsheet_token="$2"
  local sheet_id="$3"
  local component_name="$4"
  local resp result status value meta_resp column_count resp2 cell

  resp=$(get_range_values "$token" "$spreadsheet_token" "${sheet_id}!A1:ZZ2")
  result=$(python3 - "$component_name" "$resp" <<'PY'
import json, sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read header failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
rows = values[:2]
header = rows[0] if rows else []
repo = rows[1] if len(rows) > 1 else []

def text(v):
    if v is None:
        return ""
    if isinstance(v, str):
        return v.strip()
    if isinstance(v, dict):
        return str(v.get("text") or v.get("link") or "").strip()
    if isinstance(v, list):
        return "".join(text(x) for x in v).strip()
    return str(v).strip()

def col(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(ord("A") + r) + s
    return s

for i, v in enumerate(header, start=1):
    if text(v) == target:
        print(f"FOUND\t{col(i)}")
        raise SystemExit(0)
last = 1
for row in (header, repo):
    for i, v in enumerate(row, start=1):
        if text(v):
            last = max(last, i)
print(f"MISSING\t{last}")
PY
)

  status="${result%%$'\t'*}"
  value="${result#*$'\t'}"
  if [[ "$status" == "FOUND" ]]; then
    echo "$value"
    return 0
  fi
  [[ "$status" == "MISSING" ]] || {
    err "find_component_column_letter: unexpected result: $result"
    return 1
  }

  meta_resp=$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${spreadsheet_token}/sheets/query" \
    "$token")
  column_count=$(python3 - "$sheet_id" "$meta_resp" <<'PY'
import json, sys
sheet_id, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
for sheet in data.get("data", {}).get("sheets", []):
    if sheet.get("sheet_id") == sheet_id:
        print(sheet.get("grid_properties", {}).get("column_count", 0))
        raise SystemExit(0)
raise SystemExit(f"sheet id not found: {sheet_id}")
PY
)

  if (( value >= column_count )); then
    resp2=$(feishu_api_json "POST" \
      "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${spreadsheet_token}/dimension_range" \
      "$token" \
      "{\"dimension\":{\"sheetId\":\"${sheet_id}\",\"majorDimension\":\"COLUMNS\",\"length\":1}}")
  else
    resp2=$(feishu_api_json "POST" \
      "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${spreadsheet_token}/insert_dimension_range" \
      "$token" \
      "{\"dimension\":{\"sheetId\":\"${sheet_id}\",\"majorDimension\":\"COLUMNS\",\"startIndex\":${value},\"endIndex\":$((value + 1))},\"inheritStyle\":\"BEFORE\"}")
  fi
  python3 - "$resp2" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"add component column failed: {data}")
PY

  cell=$(python3 - "$value" <<'PY'
import sys
n = int(sys.argv[1]) + 1
s = ""
while n > 0:
    n, r = divmod(n - 1, 26)
    s = chr(ord("A") + r) + s
print(s)
PY
)
  write_cell "$token" "$spreadsheet_token" "$sheet_id" "${cell}1" "$component_name" >/dev/null
  echo "$cell"
}

find_date_row() {
  local token="$1"
  local spreadsheet_token="$2"
  local sheet_id="$3"
  local target_date="$4"
  local resp

  resp=$(get_range_values "$token" "$spreadsheet_token" "${sheet_id}!A4:A2000")
  python3 - "$target_date" "$resp" <<'PY'
import json, sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read date column failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
for idx, row in enumerate(values, start=4):
    if row and str(row[0]).strip() == target:
        print(idx)
        raise SystemExit(0)
print("")
PY
}

prepend_date_row() {
  local token="$1"
  local spreadsheet_token="$2"
  local sheet_id="$3"
  local today="$4"
  local resp

  resp=$(feishu_api_json "POST" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${spreadsheet_token}/values_prepend" \
    "$token" \
    "{\"valueRange\":{\"range\":\"${sheet_id}!A4:A4\",\"values\":[[\"${today}\"]]}}")
  python3 - "$resp" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"prepend_date_row failed: {data}")
print("ok")
PY
}

usage() {
  cat <<'EOF'
Usage:
  ./build_image.sh [amd|arm]
  ./build_image.sh --profile [amd|arm]
  ./build_image.sh arm --sheet ARM_without_cuda --build-only
  ./build_image.sh --sheet AMD_with_cuda
  ./build_image.sh --sheet l4t --sheet thor_spark

Supported sheets:
  AMD: AMD_with_cuda, AMD_with_mxn100
  ARM: ARM_without_cuda, ARM_with_cuda, l4t, thor_spark, SOPHON_bm1688
EOF
}

PROFILE=""
BUILD_ONLY=false
TARGET_SHEETS=()

if [[ -n "${PGV_RELEASE_SHEETS:-}" ]]; then
  IFS=',' read -r -a ENV_SHEETS <<< "${PGV_RELEASE_SHEETS}"
  for sheet in "${ENV_SHEETS[@]}"; do
    [[ -n "$sheet" ]] && TARGET_SHEETS+=("$sheet")
  done
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    amd|arm)
      PROFILE="$1"
      shift
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --sheet)
      TARGET_SHEETS+=("${2:-}")
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PROFILE" && ${#TARGET_SHEETS[@]} -gt 0 ]]; then
  if contains "${TARGET_SHEETS[0]}" "${AMD_SHEETS[@]}"; then
    PROFILE=amd
  elif contains "${TARGET_SHEETS[0]}" "${ARM_SHEETS[@]}"; then
    PROFILE=arm
  fi
fi

if [[ "$PROFILE" != "amd" && "$PROFILE" != "arm" ]]; then
  err "Unsupported profile: $PROFILE"
  usage
  exit 1
fi

if [[ "$PROFILE" == arm && "$BUILD_ONLY" == false && "${PGV_RELEASE_WITHOUT_PHYSICAL_ARM:-0}" != 1 ]]; then
  err "PG17 ARM publication is blocked until 64 KiB page compatibility and BM1688 are verified"
  err "Set PGV_RELEASE_WITHOUT_PHYSICAL_ARM=1 only for an explicitly authorized release before those physical tests"
  exit 1
fi

if [[ ${#TARGET_SHEETS[@]} -eq 0 ]]; then
  if [[ "$PROFILE" == "amd" ]]; then
    TARGET_SHEETS=("${AMD_SHEETS[@]}")
  else
    TARGET_SHEETS=("${ARM_SHEETS[@]}")
  fi
fi

for sheet in "${TARGET_SHEETS[@]}"; do
  if [[ "$PROFILE" == "amd" ]]; then
    contains "$sheet" "${AMD_SHEETS[@]}" || {
      err "Sheet ${sheet} is not valid for amd"
      exit 1
    }
  else
    contains "$sheet" "${ARM_SHEETS[@]}" || {
      err "Sheet ${sheet} is not valid for arm"
      exit 1
    }
  fi
done

DOCKERFILE="Dockerfile"
PLATFORM="$(platform_for_profile "$PROFILE")"
DATE="$(date +%Y%m%d)"
TAG="${PROFILE}_${PG_MAJOR}_${DATE}"
IMAGE_REPOSITORY="swr.cn-southwest-2.myhuaweicloud.com/ictrek/${IMG_NAME}"
IMAGE_URI="${IMAGE_REPOSITORY}:${TAG}"
BASE_IMAGE="${PGV_BASE_IMAGE:-swr.cn-southwest-2.myhuaweicloud.com/ictrek/paradedb:${PLATFORM#linux/}_0.25.11-pg17}"
OLD_TAG=amd_16_20261012
[[ "$PROFILE" != arm ]] || OLD_TAG=arm_16_20261012
LEGACY_IMAGE="${IMAGE_REPOSITORY}:${OLD_TAG}"
VCHORD_DEB="vendor/${PLATFORM#linux/}/vchord-pg17.deb"
VECTORS_DEB="vendor/${PLATFORM#linux/}/vectors-pg17.deb"

require_cmd curl
require_cmd python3
require_cmd docker

[[ -f "$DOCKERFILE" ]] || {
  err "Dockerfile not found: $DOCKERFILE"
  exit 1
}
if [[ "$BUILD_ONLY" == false ]]; then
  [[ -f "$FEISHU_CONFIG_FILE" ]] || {
    err "Feishu config not found: $FEISHU_CONFIG_FILE"
    exit 1
  }

  FEISHU_APP_ID="$(read_feishu_field "feishu_app_id")"
  FEISHU_APP_SECRET="$(read_feishu_field "feishu_app_secret")"
  [[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] || {
    err "feishu_app_id or feishu_app_secret missing in $FEISHU_CONFIG_FILE"
    exit 1
  }

fi

log "PROFILE=${PROFILE}"
log "PLATFORM=${PLATFORM}"
log "DOCKERFILE=${DOCKERFILE}"
log "TARGET_SHEETS=${TARGET_SHEETS[*]}"
log "IMG_NAME=${IMG_NAME}"
log "PG_MAJOR=${PG_MAJOR}"
log "TAG=${TAG}"
log "GITHUB_PROXY=${GITHUB_PROXY:-<none>}"

prepare_vendor_assets "$PROFILE"
if [[ "$PROFILE" == arm ]]; then
  require_cmd dpkg-deb
  portable="$BUILD_CONTEXT/vendor/arm64/vectors-portable-pg17.deb"
  [[ -f "$portable" ]] || {
    err "Portable PG17 ARM vectors package is missing: $portable"
    err "Build it with scripts/build_vectors_pg17_arm.sh on a suitable build host"
    exit 1
  }
  [[ "$(dpkg-deb -f "$portable" Package)" == vectors-pg17 &&
     "$(dpkg-deb -f "$portable" Version)" == 0.3.0+ictrek1 &&
     "$(dpkg-deb -f "$portable" Architecture)" == arm64 ]] || {
    err "Portable PG17 ARM vectors package metadata is invalid: $portable"
    exit 1
  }
  VECTORS_DEB="vendor/arm64/vectors-portable-pg17.deb"
fi

docker buildx build --load --provenance=false --sbom=false \
  --platform "${PLATFORM}" \
  --build-arg "TARGETARCH=${PLATFORM#linux/}" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "LEGACY_IMAGE=${LEGACY_IMAGE}" \
  --build-arg "VCHORD_DEB=${VCHORD_DEB}" \
  --build-arg "VECTORS_DEB=${VECTORS_DEB}" \
  -t "${IMG_NAME}" \
  -t "${IMAGE_URI}" \
  -f "${DOCKERFILE}" "$BUILD_CONTEXT"

./scripts/verify_pg17_migration.sh --image "$IMAGE_URI" --old-image "$LEGACY_IMAGE"
./scripts/verify_pg17_auto_migration.sh --image "$IMAGE_URI" --old-image "$LEGACY_IMAGE"
./scripts/verify_pg17_postgis_migration.sh --image "$IMAGE_URI" \
  --old-image "${PGV_POSTGIS_SOURCE_IMAGE:-${IMAGE_REPOSITORY}:${PROFILE}_16_20260717}"

if [[ "$BUILD_ONLY" == true ]]; then
  log "Candidate verified; not published: $IMAGE_URI"
  exit 0
fi

if [[ "$PROFILE" == arm && "${PGV_RELEASE_WITHOUT_PHYSICAL_ARM:-0}" == 1 ]]; then
  log 'ARM physical BM1688/64 KiB verification remains outstanding; publishing by explicit authorization'
fi

docker push "${IMAGE_URI}"
log "Docker push succeeded: ${IMAGE_URI}"

for sheet in "${TARGET_SHEETS[@]}"; do
  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  SHEET_ID="$(get_sheet_id_by_title "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$sheet")"
  log "Resolved sheet: ${sheet} -> ${SHEET_ID}"

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  COMPONENT_COL="$(find_component_column_letter "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "$IMG_NAME")"
  log "Resolved component column: ${IMG_NAME} -> ${COMPONENT_COL}"

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  write_cell "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "${COMPONENT_COL}1" "$IMG_NAME" >/dev/null
  write_cell "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "${COMPONENT_COL}2" "$IMAGE_REPOSITORY" >/dev/null

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  DATE_ROW="$(find_date_row "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "$DATE")"
  if [[ -z "$DATE_ROW" ]]; then
    log "Date ${DATE} not found, creating a new row at top of data area"
    FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
    prepend_date_row "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "$DATE" >/dev/null
    DATE_ROW=4
  else
    log "Date ${DATE} already exists at row ${DATE_ROW}"
  fi

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  write_cell "$FEISHU_TOKEN" "$FEISHU_SPREADSHEET_TOKEN" "$SHEET_ID" "${COMPONENT_COL}${DATE_ROW}" "$TAG" >/dev/null
  log "Feishu updated: ${sheet}!${COMPONENT_COL}${DATE_ROW} = ${TAG}"
done
