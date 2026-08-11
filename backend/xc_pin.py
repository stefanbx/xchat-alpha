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

cids = set()
for h in best.values():
    cids.add(h['cid'])                                   # the thread JSON
    data = fetch(h['cid'])
    if data:
        try:
            for p in json.loads(data).get('posts', []):
                for k in ('thumb', 'media'):
                    if p.get(k):
                        cids.add(p[k])                   # referenced media
        except Exception:
            pass

blobs = 0; backfilled = 0
for cid in cids:
    data = fetch(cid)
    if not data or len(data) > CAP:
        continue
    b64 = base64.b64encode(data).decode(); blobs += 1
    for r in RELAYS:
        try:
            resp = json.loads(urllib.request.urlopen(urllib.request.Request(
                r + '/blob', json.dumps({'cid': cid, 'b64': b64}).encode(), {'Content-Type': 'application/json'}), timeout=5).read())
            if resp.get('stored'):
                backfilled += 1                          # this relay was missing it — now pinned
        except Exception:
            pass
json.dump({"ok": True, "blobs": blobs, "relays": len(RELAYS), "backfilled": backfilled},
          open('/tmp/xc_pin_result.json', 'w'))
