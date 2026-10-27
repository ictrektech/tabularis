#!/usr/bin/env bash
# Unified source build; unchanged PGV images can be reused by selecting tabularis only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHEET=""; IMAGES=tabularis; BUILD_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sheet) SHEET="$2"; shift 2 ;;
    --images) IMAGES="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=true; shift ;;
    -h|--help) echo 'build_image.sh --sheet AMD_with_cuda|ARM_without_cuda --images tabularis[,pgv] [--build-only]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$SHEET" in
  AMD_with_cuda|AMD_with_mxn100) PROFILE=amd; PLATFORM=linux/amd64 ;;
  ARM_without_cuda|ARM_with_cuda|l4t|thor_spark|SOPHON_bm1688) PROFILE=arm; PLATFORM=linux/arm64 ;;
  *) echo 'An explicit supported --sheet is required' >&2; exit 1 ;;
esac
BUILD_ROOT="${TABULARIS_BUILD_ROOT:-$HOME/dev/build/tabularis}"
mkdir -p "$BUILD_ROOT/context"
IFS=, read -ra SELECTED <<< "$IMAGES"
for component in "${SELECTED[@]}"; do
  case "$component" in
    pgv)
      args=(--profile "$PROFILE" --sheet "$SHEET")
      [[ "$BUILD_ONLY" != true ]] || args+=(--build-only)
      (cd "$ROOT/pgv" && ./build_image.sh "${args[@]}") ;;
    tabularis)
      rsync -a --delete --exclude .git --exclude .gitnexus --exclude node_modules --exclude ictrek.app/dist "$ROOT/" "$BUILD_ROOT/context/"
      python3 "$ROOT/scripts/prepare_redis.py" --arch "${PLATFORM#linux/}" --context "$BUILD_ROOT/context"
      TAG="${TABULARIS_IMAGE_TAG:-${PROFILE}_0.30.0_vos_$(date +%Y%m%d%H%M%S)}"
      REPOSITORY=swr.cn-southwest-2.myhuaweicloud.com/ictrek/tabularis
      IMAGE="$REPOSITORY:$TAG"
      docker buildx build --load --provenance=false --sbom=false --platform "$PLATFORM" \
        --build-arg "GITHUB_PROXY=${GITHUB_PROXY:-https://ghfast.top/}" \
        -t "$IMAGE" -f "$BUILD_ROOT/context/docker/vos/Dockerfile" "$BUILD_ROOT/context" \
        > "$BUILD_ROOT/build-${PROFILE}.log" 2>&1
      node --test "$ROOT/docker/vos/gateway.test.mjs"
      PG_IMAGE="${PGV_VERIFY_IMAGE:-$(python3 "$ROOT/scripts/record_image.py" --sheet "$SHEET" --component pgv --repository swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv --resolve)}"
      REDIS_REPOSITORY=ictrek
      [[ "$PROFILE" != arm ]] || REDIS_REPOSITORY=ictrek-arm
      python3 "$ROOT/scripts/verify_viewer_runtime.py" --image "$IMAGE" --postgres-image "$PG_IMAGE" \
        --redis-image "swr.cn-southwest-2.myhuaweicloud.com/$REDIS_REPOSITORY/redis:7.0-alpine"
      if [[ "$BUILD_ONLY" == true ]]; then
        echo "Candidate built: $IMAGE"
      else
        docker push "$IMAGE"
        docker manifest inspect "$IMAGE" >/dev/null
        python3 "$ROOT/scripts/record_image.py" --sheet "$SHEET" --component tabularis --repository "$REPOSITORY" --tag "$TAG"
      fi ;;
    *) echo "Unsupported image: $component" >&2; exit 1 ;;
  esac
done
