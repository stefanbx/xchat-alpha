#!/usr/bin/env python3
# App SELF-DELIVERY: releases are the APK content-addressed (cid = sha256 of the bytes),
# pinned to the relays/IPFS like any other blob, PLUS a SIGNED release record published under
# the PUBLISHER key (a mutable head, like an author's). The app resolves the record, verifies
# the publisher signature + hash, then installs. GitHub is a mirror, not the root of trust —
# the signature is. Takedown of any one relay doesn't stop updates.
# Usage: xc_release.py keygen    (create the publisher key ONCE, outside the repo)
#        xc_release.py publish   (reads /tmp/xc_rel_{apk,version,changelog}.txt)
#        xc_release.py check     (reads /tmp/xc_rel_current.txt  -> newest signed release)
#        xc_release.py fetch      (reads /tmp/xc_rel_{cid,sha}.txt -> verified APK on disk)
#
# THE PUBLISHER KEY IS A SECRET, AND IT USED NOT TO BE. It was `keyof(0x99)` — a key derived from a
# constant in this file, which anyone reading the repo could recompute. That made the whole update
# path theatre: a stranger could sign a release record for any APK, the app would report "publisher
# signature verified", and install it. A signature is only a root of trust if exactly one party can
# produce it.
#
# So: the ACCOUNT is public and pinned (below, or via XC_PUBLISHER_ACCOUNT) and the KEY lives
# OUTSIDE this repo — XC_PUBLISHER_KEY, or ~/.xchat/publisher.key, 0600, made by `keygen`. Only
# `publish` needs it; `check` and `fetch` need the account alone.
import json, os, stat, sys, time, base64, hashlib, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'check'

KEY_FILE = os.path.expanduser(os.environ.get('XC_PUBLISHER_KEY_FILE', '~/.xchat/publisher.key'))
# The publisher account the app pins — public by nature, and safe here. Set XC_PUBLISHER_ACCOUNT to
# override it; a network of your own has its own publisher, and pinning theirs is the whole point.
PUBLISHER_PINNED = 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8'
APK_OUT = '/tmp/xchat_update.apk'

def rd(p, d=''):
    try:
        return open(p).read().strip() or d
    except Exception:
        return d

PUBLISHER = os.environ.get('XC_PUBLISHER_ACCOUNT', '') or PUBLISHER_PINNED or \
    rd(os.path.expanduser('~/.xchat/publisher.account'))

def publisher_key():
    # the secret, from the environment or a file outside the repo — never from a constant
    k = os.environ.get('XC_PUBLISHER_KEY', '') or rd(KEY_FILE)
    return k if len(k) == 64 else ''

def vt(s):                                            # "1.2.0" -> (1,2,0) for ordering
    try:
        return tuple(int(x) for x in str(s).split('.'))
    except Exception:
        return (0,)

def canon(rec):
    return f"{rec['publisher']}|{rec['version']}|{rec['cid']}|{rec['sha256']}|{rec['size']}|{rec['changelog']}"

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

def post(path, obj, timeout=30):
    ok = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=timeout).read()
            ok += 1
        except Exception:
            pass
    return ok

if mode == 'keygen':
    # one publisher key, made once, kept off the network and out of the repo
    if publisher_key():
        json.dump({'ok': False, 'error': f'a publisher key already exists at {KEY_FILE} — refusing to '
                   'overwrite it (delete it yourself if you really mean to rotate)'},
                  open('/tmp/xc_release_result.json', 'w'))
        print(f'refusing to overwrite {KEY_FILE}'); sys.exit(1)
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    key = os.urandom(32).hex()
    with open(KEY_FILE, 'w') as f:
        f.write(key + '\n')
    os.chmod(KEY_FILE, stat.S_IRUSR | stat.S_IWUSR)     # 0600: the one copy, readable by you alone
    addr, _pub = xc.derive(key)
    open(os.path.expanduser('~/.xchat/publisher.account'), 'w').write(addr + '\n')
    json.dump({'ok': True, 'account': addr, 'key_file': KEY_FILE}, open('/tmp/xc_release_result.json', 'w'))
    print(f'publisher key written to {KEY_FILE} (0600)\n'
          f'publisher account: {addr}\n\n'
          f'Pin it: set PUBLISHER_PINNED in this file (or XC_PUBLISHER_ACCOUNT) to that account.\n'
          f'BACK THE KEY UP. Lose it and you cannot sign another update; leak it and someone else can.')

elif mode == 'publish':
    key = publisher_key()
    if not key:
        json.dump({'ok': False, 'error': f'no publisher key (XC_PUBLISHER_KEY or {KEY_FILE}) — run '
                   '`python3 xc_release.py keygen` first'}, open('/tmp/xc_release_result.json', 'w'))
        print('no publisher key; run: python3 xc_release.py keygen'); sys.exit(1)
    signer_acct = xc.derive(key)[0]
    if PUBLISHER and signer_acct != PUBLISHER:
        # signing with a key the app does not pin produces a record every client silently ignores
        json.dump({'ok': False, 'error': f'this key signs as {signer_acct}, but the pinned publisher '
                   f'is {PUBLISHER} — the app would ignore the record'},
                  open('/tmp/xc_release_result.json', 'w'))
        print('publisher key does not match the pinned account'); sys.exit(1)
    PUBLISHER = PUBLISHER or signer_acct
    apk = rd('/tmp/xc_rel_apk.txt')
    version = rd('/tmp/xc_rel_version.txt', '1.0.0')
    changelog = rd('/tmp/xc_rel_changelog.txt', 'update')
    data = open(apk, 'rb').read()
    sha = hashlib.sha256(data).hexdigest()
    size = len(data)
    cid = 'sha256-' + sha                              # content id names the exact bytes
    # pin the APK bytes to every relay (content cache), so no single host is load-bearing
    b64 = base64.b64encode(data).decode()
    pinned = post('/blob', {'cid': cid, 'b64': b64})
    rec = {'publisher': PUBLISHER, 'version': version, 'cid': cid, 'sha256': sha,
           'size': size, 'changelog': changelog, 'ts': int(time.time())}
    d = dict(l.split(' ', 1) for l in xc._sign_lines(key, canon(rec)))
    rec['sig'] = d['sig']; rec['pub'] = d['pub']
    # A hash-verified DOWNLOAD MIRROR: a plain-binary CDN URL the app fetches FIRST (a 20 MB binary GET is
    # far more reliable than 27 MB of base64 JSON re-served by a small relay — that's what made the in-app
    # download spin-and-fail). It is NOT in the signed canon and NOT the root of trust: the app accepts the
    # bytes only if they match `sha256` above, and falls back to the relays if the mirror is wrong/down.
    mirror = os.environ.get('XC_RELEASE_URL', '') or \
        'https://raw.githubusercontent.com/stefanbx/xchat-alpha/master/apk/xchat-alpha.apk'
    if mirror:
        rec['url'] = mirror
    pushed = post('/release', rec)
    json.dump({'ok': True, 'version': version, 'cid': cid, 'size': size,
               'pinned_relays': pinned, 'record_relays': pushed}, open('/tmp/xc_release_result.json', 'w'))

elif mode == 'fetch':
    cid = rd('/tmp/xc_rel_cid.txt')
    want = rd('/tmp/xc_rel_sha.txt')
    got = None
    for r in RELAYS:
        try:
            b64 = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=30).read()).get('b64')
            if not b64:
                continue
            data = base64.b64decode(b64)
            if hashlib.sha256(data).hexdigest() == want:  # hash must match the signed record
                open(APK_OUT, 'wb').write(data)
                got = {'ok': True, 'path': APK_OUT, 'size': len(data), 'sha256_ok': True, 'served_by': r}
                break
        except Exception:
            pass
    json.dump(got or {'ok': False, 'error': 'no relay served a hash-matching blob'},
              open('/tmp/xc_release_result.json', 'w'))

else:                                                  # check: newest VALID signed release
    current = rd('/tmp/xc_rel_current.txt', '0.0.0')
    if not PUBLISHER:
        # NO PINNED PUBLISHER, NO UPDATES. The alternative — trusting whatever record turns up — is
        # how a self-updating app installs a stranger's APK. Refuse rather than guess.
        json.dump({'ok': True, 'update': False, 'publisher': '', 'current': current,
                   'error': 'no publisher account pinned; in-app updates are off'},
                  open('/tmp/xc_release_result.json', 'w'))
        sys.exit()
    best = None
    seen_sigs = set()
    # RELAYS sort local (http://127.*) before the public loopback (https://*.trycloudflare),
    # so the fast relays answer first. Records propagate to every relay, so the FIRST relay that
    # returns any records has the full picture — stop there instead of waiting on a slow/dead relay.
    for r in RELAYS:
        try:
            recs = json.loads(urllib.request.urlopen(r + '/releases?pub=' + PUBLISHER, timeout=4).read()).get('records', [])
            for rec in recs:
                if rec.get('sig') in seen_sigs:
                    continue
                seen_sigs.add(rec.get('sig'))
                # trust check: key must bind to the pinned publisher AND the signature must hold.
                # forged records simply fail here; the highest VALID version wins.
                if rec.get('publisher') == PUBLISHER and xc.pub_to_addr(rec['pub']) == PUBLISHER \
                   and verify(rec['pub'], canon(rec), rec['sig']):
                    if best is None or vt(rec['version']) > vt(best['version']):
                        best = rec
            if best is not None:                          # a responsive relay gave us a valid record — done
                break
        except Exception:
            pass
    if best is None:
        json.dump({'ok': True, 'update': False, 'publisher': PUBLISHER, 'current': current},
                  open('/tmp/xc_release_result.json', 'w'))
    else:
        json.dump({'ok': True, 'update': vt(best['version']) > vt(current), 'verified': True,
                   'publisher': PUBLISHER, 'current': current, 'version': best['version'],
                   'changelog': best['changelog'], 'cid': best['cid'], 'sha256': best['sha256'],
                   'size': best['size'], 'url': best.get('url')},   # hash-verified download mirror (may be null)
                  open('/tmp/xc_release_result.json', 'w'))
