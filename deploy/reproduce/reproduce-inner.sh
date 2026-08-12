#!/usr/bin/env bash
# Runs INSIDE the reproduction container (see Dockerfile). The host mounts the repo
# read-only at /src; we copy it to the CANONICAL path /build/xchat and build there,
# so the one path the Dart AOT snapshot embeds is identical for every reproducer.
set -euo pipefail

SRC=/src
DST=/build/xchat
EXPECT="${EXPECT:-}"

echo "== copying source to the canonical path $DST =="
mkdir -p "$DST"
# Copy tracked source only; never the host's build/ or .dart_tool/ (they carry host paths).
cp -a "$SRC/." "$DST/"
rm -rf "$DST/app/build" "$DST/app/.dart_tool" "$DST/app/android/key.properties"
cd "$DST/app"

echo "== flutter build apk --release (arm64) at $DST =="
# No signing key in the container: the release build falls back to the debug key.
# That's fine — the content hash EXCLUDES all signature files, so it matches the
# publisher's signed APK regardless.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-315532800}" TZ=UTC LC_ALL=C
flutter pub get >/dev/null
flutter build apk --release --split-per-abi --target-platform android-arm64

APK="$DST/app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
echo "== content-identity hash =="
python3 "$DST/deploy/reproduce/apk_content_hash.py" "$APK"
CH="$(python3 "$DST/deploy/reproduce/apk_content_hash.py" "$APK" --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["content_hash"])')"

# Copy the built APK out if the host mounted an output dir.
[ -d /out ] && cp "$APK" /out/app-arm64-v8a-release.repro.apk || true

if [ -n "$EXPECT" ]; then
  if [ "$CH" = "$EXPECT" ]; then
    echo "PASS: content hash matches the published release ($CH)"; exit 0
  else
    echo "FAIL: expected $EXPECT got $CH"; exit 1
  fi
fi
