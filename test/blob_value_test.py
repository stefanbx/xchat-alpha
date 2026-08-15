#!/usr/bin/env python3
# Issue #5: a blob's stored VALUE decides what survives eviction and what gets sync priority
# (blob_score ranks both). It used to be a number in an unauthenticated POST body, so anyone could
# declare their own spam the most valuable content on a relay and make it un-evictable while real
# content was dropped to make room. Value must now come only from a confirmed on-chain payment.
#
#   python3 test/blob_value_test.py
import base64, importlib.util, os, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Isolate in a fresh directory. The blob store is a SQLite file created NEXT TO the state file, so a
# test that only deletes the state JSON inherits the previous run's stored values from /tmp/blobs.db —
# and then measures the leftovers instead of what it just did.
import tempfile
_dir = tempfile.mkdtemp(prefix='xc_blobval_')
sys.argv = ['xc_relayd.py', '7996', os.path.join(_dir, 'state.json')]
os.environ.update({'XC_NANO_RPC': 'http://127.0.0.1:1'})
import http.server
http.server.ThreadingHTTPServer.serve_forever = lambda self, *a, **k: None
spec = importlib.util.spec_from_file_location('relayd', os.path.join(REPO, 'relay', 'xc_relayd.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

CID = 'sha256-value-test'
B64 = base64.b64encode(b'some media bytes').decode()
SRC = 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8'
DST = 'nano_1pyegpyq4pdfzjsweu66h8neutt5zkjf7mi3e5t454rnmdy79ed4aakjbp3c'
# Raw Nano amounts exceed float64's exact integer range, and blob_meta stores value as a float (it is
# a ranking signal, not an accounting figure). So compare with a relative tolerance rather than for
# exact equality — asserting float(10**28) == 10**28 fails on the float conversion, not the logic.
AMT = 10 ** 28                                  # 0.01 XNO


def ledger(**over):
    base = {'amount': str(AMT), 'confirmed': 'true', 'subtype': 'send',
            'contents': {'account': SRC, 'link_as_account': DST}}
    base.update(over)
    return base


def near(a, b, rel=1e-9):
    return abs(float(a) - float(b)) <= rel * float(b)


def value_of(cid):
    return float((r.blob_meta.get(cid) or {}).get('tips', 0))


results = []
def check(name, cond):
    results.append(cond)
    print(f'  {"PASS" if cond else "FAIL"}  {name}')


print('blob value must be earned, not declared\n')

# 1) storing bytes cannot assert value — the old /blob body carried `tips`
r.blob_put(CID, B64)
check('a freshly stored blob has zero value', value_of(CID) == 0)

# blob_put no longer even accepts a declared value
try:
    r.blob_put(CID, B64, tips=10 ** 30)
    check('blob_put refuses a caller-declared value', False)
except TypeError:
    check('blob_put refuses a caller-declared value', True)

# 2) a confirmed on-chain send credits it, once. Reputation is stubbed to 1.0 here so this case
#    measures the payment path; the weighting itself is exercised below.
r.xc.account_rep = lambda _a: 1.0
r.xc.rpc = lambda *_a, **_k: ledger()
first = r.blob_credit(CID, 'PAYHASH-1')
check('a confirmed send credits the blob', near(first, AMT) and near(value_of(CID), AMT))
again = r.blob_credit(CID, 'PAYHASH-1')
check('the same payment cannot be claimed twice', again == 0 and near(value_of(CID), AMT))

# 3) everything that is not a real payment to someone else buys nothing
before = value_of(CID)
cases = [
    ('an UNCONFIRMED send credits nothing',      ledger(confirmed='false')),
    ('a missing confirmed field credits nothing', {k: v for k, v in ledger().items() if k != 'confirmed'}),
    ('a receive block credits nothing',           ledger(subtype='receive')),
    ('a zero-amount send credits nothing',        ledger(amount='0')),
    ('a SELF-send credits nothing',               ledger(contents={'account': SRC, 'link_as_account': SRC})),
]
for i, (name, block) in enumerate(cases):
    r.xc.rpc = lambda *_a, _b=block, **_k: _b
    r.blob_credit(CID, f'PAYHASH-BAD-{i}')
    check(name, value_of(CID) == before)

# 4) reputation weighting (issue #11): a throwaway's self-dealt tip must be worth ~nothing
base = value_of(CID)
r.xc.account_rep = lambda _a: 0.0                      # fresh throwaway
r.xc.rpc = lambda *_a, **_k: ledger()
r.blob_credit(CID, 'PAYHASH-THROWAWAY')
check('a throwaway account credits nothing', value_of(CID) == base)
check('but its payment is still consumed', 'PAYHASH-THROWAWAY' in r.tips_paid)

r.xc.account_rep = lambda _a: 0.5                      # established-ish account
r.blob_credit(CID, 'PAYHASH-HALFREP')
check('an established account credits in proportion to reputation',
      near(value_of(CID) - base, AMT * 0.5))
r.xc.account_rep = lambda _a: 1.0

# 5) and the value survives the bytes being re-stored (a peer re-pushing must not reset or raise it)
expected = value_of(CID)
r.blob_put(CID, B64)
check('re-storing the bytes preserves earned value', near(value_of(CID), expected))

print(f'\n{sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
