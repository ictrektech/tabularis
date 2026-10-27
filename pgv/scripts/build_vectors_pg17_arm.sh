#!/usr/bin/env bash
set -euo pipefail

# Rebuild only vectors.so without its process-wide jemalloc allocator. Keep the
# official PG17 vectors 0.3.0 control and SQL files so restored databases see
# the same extension contract.
SOURCE_REF=cc4776fec025672f934e3be6dfb2e27f930bef6d
PGRX_REF=1fd3d1544c2f9ac68ec0c6e293fd2de398b6d3d7
RUST_TOOLCHAIN=nightly-2025-01-01
BUILD_ROOT="${PGVECTORS_BUILD_ROOT:-$HOME/dev/build/pgv-pgvectors-pg17-arm}"
CARGO_HOME="${PGVECTORS_CARGO_HOME:-$BUILD_ROOT/cargo}"
UPSTREAM_DEB="${PGVECTORS_UPSTREAM_DEB:-$HOME/dev/build/pgv/context/vendor/arm64/vectors-pg17.deb}"
OUTPUT="${PGVECTORS_OUTPUT:-$HOME/dev/build/pgv/context/vendor/arm64/vectors-portable-pg17.deb}"

die() { echo "[ERROR] $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for command in curl tar python3 rustup cargo dpkg-deb md5sum; do require "$command"; done
case "$(uname -m)" in
  aarch64) ;;
  x86_64) require aarch64-linux-gnu-gcc ;;
  *) die 'build on ARM64 or an x86_64 host with the ARM64 cross-compiler' ;;
esac
[[ -f "$UPSTREAM_DEB" ]] || die "upstream package is missing: $UPSTREAM_DEB"
[[ "$(dpkg-deb -f "$UPSTREAM_DEB" Package)" == vectors-pg17 ]] || die 'unexpected upstream package'
[[ "$(dpkg-deb -f "$UPSTREAM_DEB" Version)" == 0.3.0 ]] || die 'upstream vectors version must be 0.3.0'
[[ "$(dpkg-deb -f "$UPSTREAM_DEB" Architecture)" == arm64 ]] || die 'upstream package must be ARM64'

mkdir -p "$BUILD_ROOT" "$CARGO_HOME" "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
if [[ ! -f "$CARGO_HOME/config.toml" ]]; then
  cat > "$CARGO_HOME/config.toml" <<'EOFCONFIG'
[source.crates-io]
replace-with = "rsproxy"
[source.rsproxy]
registry = "sparse+https://rsproxy.cn/index/"
EOFCONFIG
fi

fetch_source() {
  local repository="$1" ref="$2" destination="$3"
  local archive="$BUILD_ROOT/${repository}-${ref}.tar.gz"
  [[ -d "$destination" ]] && return
  if [[ ! -f "$archive" ]]; then
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
      "https://codeload.github.com/tensorchord/${repository}/tar.gz/${ref}" \
      -o "${archive}.tmp"
    mv "${archive}.tmp" "$archive"
  fi
  local temporary
  temporary="$(mktemp -d "$BUILD_ROOT/source-XXXXXXXX")"
  tar -xzf "$archive" --strip-components=1 -C "$temporary"
  mv "$temporary" "$destination"
}

source_dir="$BUILD_ROOT/pgvecto-${SOURCE_REF}"
pgrx_dir="$BUILD_ROOT/pgrx-${PGRX_REF}"
fetch_source pgvecto.rs "$SOURCE_REF" "$source_dir"
fetch_source pgrx "$PGRX_REF" "$pgrx_dir"

export RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://rsproxy.cn}"
export RUSTUP_NO_SELF_UPDATE=1
if ! rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}-"; then
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
fi
rustup target add aarch64-unknown-linux-gnu --toolchain "$RUST_TOOLCHAIN" >/dev/null
rustup component add rustfmt --toolchain "$RUST_TOOLCHAIN" >/dev/null

work="$BUILD_ROOT/work"
rm -rf "$work"
mkdir -p "$work"
cp -a "$source_dir/." "$work/"
python3 - "$work" "$pgrx_dir" <<'PY'
from pathlib import Path
import sys

work, pgrx = map(Path, sys.argv[1:])
lib = work / "src/lib.rs"
source = lib.read_text()
allocator = '''#[cfg(target_os = "linux")]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;
'''
if allocator not in source:
    raise SystemExit("expected upstream allocator declaration is missing")
lib.write_text(source.replace(allocator, ""))

cargo = work / "Cargo.toml"
source = cargo.read_text()
dependency = '''[target.'cfg(target_os = "linux")'.dependencies]
tikv-jemallocator = { version = "0.6.0", features = [
    "disable_initial_exec_tls",
] }
'''
patch = 'pgrx = { git = "https://github.com/tensorchord/pgrx.git", branch = "v0.12.5-patch" }'
if dependency not in source or patch not in source:
    raise SystemExit("expected upstream Cargo dependencies are missing")
source = source.replace(dependency, "")
cargo.write_text(source.replace(patch, f'pgrx = {{ path = "{pgrx}/pgrx" }}'))
PY

export CARGO_HOME
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
export PGRX_PG_CONFIG_PATH="$work/vendor/pg17_aarch64_debian/pg_config/pg_config"
export PGRX_TARGET_INFO_PATH_PG17="$work/vendor/pg17_aarch64_debian/pgrx_binding"
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
export CARGO_TARGET_DIR="$BUILD_ROOT/target"
if [[ "$(uname -m)" == x86_64 ]]; then
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$(command -v aarch64-linux-gnu-gcc)"
  export CC_aarch64_unknown_linux_gnu="$CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER"
fi
cd "$work"
cargo build --package pgvectors --lib --features pg17 \
  --target aarch64-unknown-linux-gnu --release --jobs 2

package="$BUILD_ROOT/package"
rm -rf "$package"
mkdir -p "$package"
dpkg-deb -R "$UPSTREAM_DEB" "$package"
sql="$package/usr/share/postgresql/17/extension/vectors--0.3.0.sql"
[[ "$(sha256sum "$sql" | cut -d ' ' -f 1)" == d92337b1991f4834841ca8b35b456aa00c5ba45e9746aa502a757949d4ecb1e4 ]] ||
  die 'upstream vectors SQL differs from the verified 0.3.0 package'
install -m 755 "$CARGO_TARGET_DIR/aarch64-unknown-linux-gnu/release/libvectors.so" \
  "$package/usr/lib/postgresql/17/lib/vectors.so"
python3 - "$package/DEBIAN/control" <<'PY'
from pathlib import Path
import sys
control = Path(sys.argv[1])
source = control.read_text()
if "Version: 0.3.0\n" not in source:
    raise SystemExit("unexpected upstream package version")
control.write_text(source.replace("Version: 0.3.0\n", "Version: 0.3.0+ictrek1\n"))
PY
(cd "$package" && find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
dpkg-deb -Zxz --build "$package" "$OUTPUT"
[[ "$(dpkg-deb -f "$OUTPUT" Version)" == 0.3.0+ictrek1 ]] || die 'package version mismatch'
echo "Portable PG17 vectors package: $OUTPUT"
sha256sum "$OUTPUT"
