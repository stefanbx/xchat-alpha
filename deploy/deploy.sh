#!/usr/bin/env bash
# Build and deploy the hosted node image.
#
# The Dockerfile copies a single flat /app, but the sources live in backend/ and relay/, so this
# stages them into deploy/app first. Doing it by hand is how a hosted node ends up running code
# nobody can point at — the reference node was live for hours on a build whose /api/post still
# signed with a seed the node held.
#
#   ./deploy/deploy.sh              # stage + fly deploy
#   ./deploy/deploy.sh --stage-only # just assemble deploy/app and stop
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf deploy/app && mkdir -p deploy/app
cp backend/*.py deploy/app/
cp backend/*.html deploy/app/ 2>/dev/null || true   # front-door download page
cp relay/xc_relayd.py deploy/app/
echo "staged $(ls deploy/app | wc -l | tr -d ' ') files into deploy/app"

[ "${1:-}" = "--stage-only" ] && exit 0

cd deploy && fly deploy --config fly.toml --dockerfile Dockerfile
