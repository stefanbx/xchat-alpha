#!/usr/bin/env bash
# reproduce.sh — rebuild the ӾChat Android APK and print its content-identity hash,
# so anyone can confirm the published app is exactly this source.
#
# Trust model (see WHITEPAPER §7): a signed APK can't be byte-reproduced without our
# private key, so we anchor trust on the CONTENT hash — a hash over every file inside
# the APK, blind to ZIP timestamps/order/compression and to the signing key. A verifier
# runs this script and checks that the printed content_hash matches the one published in
# the release record. The signature is a separate, independent check (apksigner verify).
#
# Usage:
#   ./reproduce.sh                 # build + print hashes
#   ./reproduce.sh <expected_hash> # build + PASS/FAIL against a published content hash
#   EXPECT=<hash> ./reproduce.sh   # same, via env
#
# Env knobs:
#   SKIP_TOOLCHAIN_CHECK=1   don't enforce toolchain.lock (not recommended)
#   KEEP_BUILD=1             don't `flutter clean` first (faster, less hermetic)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$REPO/app"
LOCK="$HERE/toolchain.lock"
EXPECT="${1:-${EXPECT:-}}"

source "$HERE/buildenv.sh"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

lock_val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LOCK" | head -1; }

# ---- 1. toolchain check --------------------------------------------------------
say "1/4  Toolchain (pinned in toolchain.lock)"
if [ "${SKIP_TOOLCHAIN_CHECK:-0}" = "1" ]; then
  warn "toolchain check SKIPPED (SKIP_TOOLCHAIN_CHECK=1) — hash may not match the published one"
else
  fv=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -1)
  frev=$(flutter --version 2>/dev/null | sed -n 's/.*revision \([0-9a-f]*\).*/\1/p' | head -1)
  dv=$(flutter --version 2>/dev/null | sed -n 's/.*Dart \([0-9.]*\).*/\1/p' | head -1)
  jv=$("$JAVA_HOME/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)
  check() { # name expected actual
    if [ "$2" = "$3" ]; then ok "$1 = $3"
    else die "$1 mismatch: need '$2', have '$3'. Install the pinned toolchain or set SKIP_TOOLCHAIN_CHECK=1."; fi
  }
  check "flutter"          "$(lock_val flutter_version)"  "$fv"
  check "flutter revision" "$(lock_val flutter_revision)" "$frev"
  check "dart"             "$(lock_val dart_version)"     "$dv"
  check "java major"       "$(lock_val java_major)"       "$jv"
fi

# ---- 2. deterministic build inputs --------------------------------------------
say "2/4  Deterministic inputs"
# Pin every ZIP/JAR/AOT timestamp to the commit time so the .apk is as stable as
# the toolchain allows. The content hash does not depend on this, but a stable
# file_sha256 is a bonus for mirrors and the download record.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  export SOURCE_DATE_EPOCH="$(git -C "$REPO" log -1 --format=%ct)"
  ok "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(git -C "$REPO" rev-parse --short HEAD))"
else
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-315532800}"  # 1980-01-01, ZIP epoch
  warn "not a git checkout — SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
fi
export TZ=UTC LC_ALL=C

# ---- 3. build ------------------------------------------------------------------
say "3/4  Build (flutter build apk --release, arm64)"
cd "$APP"
[ "${KEEP_BUILD:-0}" = "1" ] || flutter clean >/dev/null 2>&1
flutter pub get >/dev/null 2>&1
flutter build apk --release --split-per-abi --target-platform android-arm64 >/tmp/xrepro_build.log 2>&1 \
  || { tail -20 /tmp/xrepro_build.log; die "build failed (full log: /tmp/xrepro_build.log)"; }
APK="$APP/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
[ -f "$APK" ] || die "expected APK not found: $APK"
ok "built $(du -h "$APK" | cut -f1)  $APK"

# ---- 4. hash + verify ----------------------------------------------------------
say "4/4  Content-identity hash"
OUT="$(python3 "$HERE/apk_content_hash.py" "$APK")"
echo "$OUT" | sed 's/^/  /'
CH="$(echo "$OUT" | sed -n 's/^content_hash:[[:space:]]*//p')"

if [ -n "$EXPECT" ]; then
  echo
  if [ "$CH" = "$EXPECT" ]; then
    printf '\033[42;30m PASS \033[0m content hash matches the published release.\n'
    exit 0
  else
    printf '\033[41;30m FAIL \033[0m content hash does NOT match.\n'
    printf '  expected: %s\n  got:      %s\n' "$EXPECT" "$CH"
    exit 1
  fi
fi
echo
say "Publish this content_hash in the release record; verifiers re-run reproduce.sh to match it."
