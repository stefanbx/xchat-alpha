#!/usr/bin/env python3
# Aggregate signed COMMUNITY REPORTS across the relays into one "community" labeler. For each stored
# report, verify the signature and the key<->account binding, dedupe by account across relays, then per
# post expose a fraction = distinct valid reporters / QUORUM (capped at 1). The app hides a post whose
# fraction crosses the shield threshold (>=10% / >=50% / >=90%). One honest signal — how many real
# accounts flagged it — no stake/reputation weighting yet (Sybil resistance is therefore limited).
import json, os, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
QUORUM = float(os.environ.get('XC_REPORT_QUORUM', '3'))     # reporters for a full 1.0 (matches takedown)

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

per_post = {}                                              # post_id -> {account: ts}  (distinct VALID)
for r in RELAYS:
    try:
        d = json.loads(urllib.request.urlopen(r + '/reports', timeout=4).read()).get('reports', {})
        for pid, recs in d.items():
            for acc, rec in (recs or {}).items():
                pub, sig, ts = rec.get('pub', ''), rec.get('sig', ''), rec.get('ts', 0)
                if xc.pub_to_addr(pub) == acc and verify(pub, f"report|{acc}|{pid}|{ts}", sig):
                    per_post.setdefault(pid, {})[acc] = ts
    except Exception:
        pass

labels = []
for pid, accs in per_post.items():
    n = len(accs)
    frac = min(1.0, n / QUORUM) if QUORUM > 0 else 1.0
    labels.append({'post': pid, 'verdict': 'reported', 'reason': f'{n} community report(s)',
                   'frac': round(frac, 3), 'ts': max(accs.values()) if accs else 0})

out = {'labelers': [{'account': 'community', 'reputation': 1,
                     'list': {'labeler': 'community', 'labels': labels}}]} if labels else {'labelers': []}
json.dump(out, open('/tmp/xc_labels.json', 'w'))
