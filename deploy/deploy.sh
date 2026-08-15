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

# The landing page quotes the APK's version, size and SHA-256. Derive them from the artifact before
# staging: hand-typed, they drifted to "18 MB · v2.3.5" and a checksum that did NOT match the APK the
# page linked — so anyone following the page's own "verify the checksum" step saw a mismatch.
./deploy/stamp-release.sh

rm -rf deploy/app && mkdir -p deploy/app
cp backend/*.py deploy/app/
cp backend/*.html deploy/app/ 2>/dev/null || true   # download/landing page served by the node front door
cp relay/xc_relayd.py deploy/app/
cp relay/install-relay.sh deploy/app/          # served at <node>/relay.sh — the landing page's one-liner
cp relay/xc_admin.py deploy/app/               # the relay operator's settings page (loopback only)
# The Flutter web build, served at <node>/chat. It's a build artifact (not in git), so build it first:
#   cd app && flutter build web --release --base-href /chat/
if [ -d app/build/web ]; then
  rm -rf deploy/app/web && cp -R app/build/web deploy/app/web
  echo "staged web app ($(du -sh deploy/app/web | cut -f1))"
else
  echo "NOTE: app/build/web missing — deploying without the browser app (/chat will say so)"
fi
echo "staged $(ls deploy/app | wc -l | tr -d ' ') files into deploy/app"

[ "${1:-}" = "--stage-only" ] && exit 0

cd deploy && fly deploy --config fly.toml --dockerfile Dockerfile
