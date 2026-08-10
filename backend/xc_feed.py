#!/usr/bin/env python3
# Aggregate the feed from PLURAL RELAYS. Pull heads from every relay, VERIFY each head's
# signature and its key↔author binding, keep the HIGHEST valid seq per author (mutable
# head resolution), then fetch each author's content by CID. One relay down / stale /
# forging a head cannot break or censor the feed.
import json, subprocess, os, base64, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()          # find the relay set from a bootstrap — no hardcoding

def get_content(cid):                  # content by CID: IPFS origin, else a relay CACHE (survives origin loss)
    try:
        return subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': '/tmp/ipfsB'}, timeout=8)
    except Exception:
        pass
    for r in RELAYS:
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=4).read())
            if d.get('b64'):
                return base64.b64decode(d['b64'])
        except Exception:
            pass
    return None

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

up = 0
heads = []
for r in RELAYS:
    try:
        d = json.loads(urllib.request.urlopen(r + '/heads', timeout=4).read())
        up += 1
        heads += d.get('heads', [])
    except Exception:
        pass

import time
now = time.time()
best = {}
for h in heads:
    exp = h.get('expires', 9e18)
    msg = f"{h['author']}|{h['seq']}|{h['cid']}|{exp}"
    if exp < now:
        continue                                   # expired head — ignore (needs republish)
    if not verify(h['pub'], msg, h['sig']):
        continue                                   # forged / bad signature — reject
    if xc.pub_to_addr(h['pub']) != h['author']:
        continue                                   # key doesn't match the claimed author — reject
    cur = best.get(h['author'])
    if cur is None or h['seq'] > cur['seq'] or (h['seq'] == cur['seq'] and exp > cur.get('expires', 0)):
        best[h['author']] = h                      # highest valid seq (mutable head), freshest TTL

posts = []
for h in best.values():
    data = get_content(h['cid'])
    if data:
        try:
            posts += json.loads(data).get('posts', [])
        except Exception:
            pass
posts.sort(key=lambda p: p.get('ts', 0), reverse=True)
json.dump({"feed": "XChat", "posts": posts, "relays_up": up, "relays_total": len(RELAYS),
           "authors": len(best)}, open('/tmp/xc_feed_agg.json', 'w'))
