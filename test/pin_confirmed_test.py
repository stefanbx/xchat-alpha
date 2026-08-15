#!/usr/bin/env python3
# Issue #9: pay-to-pin must only grant time on a CONFIRMED send to this relay's account.
# Drives the real grant_pin() with a stubbed ledger so every case is exact and offline.
import importlib.util, os, sys, io, contextlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.argv = ['xc_relayd.py', '7998', '/tmp/_pin_test_state.json']
os.environ.update({'XC_NANO_RPC': 'http://127.0.0.1:1',
    'RELAY_ACCT': 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8'})
for f in ('/tmp/_pin_test_state.json', '/tmp/_pin_test_state.json.id'):
    if os.path.exists(f):
        os.remove(f)
import http.server
http.server.ThreadingHTTPServer.serve_forever = lambda self, *a, **k: None
spec = importlib.util.spec_from_file_location('relayd', os.path.join(REPO, 'relay', 'xc_relayd.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

ACCT = r.RELAY_ACCT
assert ACCT, 'test needs a payout account'
PUB = r.xc.nano_to_pub(ACCT).upper()
AMT = str(10**28)                      # 0.01 XNO — comfortably above zero


def ledger(**over):
    base = {'amount': AMT, 'confirmed': 'true', 'subtype': 'send',
            'contents': {'link': PUB, 'link_as_account': ACCT}}
    base.update(over)
    return base


def run(name, block, expect_pin):
    r.pins_paid.clear(); r.pinned.clear()
    r.xc.rpc = lambda *_a, **_k: block
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        got = r.grant_pin('cid-test', 'HASH' + name[:8])
    ok = (got > 0) == expect_pin
    note = ' | logged: ' + buf.getvalue().strip()[:58] if buf.getvalue().strip() else ''
    print(f'  {"PASS" if ok else "FAIL"}  {name:46} pin={"granted" if got else "refused":8}{note}')
    return ok

print('pay-to-pin, confirmed-send enforcement\n')
results = [
    run('confirmed send to us',                 ledger(),                             True),
    run('UNCONFIRMED send to us',               ledger(confirmed='false'),            False),
    run('confirmed field ABSENT (fail closed)', {k: v for k, v in ledger().items() if k != 'confirmed'}, False),
    run('confirmed=true but a RECEIVE block',   ledger(subtype='receive'),            False),
    run('confirmed=true but an EPOCH block',    ledger(subtype='epoch', amount='0'),  False),
    run('confirmed send to SOMEONE ELSE',
        ledger(contents={'link': '00' * 32, 'link_as_account':
                         'nano_1111111111111111111111111111111111111111111111111111hifc8npp'}), False),
    run('confirmed send of zero',               ledger(amount='0'),                   False),
    run('subtype absent but otherwise valid',   {k: v for k, v in ledger().items() if k != 'subtype'}, True),
]

# a payment may only ever be consumed once
r.pins_paid.clear(); r.pinned.clear()
r.xc.rpc = lambda *_a, **_k: ledger()
first = r.grant_pin('cid-a', 'HASH-REPLAY')
second = r.grant_pin('cid-b', 'HASH-REPLAY')
ok = first > 0 and second == 0
results.append(ok)
print(f'  {"PASS" if ok else "FAIL"}  {"same payment cannot be claimed twice":46} '
      f'first={"granted" if first else "refused"} second={"granted" if second else "refused"}')

print(f'\n{sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
