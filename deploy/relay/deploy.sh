#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
rm -rf deploy/relay/app && mkdir -p deploy/relay/app
cp relay/xc_relayd.py deploy/relay/app/
cp backend/xc_common.py deploy/relay/app/
echo "staged $(ls deploy/relay/app | wc -l | tr -d ' ') files"
[ "${1:-}" = "--stage-only" ] && exit 0
cd deploy/relay && fly deploy --config fly.toml --dockerfile Dockerfile
