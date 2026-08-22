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

# Content is CONTENT-ADDRESSED (a CID *is* the hash of its bytes), so once we hold a CID's bytes they are
# valid forever. But xc_feed runs as a FRESH process every FEED_TTL, so it used to re-`ipfs cat` every
# post's content on every spawn — and each `ipfs cat` is a ~60 ms fork+exec of the Go binary, so a feed
# of N posts burned N×60 ms of pure process spawn every few seconds, almost all of it redundant. A disk
# cache keyed by CID makes that a ONE-TIME cost per CID: steady state (no new posts) does zero cats.
CONTENT_CACHE = os.environ.get('XC_CONTENT_CACHE', '/tmp/xc_content_cache')
CONTENT_TTL   = float(os.environ.get('XC_CONTENT_TTL', str(24 * 3600)))   # disk-bound only; content never changes

def _cache_path(cid):
    os.makedirs(CONTENT_CACHE, exist_ok=True)
    return os.path.join(CONTENT_CACHE, urllib.parse.quote(cid, safe=''))   # CID -> collision-free filename

def get_content(cid):                  # content by CID: disk cache, then IPFS origin, then a relay CACHE
    try:
        return open(_cache_path(cid), 'rb').read()     # cache hit: these bytes were CID-validated before writing
    except Exception:
        pass
    data = None
    try:
        # ipfs runs --offline here, so a missing block fails FAST (no DHT); a low timeout just caps the
        # rare slow local read. The old 8s cap × serial-per-post was the feed's cold-start bottleneck.
        data = subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': xc.IPFS_PATH}, timeout=3)
    except Exception:
        for r in RELAYS:
            try:
                d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + urllib.parse.quote(cid, safe=''), timeout=4).read())
                if d.get('b64'):
                    b = base64.b64decode(d['b64'])
                    if xc.content_matches_cid(cid, b):     # a rogue relay can't swap content for a signed CID
                        data = b; break
                    # bytes don't hash to the CID — this relay is lying/corrupt; try the next one
            except Exception:
                pass
    if data is not None:
        try:
            cp = _cache_path(cid); tmp = cp + '.tmp'     # atomic write; bytes are CID-valid (self-verified above)
            open(tmp, 'wb').write(data); os.replace(tmp, cp)
        except Exception:
            pass
    return data

def _prune_content_cache():            # disk hygiene only — an expired entry is still valid, just unused
    try:
        cut = time.time() - CONTENT_TTL
        for f in os.listdir(CONTENT_CACHE):
            p = os.path.join(CONTENT_CACHE, f)
            try:
                if os.path.getmtime(p) < cut:
                    os.remove(p)
            except Exception:
                pass
    except Exception:
        pass

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
    # A relay (or a peer POSTing to one) can hand us a head missing a field or with a non-numeric seq/
    # expires. Guard the whole record: one malformed head must skip itself, never KeyError/TypeError out
    # of the loop and blank the feed for everyone. CRUCIAL: the signing preimage must use the field
    # values EXACTLY as signed — sig_canon stringifies with str(), so coercing expires to float here
    # ('1787..0' -> '1787..0.0') would change the preimage and break every head's signature. Keep the
    # originals for sig_canon; derive numeric copies only for the expiry check / seq ordering.
    try:
        if not isinstance(h, dict):
            continue
        author = h['author']; seq = h['seq']; cid = h['cid']
        pub = h['pub']; sig = h['sig']
        exp = h.get('expires', 9e18)               # original value → signing preimage (unchanged)
        seq_n = int(seq); exp_n = float(exp)        # numeric views → comparison/sort only
    except (KeyError, TypeError, ValueError):
        continue
    msg = xc.sig_canon('head', author, seq, cid, exp)
    if exp_n < now:
        continue                                   # expired head — ignore (needs republish)
    if not verify(pub, msg, sig):
        continue                                   # forged / bad signature — reject
    if xc.pub_to_addr(pub) != author:
        continue                                   # key doesn't match the claimed author — reject
    cur = best.get(author)
    if cur is None or seq_n > cur['seq'] or (seq_n == cur['seq'] and exp_n > cur.get('expires', 0)):
        best[author] = {**h, 'seq': seq_n, 'expires': exp_n}   # numeric seq/expires for downstream compare

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
def _ts(p):                            # a post with a string/None/missing ts must not blow up the sort
    try:
        return float(p.get('ts', 0) or 0)
    except (TypeError, ValueError):
        return 0.0
posts.sort(key=_ts, reverse=True)
# ATOMIC write: a reader (api_feed) must never see this file half-written, or the feed blinks empty.
json.dump({"feed": "XChat", "posts": posts, "relays_up": up, "relays_total": len(RELAYS),
           "authors": len(best)}, open(xc.FEED_CACHE + '.tmp', 'w'))
os.replace(xc.FEED_CACHE + '.tmp', xc.FEED_CACHE)
_prune_content_cache()                 # bound the CID cache after the feed is written (off the hot path)
