#!/usr/bin/env python3
# Portable follows: publish a SIGNED follow-list to the relays (keyed by the wallet account),
# and fetch+verify it back — so a restore on another phone brings the follow graph with it.
# Usage: xc_follows.py pub | xc_follows.py get
import json, os, sys, time, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'
acc = xc.wallet_acct()

def canon(account, ts, follows):
    return f"{account}|{ts}|{','.join(sorted(follows))}"

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

if mode == 'pub':
    csv = open('/tmp/xc_follows_csv.txt').read().strip()    # comma-joined accounts from the app
    follows = sorted(set(a for a in csv.split(',') if a))
    ts = int(time.time())
    d = dict(l.split(' ', 1) for l in xc._sign_lines(xc.wallet_key(), canon(acc, ts, follows)))
    rec = {"account": acc, "follows": follows, "ts": ts, "sig": d['sig'], "pub": d['pub']}
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/follows', json.dumps(rec).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            pushed += 1
        except Exception:
            pass
    json.dump({"ok": True, "count": len(follows), "relays": pushed}, open('/tmp/xc_follows_result.json', 'w'))
else:                                                        # get: fetch the newest valid record
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
