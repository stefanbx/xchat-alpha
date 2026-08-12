#!/usr/bin/env python3
# Aggregate the feed from PLURAL RELAYS. Pull heads from every relay, VERIFY each head's
# signature and its key↔author binding, keep the HIGHEST valid seq per author (mutable
# head resolution), then fetch each author's content by CID. One relay down / stale /
# forging a head cannot break or censor the feed.
import json, subprocess, os, base64, urllib.request, urllib.parse
import importlib.util
from concurrent.futures import ThreadPoolExecutor
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()          # find the relay set from a bootstrap — no hardcoding
WORKERS = int(os.environ.get('XC_FEED_WORKERS', '16'))   # parallel fan-out for relay + content fetches

def get_content(cid):                  # content by CID: IPFS origin, else a relay CACHE (survives origin loss)
    try:
        # ipfs runs --offline here, so a missing block fails FAST (no DHT); a low timeout just caps the
        # rare slow local read. The old 8s cap × serial-per-post was the feed's cold-start bottleneck.
        return subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': xc.IPFS_PATH}, timeout=3)
    except Exception:
        pass
    for r in RELAYS:
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + urllib.parse.quote(cid, safe=''), timeout=4).read())
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

def fetch_heads(r):                    # returns a head list, or None if the relay is down/slow
    try:
        return json.loads(urllib.request.urlopen(r + '/heads', timeout=4).read()).get('heads', [])
    except Exception:
        return None

# PARALLEL relay fan-out: pull /heads from every relay at once (was a serial loop — N × round-trip).
up = 0
heads = []
if RELAYS:
    with ThreadPoolExecutor(max_workers=min(WORKERS, len(RELAYS))) as ex:
        for res in ex.map(fetch_heads, RELAYS):
            if res is not None:
                up += 1
                heads += res

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

# COMMUNITY TAKEDOWN: a post whose reputation-WEIGHTED reports cross the threshold is dropped from the
# feed for everyone (not just the reporter's client filter). Reports are verified + reputation-weighted
# in xc_common.aggregate_reports, so one relay can't censor by fabricating reports and a Sybil swarm of
# empty accounts can't force a takedown.
TAKEDOWN_W = float(os.environ.get('XC_TAKEDOWN_WEIGHT', '2'))
taken = {pid for pid, e in xc.aggregate_reports(RELAYS).items() if e['weight'] >= TAKEDOWN_W}

# PARALLEL content fetch: each author's content is fetched independently (IPFS, then relay cache), so
# fetch them all at once instead of serially — this was the dominant cold-start cost (per-post I/O × N).
best_heads = list(best.values())
posts = []
if best_heads:
    with ThreadPoolExecutor(max_workers=min(WORKERS, len(best_heads))) as ex:
        for data in ex.map(lambda h: get_content(h['cid']), best_heads):
            if data:
                try:
                    posts += [p for p in json.loads(data).get('posts', []) if p.get('id') not in taken]
                except Exception:
                    pass
posts.sort(key=lambda p: p.get('ts', 0), reverse=True)
# ATOMIC write: a reader (api_feed) must never see this file half-written, or the feed blinks empty.
json.dump({"feed": "XChat", "posts": posts, "relays_up": up, "relays_total": len(RELAYS),
           "authors": len(best)}, open('/tmp/xc_feed_agg.json.tmp', 'w'))
os.replace('/tmp/xc_feed_agg.json.tmp', '/tmp/xc_feed_agg.json')
