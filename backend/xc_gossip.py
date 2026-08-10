#!/usr/bin/env python3
# The work a SUPPORTER phone actually does. A phone can't accept inbound (NAT), so it
# serves by PROPAGATING: fetch the best head per author across the discovered relays and
# re-push it to every relay — backfilling ones that are missing or lagging. Heads are
# signed, so a supporter can relay ANYONE's head (it can't forge). Outbound-only, battery-gated.
import json, os, time, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
now = time.time()

# collect the best (highest seq / freshest TTL) live head per author across all relays
best = {}
for r in RELAYS:
    try:
        for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=3).read()).get('heads', []):
            if h.get('expires', 9e18) < now:
                continue
            cur = best.get(h['author'])
            if cur is None or h['seq'] > cur['seq'] or (h['seq'] == cur['seq'] and h.get('expires', 0) > cur.get('expires', 0)):
                best[h['author']] = h
    except Exception:
        pass

# push each best head to every relay; the relay accepts only if it was missing/staler (=backfill)
pushes = 0; backfilled = 0
for h in best.values():
    for r in RELAYS:
        try:
            resp = json.loads(urllib.request.urlopen(urllib.request.Request(
                r + '/push', json.dumps(h).encode(), {'Content-Type': 'application/json'}), timeout=3).read())
            pushes += 1
            if resp.get('accepted'):
                backfilled += 1
        except Exception:
            pass
json.dump({"ok": True, "heads": len(best), "relays": len(RELAYS), "pushes": pushes, "backfilled": backfilled},
          open('/tmp/xc_gossip_result.json', 'w'))
