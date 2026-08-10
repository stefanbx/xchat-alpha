#!/usr/bin/env python3
# App SELF-DELIVERY: releases are the APK content-addressed (cid = sha256 of the bytes),
# pinned to the relays/IPFS like any other blob, PLUS a SIGNED release record published under
# the PUBLISHER key (a mutable head, like an author's). The app resolves the record, verifies
# the publisher signature + hash, then installs. GitHub is a mirror, not the root of trust —
# the signature is. Takedown of any one relay doesn't stop updates.
# Usage: xc_release.py publish   (reads /tmp/xc_rel_{apk,version,changelog}.txt)
#        xc_release.py check     (reads /tmp/xc_rel_current.txt  -> newest signed release)
#        xc_release.py fetch      (reads /tmp/xc_rel_{cid,sha}.txt -> verified APK on disk)
import json, os, sys, time, base64, hashlib, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'check'

PUB_SEEDBYTE = 0x99                                   # the publisher identity (demo trust anchor)
PUBLISHER = xc.acct(PUB_SEEDBYTE)                     # publisher Nano account (the app pins this)
APK_OUT = '/tmp/xchat_update.apk'

def rd(p, d=''):
    try:
        return open(p).read().strip() or d
    except Exception:
        return d

def vt(s):                                            # "1.2.0" -> (1,2,0) for ordering
    try:
        return tuple(int(x) for x in str(s).split('.'))
    except Exception:
        return (0,)

def canon(rec):
    return f"{rec['publisher']}|{rec['version']}|{rec['cid']}|{rec['sha256']}|{rec['size']}|{rec['changelog']}"

def verify(pub, msg, sig):
    try:
        return subprocess.check_output(['/tmp/xc_verify', pub, msg, sig]).decode().strip() == 'ok'
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

if mode == 'publish':
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
    d = dict(l.split(' ', 1) for l in subprocess.check_output(
        ['/tmp/xc_sign', xc.keyof(PUB_SEEDBYTE), canon(rec)]).decode().splitlines())
    rec['sig'] = d['sig']; rec['pub'] = d['pub']
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
                   'size': best['size']}, open('/tmp/xc_release_result.json', 'w'))
