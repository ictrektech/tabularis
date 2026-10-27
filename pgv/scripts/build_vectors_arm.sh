#!/usr/bin/env bash
set -euo pipefail

# Build a portable pgvecto.rs 0.3.0 package for ARM64 Linux pages. Upstream's arm64 package
# makes tikv-jemallocator the process allocator; jemalloc rejects 64 KiB pages.
# This script uses the system allocator instead and produces the same PG16 deb
# layout consumed by the PGV Dockerfile.

PGVECTORS_REF="4360cac6f80762323fb882c10c747cb7372f793c" # pgvecto.rs v0.3.0
PGRX_REF="6a89f963209e9d4ed18d2fb868b8d2e967421785" # v0.12.0-alpha.1-patch3
PG_MAJOR="16"
SEMVER="0.3.0+ictrek1"
OUTPUT="vendor/arm64/vectors-portable.deb"
BUILD_ROOT="${PGVECTORS_BUILD_ROOT:-$HOME/dev/build/pgv-pgvectors-arm}"
RUST_TOOLCHAIN="nightly-2024-05-22"
CARGO_HOME="${PGVECTORS_CARGO_HOME:-$BUILD_ROOT/cargo}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/build_vectors_arm.sh [--output vendor/arm64/vectors-portable.deb]

Downloads pinned source archives, removes pgvecto.rs's global jemalloc allocator and builds a portable PG16 arm64
Debian package. Run this on the unified ARM build host; use a 64 KiB host only
for runtime verification.
USAGE
}

log() { echo "[INFO] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$(uname -m)" =~ ^(aarch64|arm64)$ ]] || die "must run on an ARM64 build host"
for command in curl tar python3 rustup cargo dpkg zip; do require_cmd "$command"; done

mkdir -p "$BUILD_ROOT" "$CARGO_HOME" "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
SOURCE_DIR="$BUILD_ROOT/pgvecto-rs-$PGVECTORS_REF"
PGRX_DIR="$BUILD_ROOT/pgrx-$PGRX_REF"

fetch_source() {
  local name="$1" ref="$2" dir="$3"
  [[ -d "$dir" ]] && return
  local archive="$BUILD_ROOT/$name-$ref.tar.gz"
  log "Download $name@$ref"
  curl --fail --location --retry 3 --connect-timeout 20 \
    "https://codeload.github.com/tensorchord/$name/tar.gz/$ref" -o "$archive"
  mkdir -p "$dir"
  tar -xzf "$archive" --strip-components=1 -C "$dir"
}

fetch_source "pgvecto.rs" "$PGVECTORS_REF" "$SOURCE_DIR"
fetch_source "pgrx" "$PGRX_REF" "$PGRX_DIR"

if ! rustup toolchain list | awk '{print $1}' | grep -qx "${RUST_TOOLCHAIN}-aarch64-unknown-linux-gnu"; then
  log "Install Rust $RUST_TOOLCHAIN"
  RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://rsproxy.cn}" \
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
fi

# Keep the upstream source immutable in the cache; construct a fresh work tree
# for every binary so a failed build cannot contaminate the next release.
WORK_DIR="$BUILD_ROOT/work-$SEMVER"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -a "$SOURCE_DIR/." "$WORK_DIR/"

python3 - "$WORK_DIR" "$PGRX_DIR" <<'PY'
from pathlib import Path
import sys
work, pgrx = map(Path, sys.argv[1:])
lib = work / "src/lib.rs"
text = lib.read_text()
needle = "#[global_allocator]\nstatic GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;\n\n"
if needle not in text:
    raise SystemExit("expected upstream jemalloc allocator declaration is missing")
lib.write_text(text.replace(needle, ""))

cargo = work / "Cargo.toml"
text = cargo.read_text()
needle = 'tikv-jemallocator = { version = "0.5.4", features = [\n    "disable_initial_exec_tls",\n] }\n'
if needle not in text:
    raise SystemExit("expected upstream tikv-jemallocator dependency is missing")
text = text.replace(needle, "")
needle = 'pgrx = { git = "https://github.com/tensorchord/pgrx.git", branch = "v0.12.0-alpha.1-patch3" }'
if needle not in text:
    raise SystemExit("expected upstream pgrx patch declaration is missing")
cargo.write_text(text.replace(needle, f'pgrx = {{ path = "{pgrx}/pgrx" }}'))
PY

# pgvecto.rs hard-codes clang-16 for one small C support library. The standard
# ARM builder may only expose cc; a private compatibility shim keeps host
# package state untouched.
TOOL_BIN="$WORK_DIR/tool-bin"
mkdir -p "$TOOL_BIN"
cat > "$TOOL_BIN/clang-16" <<'SH'
#!/usr/bin/env bash
exec cc "$@"
SH
chmod 755 "$TOOL_BIN/clang-16"

PGRX_HOME="$WORK_DIR/pgrx-home"
BINDING_DIR="$WORK_DIR/pgrx-bindings"
mkdir -p "$PGRX_HOME" "$BINDING_DIR"
cat > "$WORK_DIR/pg_config" <<EOFPG
#!/usr/bin/env bash
"$WORK_DIR/tools/pg_config.sh" "\$@" < "$WORK_DIR/vendor/pg_config/pg16_aarch64-unknown-linux-gnu.txt"
EOFPG
chmod 755 "$WORK_DIR/pg_config"
printf 'configs.pg16="%s"\n' "$WORK_DIR/pg_config" > "$PGRX_HOME/config.toml"
cp "$WORK_DIR/vendor/pgrx_binding/pg16_aarch64-unknown-linux-gnu.rs" "$BINDING_DIR/pg16_raw_bindings.rs"

export PATH="$TOOL_BIN:$PATH"
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
export CARGO_HOME PGRX_HOME
export PGRX_TARGET_INFO_PATH_PG16="$BINDING_DIR"
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

if [[ ! -f "$CARGO_HOME/config.toml" ]]; then
  cat > "$CARGO_HOME/config.toml" <<'EOFCONFIG'
[source.crates-io]
replace-with = "rsproxy"
[source.rsproxy]
registry = "sparse+https://rsproxy.cn/index/"
EOFCONFIG
fi

cd "$WORK_DIR"
cargo build --lib --features "pg$PG_MAJOR" --release --target aarch64-unknown-linux-gnu
# Schema generation executes a helper binary. The build is native ARM64, so use
# the host helper and expose the target library at the path it expects; this
# avoids a QEMU dependency on the unified builder.
mkdir -p ./target/release
ln -sfn ../aarch64-unknown-linux-gnu/release/libvectors.so ./target/release/libvectors.so
./tools/schema.sh --features "pg$PG_MAJOR" --release \
  | expand -t 4 > "./target/vectors--$SEMVER.sql"
SEMVER="$SEMVER" VERSION="$PG_MAJOR" ARCH=aarch64 PLATFORM=arm64 ./scripts/package.sh
cp "./build/vectors-pg${PG_MAJOR}_${SEMVER}_arm64.deb" "$OUTPUT"
sha256sum "$OUTPUT"
log "Built $OUTPUT"
