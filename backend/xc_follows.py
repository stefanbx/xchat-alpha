#!/usr/bin/env python3
# Portable follows: a SIGNED follow-list keyed by the wallet account, published to the relays — so a
# restore on another phone brings the follow graph with it.
#
# ON-DEVICE SIGNING: the record arrives ALREADY SIGNED BY THE APP. The node only verifies it and
# relays it — it holds no seed and cannot forge, alter or reorder anybody's follow list.
# Usage: xc_follows.py pub   (reads /tmp/xc_follows_rec.json  = app-signed record)
#        xc_follows.py get   (reads /tmp/xc_follows_acct.txt  -> that account's list)
import json, os, sys, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'

def rd(p, d=''):
    try:
        return open(p).read().strip() if os.path.exists(p) else d
    except Exception:
        return d

def canon(account, ts, follows):
    return xc.sig_canon('follow', account, ts, ','.join(sorted(follows)))

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

if mode == 'pub':
    # The follow list is ALREADY SIGNED BY THE APP (on-device). Verify the key binds to the account
    # and that the signature covers this exact list, then relay it. No seed touched.
    src = json.load(open('/tmp/xc_follows_rec.json'))
    acc = src.get('account', ''); ts = src.get('ts')
    follows = sorted(set(a for a in (src.get('follows') or []) if a))
    sig = src.get('sig', ''); pub = src.get('pub', '')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, canon(acc, ts, follows), sig)):
        json.dump({"ok": False, "error": "bad signature"}, open('/tmp/xc_follows_result.json', 'w')); sys.exit()
    rec = {"account": acc, "follows": follows, "ts": ts, "sig": sig, "pub": pub}
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/follows', json.dumps(rec).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            pushed += 1
        except Exception:
            pass
    json.dump({"ok": True, "count": len(follows), "relays": pushed}, open('/tmp/xc_follows_result.json', 'w'))
elif mode == 'followers':                                    # who follows this account (reverse edge)
    acc = rd('/tmp/xc_follows_acct.txt')
    seen = set()
    for r in RELAYS:
        try:
            fl = json.loads(urllib.request.urlopen(r + '/followers?account=' + acc, timeout=4).read()).get('followers', [])
            seen.update(a for a in fl if a)
        except Exception:
            pass
    json.dump({"ok": True, "followers": sorted(seen)}, open('/tmp/xc_follows_result.json', 'w'))
else:                                                        # get: fetch the newest valid record
    acc = rd('/tmp/xc_follows_acct.txt')
    best = None
    for r in RELAYS:
        try:
            rec = json.loads(urllib.request.urlopen(r + '/follows?account=' + acc, timeout=4).read()).get('record')
            if not rec:
                continue
            msg = canon(rec['account'], rec['ts'], rec['follows'])
            if rec['account'] == acc and xc.pub_to_addr(rec['pub']) == acc and verify(rec['pub'], msg, rec['sig']):
                if best is None or rec['ts'] > best['ts']:
                    best = rec
        except Exception:
            pass
    json.dump({"ok": True, "follows": best['follows'] if best else []}, open('/tmp/xc_follows_result.json', 'w'))
