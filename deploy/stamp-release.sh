#!/usr/bin/env bash
# Stamp the landing page's release facts from the ACTUAL artifact.
#
# Version, size and SHA-256 used to be hand-typed into backend/download.html, and they drifted: the
# page advertised "18 MB · v2.3.5" and a checksum that did not match the APK it linked. A published
# checksum that fails verification is worse than publishing none — it is indistinguishable from a
# tampered download, and it trains people to shrug off a failed check. So derive all three here and
# never type them again. deploy.sh runs this during staging, so the page cannot ship stale.
#
# It ALSO stamps the in-app announcement banner, for the same reason. That banner is a separate
# publisher-signed record, and because nothing tied it to a release it went stale exactly the way the
# page used to: it advertised "ӾChat 2.3.9 is live — tap to update" through three releases while the
# update check correctly offered 2.4.3. One release, one place that decides what version we claim.
#
#   ./deploy/stamp-release.sh              # rewrite backend/download.html + sign announcement.json
#   ./deploy/stamp-release.sh --check      # verify only; non-zero if either is stale (for CI)
#   ./deploy/stamp-release.sh --no-announce  # page only (a release nobody needs telling about)
set -euo pipefail
cd "$(dirname "$0")/.."

APK=apk/xchat-alpha.apk
PAGE=backend/download.html
[ -f "$APK" ]  || { echo "stamp-release: no $APK — build the release APK first" >&2; exit 1; }
[ -f "$PAGE" ] || { echo "stamp-release: no $PAGE" >&2; exit 1; }

# The app's version is single-sourced from pubspec (2.3.9+22309 -> 2.3.9); the rest comes from the file.
VER=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' app/pubspec.yaml)
[ -n "$VER" ] || { echo "stamp-release: could not read version from app/pubspec.yaml" >&2; exit 1; }
SHA=$(shasum -a 256 "$APK" | cut -d' ' -f1)
# Decimal MB (10^6), not MiB: Android's download UI and macOS both report SI megabytes, so this is the
# number the user will actually see next to the file. Quoting a 9.9 MiB file as "9.9 MB" next to a
# phone saying "10.4 MB" is a small mismatch, but on a page whose whole job is "verify this is real"
# every number that disagrees with the user's own screen costs trust.
MB=$(python3 -c "import os;print(f'{os.path.getsize('$APK')/1e6:.1f}')")

MODE="${1:-}"
python3 - "$PAGE" "$VER" "$MB" "$SHA" "$MODE" <<'PY'
import re, sys
page, ver, mb, sha, mode = sys.argv[1:6]
src = open(page).read()

# Replace the whole <small> payload rather than each field, so a spacing or separator tweak in the
# page doesn't silently stop the size/version from being updated.
out, n1 = re.subn(r'(<small>signed APK)[^<]*(</small>)',
                  rf'\g<1> · {mb} MB · v{ver} · verify the checksum below\g<2>', src)
out, n2 = re.subn(r'(<div class="hash">)[a-f0-9]{64}(</div>)', rf'\g<1>{sha}\g<2>', out)
if (n1, n2) != (1, 1):
    sys.exit(f'stamp-release: matched {n1} version/size site(s) and {n2} hash site(s), expected 1 each — '
             'the page markup changed; fix this script rather than hand-editing the page')

if mode == '--check':
    if out != src:
        sys.exit(f'stamp-release: {page} is STALE — run ./deploy/stamp-release.sh')
    print(f'stamp-release: {page} is current (v{ver} · {mb} MB · {sha[:16]}…)')
else:
    if out == src:
        print(f'stamp-release: {page} already current (v{ver} · {mb} MB · {sha[:16]}…)')
    else:
        open(page, 'w').write(out)
        print(f'stamp-release: {page} updated -> v{ver} · {mb} MB · {sha[:16]}…')
PY

# The banner is signed by the same run that stamps the page, so the two can no longer disagree.
if [ "$MODE" != "--no-announce" ]; then
    python3 deploy/sign-announcement.py "$VER" $MODE
fi
