#!/usr/bin/env bash
# Build and deploy the hosted node image.
#
# The Dockerfile copies a single flat /app, but the sources live in backend/ and relay/, so this
# stages them into deploy/app first. Doing it by hand is how a hosted node ends up running code
# nobody can point at — the reference node was live for hours on a build whose /api/post still
# signed with a seed the node held.
#
#   ./deploy/deploy.sh                   # stage + fly deploy
#   ./deploy/deploy.sh --stage-only      # just assemble deploy/app and stop
#   ./deploy/deploy.sh --allow-stale-web # deploy a backend-only change without rebuilding /chat
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE_ONLY=0
ALLOW_STALE_WEB=0
for a in "$@"; do
  case "$a" in
    --stage-only)      STAGE_ONLY=1 ;;
    --allow-stale-web) ALLOW_STALE_WEB=1 ;;
    *) echo "deploy: unknown option: $a" >&2; exit 1 ;;
  esac
done

# The IPFS version is pinned in TWO places — relay/install-relay.sh (what a self-installed node gets)
# and deploy/Dockerfile (what the hosted node gets). They drifted: the image ran v0.29.0 while the
# installer pinned v0.43.0, fourteen minor versions apart, with nothing to notice. The installer is
# the source of truth; assert the Dockerfile's default agrees, then pass it explicitly so the built
# image uses it even if someone edits only one of the two.
KUBO_VERSION=$(sed -n 's/.*KUBO_V=\(v[0-9.]*\).*/\1/p' relay/install-relay.sh | head -1)
KUBO_IN_IMAGE=$(sed -n 's/^ARG KUBO_VERSION=\(v[0-9.]*\).*/\1/p' deploy/Dockerfile | head -1)
[ -n "$KUBO_VERSION" ] || { echo "deploy: could not read KUBO_V from relay/install-relay.sh" >&2; exit 1; }
if [ "$KUBO_VERSION" != "$KUBO_IN_IMAGE" ]; then
  echo "deploy: kubo pin drift — installer says $KUBO_VERSION, deploy/Dockerfile says $KUBO_IN_IMAGE." >&2
  echo "        Make them equal (the installer is the source of truth) and re-run." >&2
  exit 1
fi

# The landing page quotes the APK's version, size and SHA-256. Derive them from the artifact before
# staging: hand-typed, they drifted to "18 MB · v2.3.5" and a checksum that did NOT match the APK the
# page linked — so anyone following the page's own "verify the checksum" step saw a mismatch.
./deploy/stamp-release.sh

rm -rf deploy/app && mkdir -p deploy/app
cp backend/*.py deploy/app/
cp backend/*.html deploy/app/ 2>/dev/null || true   # download/landing page served by the node front door
# announcement.json — the publisher-signed in-app banner, written by stamp-release.sh. Without this
# line the file is generated on every release and then silently left behind, so the banner would keep
# showing whatever was last set by hand. That is the failure this automation exists to end.
cp backend/*.json deploy/app/ 2>/dev/null || true
cp relay/xc_relayd.py deploy/app/
cp relay/xc_tunnel.py deploy/app/              # mesh reverse-tunnel entry hub (imported by xc_relayd)
cp relay/install-relay.sh deploy/app/          # served at <node>/relay.sh — the landing page's one-liner
cp relay/xc_admin.py deploy/app/               # the relay operator's settings page (loopback only)
# The Flutter web build, served at <node>/chat. It's a build artifact (not in git), so build it first:
#   cd app && flutter build web --release --base-href /chat/
if [ -d app/build/web ]; then
  # A STALE web build is worse than a missing one: /chat silently serves an older app than the APK the
  # same page hands out, and nothing says so. Compare against the compiled entrypoint, NOT the directory
  # — flutter rewrites files inside app/build/web without touching the directory itself, so the folder's
  # mtime can read hours old immediately after a successful build.
  WEB_STAMP=app/build/web/main.dart.js
  if [ ! -f "$WEB_STAMP" ]; then
    echo "ERROR: app/build/web exists but has no main.dart.js — the build is incomplete." >&2
    echo "       cd app && flutter build web --release --base-href /chat/" >&2
    exit 1
  fi
  STALE=$(find app/lib app/web app/pubspec.yaml app/pubspec.lock -newer "$WEB_STAMP" 2>/dev/null || true)
  if [ -n "$STALE" ]; then
    if [ "$ALLOW_STALE_WEB" = 1 ]; then
      echo "NOTE: web build is stale, shipping it anyway (--allow-stale-web)"
    else
      echo "ERROR: the Flutter web build is STALE — /chat would ship older than the sources." >&2
      echo "       Newer than $WEB_STAMP:" >&2
      printf '%s\n' "$STALE" | head -10 | sed 's/^/         /' >&2
      echo "       Rebuild:  cd app && flutter build web --release --base-href /chat/" >&2
      echo "       Or, for a backend-only deploy:  ./deploy/deploy.sh --allow-stale-web" >&2
      exit 1
    fi
  fi
  rm -rf deploy/app/web && cp -R app/build/web deploy/app/web
  echo "staged web app ($(du -sh deploy/app/web | cut -f1))"
else
  echo "NOTE: app/build/web missing — deploying without the browser app (/chat will say so)"
fi
echo "staged $(ls deploy/app | wc -l | tr -d ' ') files into deploy/app"

if [ "$STAGE_ONLY" = 1 ]; then exit 0; fi

cd deploy && fly deploy --config fly.toml --dockerfile Dockerfile --build-arg "KUBO_VERSION=$KUBO_VERSION"
