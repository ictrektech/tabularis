#!/usr/bin/env bash
set -euo pipefail

# Run on a native ARM builder. Snapshot dependencies avoid Git on build hosts.
VERSION=0.22.6
BUILD_ROOT="${PG_SEARCH_BUILD_ROOT:-$HOME/dev/build/pgsearch-0226}"
TOOLCHAIN_ROOT="${PG_SEARCH_TOOLCHAIN_ROOT:-$HOME/dev/build/pgsearch-host}"
PG_CONFIG="$TOOLCHAIN_ROOT/pg16/bin/pg_config"
[[ -x "$PG_CONFIG" && -x "$TOOLCHAIN_ROOT/cargo/bin/cargo-pgrx" ]]
BASE_IMAGE=swr.cn-southwest-2.myhuaweicloud.com/ictrek/postgres:arm64_16.13-bookworm
OUTPUT="${1:-vendor/arm64/pg_search-portable.tar.gz}"
[[ "$(uname -m)" == aarch64 ]]
mkdir -p "$BUILD_ROOT" "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
fetch() {
  local repo="$1" ref="$2" dir="$3"
  if [[ ! -f "$BUILD_ROOT/$(basename "$dir").tar.gz" ]]; then
    curl -fsSL --max-time 600 --retry 3 "https://codeload.github.com/$repo/tar.gz/$ref" -o "$BUILD_ROOT/$(basename "$dir").tar.gz"
  fi
  mkdir -p "$dir"
  tar -xzf "$BUILD_ROOT/$(basename "$dir").tar.gz" --strip-components=1 -C "$dir"
}
fetch paradedb/paradedb "refs/tags/v$VERSION" "$BUILD_ROOT/source"
fetch paradedb/tantivy 6338e83a36f947d37aaa602cc57b253ec1c5d652 "$BUILD_ROOT/tantivy"
fetch paradedb/fst 11e89334c578f26f9fbafbd1122ffb220ebbdbbf "$BUILD_ROOT/fst"
fetch apache/datafusion d24faa0134b75ea3a17fff94c2a271d858ef88e2 "$BUILD_ROOT/datafusion"
python3 - "$BUILD_ROOT" <<'PY'
from pathlib import Path
import re, sys, tomllib
root = Path(sys.argv[1])
packages = {}
for folder in ('source', 'tantivy', 'fst', 'datafusion'):
    for manifest in (root/folder).rglob('Cargo.toml'):
        package = tomllib.loads(manifest.read_text()).get('package', {})
        if isinstance(package.get('name'), str):
            packages[package['name']] = manifest.parent
for folder in ('source', 'tantivy', 'fst', 'datafusion'):
    for manifest in (root/folder).rglob('Cargo.toml'):
        def snapshot(match):
            name, body = match.groups()
            package = re.search(r'package\s*=\s*"([^"]+)"', body)
            name = package[1] if package else name
            if name not in packages:
                # Unused tooling in dependency workspaces is outside the root lock.
                if folder != 'source':
                    return match[0]
                raise SystemExit(f'No pinned archive for Git dependency {name}')
            body = re.sub(r'(?:git|rev|branch|tag)\s*=\s*"[^"]+"\s*,?\s*', '', body)
            body = body.strip().strip(',').strip()
            suffix = ', ' + body if body else ''
            return f'{match[1]} = {{ path = "{packages[name]}"{suffix} }}'
        text = re.sub(r'([\w-]+)\s*=\s*\{([^}]*\bgit\s*=\s*"[^}]+)\}', snapshot, manifest.read_text())
        manifest.write_text(text)
PY

# Reuse native toolchain/PG16 headers inside the same mirrored runtime base.
# This keeps the library glibc-compatible with the final PGV ARM image.
docker run --rm -i --network host \
  -e PG_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT" \
  -v "$TOOLCHAIN_ROOT":"$TOOLCHAIN_ROOT" \
  -v "$HOME/.rustup/toolchains":/toolchains:ro \
  -v "$BUILD_ROOT":"$BUILD_ROOT" -w "$BUILD_ROOT/source" \
  "$BASE_IMAGE" bash -s <<'BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -f /etc/apt/sources.list.d/pgdg.list
apt-get -o Acquire::http::Timeout=30 -o Acquire::Retries=2 update -qq
apt-get install -y -qq build-essential clang rustfmt pkg-config libssl-dev ca-certificates
export PATH="/toolchains/stable-aarch64-unknown-linux-gnu/bin:$PG_TOOLCHAIN_ROOT/cargo/bin:$PATH"
export CARGO_HOME="$PG_TOOLCHAIN_ROOT/cargo"
export PGRX_HOME="$PG_TOOLCHAIN_ROOT/pgrx-home"
export RUSTFLAGS='-C target-cpu=generic'
export LIBCLANG_PATH="$(dirname "$(find /usr/lib -name 'libclang-*.so.1' -print -quit)")"
export CARGO_BUILD_JOBS=12
mkdir -p "$PGRX_HOME"
cargo pgrx init --pg16="$PG_TOOLCHAIN_ROOT/pg16/bin/pg_config"
cargo --config 'source.crates-io.replace-with="rsproxy"' \
  --config 'source.rsproxy.registry="sparse+https://rsproxy.cn/index/"' \
  pgrx package --package pg_search --pg-config "$PG_TOOLCHAIN_ROOT/pg16/bin/pg_config"
BUILD
PG_PREFIX="$("$PG_CONFIG" --bindir)"
PACKAGE="$BUILD_ROOT/source/target/release/pg_search-pg16${PG_PREFIX%/bin}"
[[ -f "$PACKAGE/lib/postgresql/pg_search.so" ]]
grep -q "default_version = '0.22.6'" "$PACKAGE/share/postgresql/extension/pg_search.control"
tar -czf "$OUTPUT" -C "$PACKAGE" lib/postgresql/pg_search.so share/postgresql/extension
sha256sum "$OUTPUT"
