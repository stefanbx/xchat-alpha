#!/usr/bin/env python3
# Supporter-mode CONTENT pinning + serving. Fetch the content each head points to
# (thread JSON + thumbnails), and push those blobs to every discovered relay that
# lacks them. Content is content-addressed (the CID names the bytes), so a supporter
# can pin/serve ANYONE's content and it can't be tampered with. Outbound-only, gated.
import json, os, time, base64, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
now = time.time()
CAP = 6_000_000   # pin media up to ~6MB (covers the small movies) so it survives origin loss

def fetch(cid):                       # get bytes for a cid: IPFS origin, else a relay cache
    try:
        return subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': xc.IPFS_PATH}, timeout=8)
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

# best live head per author -> the CIDs its content references
best = {}
for r in RELAYS:
    try:
        for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=3).read()).get('heads', []):
            if h.get('expires', 9e18) < now:
                continue
            cur = best.get(h['author'])
            if cur is None or h['seq'] > cur['seq']:
                best[h['author']] = h
    except Exception:
        pass

# Carry the post's VALUE (tips) with each blob, so the relay's value-weighted eviction keeps the
# tipped and drops the old + untipped. Tip totals per post, aggregated across relays (max wins).
engage = {}
for r in RELAYS:
    try:
        e = json.loads(urllib.request.urlopen(r + '/engagement', timeout=4).read()).get('engage', {})
        for pid, v in e.items():
            engage[pid] = max(engage.get(pid, 0), v.get('tips_raw', 0))
    except Exception:
        pass

# COMMUNITY REPORTS as a NEGATIVE value: the same score the relay evicts by (tips minus reputation-
# weighted reports) also ranks what we replicate. Reported content sinks; taken-down content (weighted
# reports >= TAKEDOWN_WEIGHT) is NOT propagated at all — a bad post must not be spread to more relays.
# Verified + reputation-weighted in xc_common.aggregate_reports (Sybil-resistant).
REPORT_WEIGHT = float(os.environ.get('XC_REPORT_WEIGHT', '0.05'))
TAKEDOWN_W = float(os.environ.get('XC_TAKEDOWN_WEIGHT', '2'))
post_reports = {pid: e['weight'] for pid, e in xc.aggregate_reports(RELAYS).items()}   # post_id -> weight

cids = {}                                                # cid -> tips (XNO): media = its post's tips,
cid_reports = {}                                         # cid -> reporter weight of the post using it
for h in best.values():                                  # the thread = the sum of its posts' tips
    data = fetch(h['cid'])
    thread_tips = 0.0; thread_rep = 0.0
    if data:
        try:
            for p in json.loads(data).get('posts', []):
                pid = p.get('id', '')
                pt = engage.get(pid, 0) / 1e30
                pr = post_reports.get(pid, 0)
                thread_tips += pt; thread_rep = max(thread_rep, pr)
                for k in ('thumb', 'media'):
                    if p.get(k):
                        cids[p[k]] = max(cids.get(p[k], 0.0), pt)          # referenced media
                        cid_reports[p[k]] = max(cid_reports.get(p[k], 0), pr)
        except Exception:
            pass
    cids[h['cid']] = max(cids.get(h['cid'], 0.0), thread_tips)             # the thread JSON
    cid_reports[h['cid']] = max(cid_reports.get(h['cid'], 0), thread_rep)

# SYNC THE BEST: replicate content to every relay in SCORE order (tips minus reports), best first,
# within a byte budget per round. The best reaches all relays (durable, multi-copy); the weak stays
# single-copy; taken-down content isn't replicated at all. Outbound-only, so it stays decentralised.
def score(c):
    return cids[c] - cid_reports.get(c, 0) * REPORT_WEIGHT
SYNC_BUDGET = int(float(os.environ.get('XC_SYNC_BUDGET_MB', '32')) * 1024 * 1024)
ranked = sorted(cids.keys(), key=lambda c: -score(c))    # highest score (tips - reports) first
spent = 0; blobs = 0; backfilled = 0; skipped = 0; suppressed = 0
for cid in ranked:
    if cid_reports.get(cid, 0) >= TAKEDOWN_W:           # community takedown — do not propagate
        suppressed += 1
        continue
    data = fetch(cid)
    if not data or len(data) > CAP:
        continue
    if spent + len(data) > SYNC_BUDGET:                  # budget went to the best — the weak isn't synced
        skipped += 1
        continue
    spent += len(data)
    b64 = base64.b64encode(data).decode(); blobs += 1
    for r in RELAYS:
        try:
            resp = json.loads(urllib.request.urlopen(urllib.request.Request(
                r + '/blob', json.dumps({'cid': cid, 'b64': b64, 'tips': cids[cid]}).encode(),
                {'Content-Type': 'application/json'}), timeout=5).read())
            if resp.get('stored'):
                backfilled += 1                          # this relay was missing it — now replicated
        except Exception:
            pass
json.dump({"ok": True, "blobs": blobs, "relays": len(RELAYS), "backfilled": backfilled,
           "skipped_lowvalue": skipped, "suppressed_reported": suppressed, "synced_bytes": spent},
          open('/tmp/xc_pin_result.json', 'w'))
