#!/usr/bin/env bash
# Portable, cross-machine reproduction of the ӾChat APK content hash.
# Unlike reproduce.sh (builds on YOUR host, so the hash is only stable per-path),
# this builds inside a pinned container at a canonical path — so any host OS gets
# the SAME content hash. This is the recipe a release's published hash comes from.
#
#   ./reproduce-docker.sh                 # build image if needed, build APK, print hash
#   ./reproduce-docker.sh <expected_hash> # + PASS/FAIL against a published hash
#   OUT=/some/dir ./reproduce-docker.sh   # also drop the rebuilt APK there
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EXPECT="${1:-${EXPECT:-}}"
IMAGE=xchat-repro
OUT="${OUT:-}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }

# The PUBLISHED canonical hash is defined on linux/amd64 (CI, native runner). Locally we
# build for the host arch unless buildx is available to cross-build. Set REPRO_PLATFORM=linux/amd64
# to force it (needs `docker buildx`); on a native amd64 host it's already amd64.
PLAT="${REPRO_PLATFORM:-}"
BUILD=(docker build) RUNPLAT=()
if [ -n "$PLAT" ]; then
  if docker buildx version >/dev/null 2>&1; then
    BUILD=(docker buildx build --platform "$PLAT" --load); RUNPLAT=(--platform "$PLAT")
  else
    echo "!! REPRO_PLATFORM=$PLAT requested but 'docker buildx' is unavailable — building for host arch."
    echo "   The published canonical hash is produced on an amd64 CI runner; a host-arch build"
    echo "   reproduces a host-arch hash (matches same-arch reproducers)."
  fi
fi
echo "== building the reproduction image ($IMAGE${PLAT:+, $PLAT}) — first run pulls the toolchain, ~minutes =="
"${BUILD[@]}" -t "$IMAGE" "$HERE"

args=(--rm "${RUNPLAT[@]}" -v "$REPO":/src:ro -e EXPECT="$EXPECT")
if [ -n "$OUT" ]; then mkdir -p "$OUT"; args+=(-v "$OUT":/out); fi

echo "== running the canonical-path build =="
docker run "${args[@]}" "$IMAGE"
