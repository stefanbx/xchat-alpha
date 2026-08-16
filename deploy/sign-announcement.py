#!/usr/bin/env python3
# Sign the in-app announcement banner for the current release.
#
# The banner is a publisher-signed record the app shows above the feed. Nothing tied it to a release,
# so it went stale the obvious way: it sat advertising "ӾChat 2.3.9 is live — tap to update" through
# three releases while the update check correctly offered 2.4.3. Two sources of truth about the
# current version, one of them hand-maintained, is the whole bug. stamp-release.sh now runs this, so
# the release stamps both.
#
#   python3 deploy/sign-announcement.py 2.4.3           # sign backend/announcement.json
#   python3 deploy/sign-announcement.py 2.4.3 --check   # verify only; non-zero if stale (for CI)
#
# Signing needs the publisher key (XC_PUBLISHER_KEY, or ~/.xchat/publisher.key). Without one the
# banner is left alone with a warning rather than failing — CI has no key and must not fail for
# lacking one. --check needs no key at all, which is what makes it useful in CI: it catches a banner
# left pointing at an older version, which is exactly what went unnoticed for three releases.
import importlib.util, json, os, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REC = os.path.join(REPO, 'backend', 'announcement.json')
CUSTOM = os.path.join(REPO, 'deploy', 'announce-text.txt')
TTL_DAYS = 21
# Re-sign when the remaining life drops below this, so a long-lived release does not quietly expire.
REFRESH_UNDER_DAYS = 7

spec = importlib.util.spec_from_file_location('xc', os.path.join(REPO, 'backend', 'xc_common.py'))
xc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xc)

PUBLISHER = (os.environ.get('XC_PUBLISHER_ACCOUNT', '')
             or 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8')


def load():
    try:
        with open(REC, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: sign-announcement.py <version> [--check]')
    ver = sys.argv[1]
    check = '--check' in sys.argv[2:]
    a = load()

    if check:
        if a is None:
            print('announcement: none present (fine — the app shows nothing)')
            return 0
        stale = []
        if ver not in str(a.get('text', '')):
            stale.append(f'names a version other than v{ver}')
        if int(a.get('expires', 0)) <= time.time():
            stale.append('has expired')
        if stale:
            sys.exit('announcement: STALE (%s) — run ./deploy/stamp-release.sh' % '; '.join(stale))
        print('announcement: current (v%s, expires %s)'
              % (ver, time.strftime('%Y-%m-%d', time.localtime(int(a['expires'])))))
        return 0

    key = os.environ.get('XC_PUBLISHER_KEY', '')
    kf = os.path.expanduser('~/.xchat/publisher.key')
    if not key and os.path.exists(kf):
        with open(kf) as f:
            key = f.read().strip()
    if len(key) != 64:
        print('announcement: no publisher key — banner left unchanged')
        return 0
    signer = xc.derive(key)[0]
    if signer != PUBLISHER:
        sys.exit('announcement: this key signs as %s, not the pinned publisher %s — the app would '
                 'ignore the banner' % (signer, PUBLISHER))

    # Overridable per release. The default says only what the reader can act on and nothing they
    # cannot verify; anything longer belongs in the release changelog, which the update sheet shows.
    if os.path.exists(CUSTOM):
        with open(CUSTOM, encoding='utf-8') as f:
            text = f.read().strip()
    else:
        text = f'ӾChat {ver} is live — tap to update.'
    if ver not in text:
        sys.exit(f'announcement: the text does not mention v{ver}, so --check would call it stale the '
                 f'moment it shipped. Fix {CUSTOM}.')

    if a and a.get('text') == text and int(a.get('expires', 0)) - time.time() > REFRESH_UNDER_DAYS * 86400:
        print(f'announcement: already current (v{ver}) — left alone')
        return 0

    ts = int(time.time())
    expires = ts + TTL_DAYS * 86400
    d = dict(l.split(' ', 1) for l in xc._sign_lines(key, xc.sig_canon('announce', text, ts, expires)))
    rec = {'text': text, 'ts': ts, 'expires': expires, 'pub': d['pub'], 'sig': d['sig']}

    # Verify EXACTLY as kt_server.api_announcement will, before writing. A record that fails there is
    # served as "no announcement" — indistinguishable from having none, so the failure would be silent.
    ok = (xc.pub_to_addr(rec['pub']) == PUBLISHER
          and xc.verify_msg(rec['pub'],
                            xc.sig_canon('announce', rec['text'], rec['ts'], rec['expires']),
                            rec['sig']))
    if not ok:
        sys.exit('announcement: the record just signed does not verify — refusing to write it')

    with open(REC, 'w', encoding='utf-8') as f:
        json.dump(rec, f, ensure_ascii=False)
    print('announcement: signed -> v%s, expires %s'
          % (ver, time.strftime('%Y-%m-%d', time.localtime(expires))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
