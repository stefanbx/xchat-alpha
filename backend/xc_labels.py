#!/usr/bin/env python3
# Aggregate signed COMMUNITY REPORTS across the relays into one "community" labeler. Each report is
# verified (signature + key<->author binding) and weighted by the reporter's ON-CHAIN reputation
# (xc_common.aggregate_reports), so the per-post fraction reflects reputation, not raw account count —
# a pile of empty throwaway accounts can't force a hide. The app hides a post whose fraction crosses
# the shield threshold (>=10% / >=50% / >=90%); "Show anyway" always reveals.
import json, os
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
QUORUM_W = float(os.environ.get('XC_TAKEDOWN_WEIGHT', '2'))     # weighted reporters for a full 1.0 (= takedown)

agg = xc.aggregate_reports(RELAYS)                             # post_id -> {'weight','count','cid'}
labels = []
for pid, e in agg.items():
    frac = min(1.0, e['weight'] / QUORUM_W) if QUORUM_W > 0 else 1.0
    labels.append({'post': pid, 'verdict': 'reported',
                   'reason': "%d report(s) · weight %.2f" % (e['count'], e['weight']),
                   'frac': round(frac, 3), 'ts': 0})

out = {'labelers': [{'account': 'community', 'reputation': 1,
                     'list': {'labeler': 'community', 'labels': labels}}]} if labels else {'labelers': []}
json.dump(out, open('/tmp/xc_labels.json.tmp', 'w'))       # atomic: never let a reader see a half-write
os.replace('/tmp/xc_labels.json.tmp', '/tmp/xc_labels.json')
