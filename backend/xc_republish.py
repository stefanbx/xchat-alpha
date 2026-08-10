#!/usr/bin/env python3
# Republish heads: re-sign each head we hold the key for with a FRESH expiry and push it to
# every DISCOVERED relay. This (a) keeps heads alive past their TTL and (b) backfills any
# newly-joined relay that was empty. This is what a client does periodically for its own head.
import json, subprocess, os, time, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
now = int(time.time())

# collect the current head per author across all relays (they may disagree/lag)
heads = {}
for r in RELAYS:
    try:
        for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=3).read()).get('heads', []):
            cur = heads.get(h['author'])
            if cur is None or h.get('seq', 0) >= cur.get('seq', 0):
                heads[h['author']] = h
    except Exception:
        pass

refreshed = 0
for acc, h in heads.items():
    sk = xc.key_for_account(acc)
    if sk is None:
        continue                           # only republish heads we hold the key for (wallet + demo authors)
    seq, cid = h['seq'], h['cid']; expires = now + xc.HEAD_TTL
    msg = f"{acc}|{seq}|{cid}|{expires}"
    d = dict(l.split(' ', 1) for l in subprocess.check_output(['/tmp/xc_sign', sk, msg]).decode().splitlines())
    head = {"author": acc, "handle": h.get('handle', ''), "seq": seq, "cid": cid,
            "ts": h.get('ts', now), "expires": expires, "sig": d['sig'], "pub": d['pub']}
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/push', json.dumps(head).encode(),
                                   {'Content-Type': 'application/json'}), timeout=3).read()
        except Exception:
            pass
    refreshed += 1
json.dump({"ok": True, "refreshed": refreshed, "relays": len(RELAYS), "ttl": xc.HEAD_TTL},
          open('/tmp/xc_republish_result.json', 'w'))
