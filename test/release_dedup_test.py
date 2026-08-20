#!/usr/bin/env python3
"""Release records are deduplicated by CID — a re-announced binary takes one slot, not several.

accept_release deduped only by `sig`, so a publisher re-announcing the SAME apk with a fresh signature
(a retry, or a re-sign) appended a second record for the same CID. That wasted the 24-record cap and
skewed the newest-N pin window. A CID is a content hash — the same CID is the same binary (same version)
— so records now collapse by CID (newest ts wins, ordered by ts) both at ingest and on load.

Extracts and runs the real _dedup_releases from xc_relayd.py (importing the module would start its HTTP
server), and asserts both call sites use it.

    python3 test/release_dedup_test.py
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'xc_relayd.py')).read()

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

# --- extract the pure function and run it ---
m = re.search(r'\ndef _dedup_releases\(lst\):.*?(?=\ndef )', SRC, re.S)
check(m is not None, 'found _dedup_releases in xc_relayd.py')
ns = {}
if m:
    exec(m.group(0), ns)
dedup = ns.get('_dedup_releases')

print('\n--- collapses duplicate CIDs, keeps newest ts, orders by ts ---')
recs = [
    {'cid': 'A', 'ts': 100, 'version': '2.2.7'},
    {'cid': 'A', 'ts': 200, 'version': '2.2.7'},   # same binary re-announced later
    {'cid': 'B', 'ts': 150, 'version': '2.3.0'},
    {'cid': 'A', 'ts': 50,  'version': '2.2.7'},    # and once earlier
    {'cid': 'C', 'ts': 300, 'version': '2.4.1'},
]
out = dedup(recs)
check([r['cid'] for r in out] == ['B', 'A', 'C'], 'one record per CID, ordered by ts', f'got {[r["cid"] for r in out]}')
check(len(out) == 3, 'three distinct binaries survive from five records', f'len={len(out)}')
check(next(r for r in out if r['cid'] == 'A')['ts'] == 200, 'the NEWEST record wins for a repeated CID')
check(dedup(recs) and out[-1]['cid'] == 'C', 'newest-by-ts sits last, so lst[-N:] is the newest-N window')

print('\n--- robust to junk; distinct binaries are never merged ---')
check([r for r in dedup(['junk', None, 42]) ] == [], 'non-dict entries are dropped')
# A cid-less record is a valid metadata-only release (accept_release allows cid=''); it must be KEPT,
# not silently dropped — dropping it broke harden_test's "valid release accepted / stored==1".
kept = dedup([{'version': '1', 'cid': '', 'ts': 5}, {'version': '2', 'ts': 9}])
check(len(kept) == 2, 'records with no/empty cid are PRESERVED (not deduped away)', f'got {kept}')
distinct = [{'cid': f'v{i}', 'ts': i} for i in range(5)]
check(len(dedup(distinct)) == 5, 'five distinct CIDs stay five records')
check(dedup([]) == [], 'empty list stays empty')

print('\n--- both call sites route through the dedup ---')
check(re.search(r'lst\.append\(m\)\s*\n\s*releases\[pub_acc\] = _dedup_releases\(lst\)', SRC) is not None,
      'accept_release dedups by CID at ingest (covers the direct announce AND the peer-sync path)')
check(re.search(r'releases\[pub\] = _dedup_releases\(lst\)', SRC) is not None,
      'the load path dedups existing records on restart (cleans what older code left)')

print()
if fails:
    print(f'FAIL — {checks} checks, {len(fails)} failure(s)')
    sys.exit(1)
print(f'PASS — {checks} checks, 0 failure(s)')
