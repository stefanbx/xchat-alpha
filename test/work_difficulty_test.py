#!/usr/bin/env python3
# Nano has TWO epoch-2 work thresholds: send/change needs fffffff8_00000000 (~2^29 tries) and
# receive/open needs only fffffe00_00000000 (~2^23) — 64x cheaper. xc_blockproc used the send
# threshold for everything. Valid, but on a hosted node whose only PoW is public RPC or a shared vCPU
# it is the difference between a receive landing and timing out: a real user's 0.1 XNO sat unclaimed
# because the open block's work took 67.5s at the send threshold and the proxy in front gave up first.
#
# This is money code, and it fails in BOTH directions:
#   - too hard  -> receives never land (the bug above)
#   - too cheap -> a send is broadcast with work the network drops
# So assert the mapping AND the safety property, using the same C validator the code uses.
#
#   python3 test/work_difficulty_test.py
import os, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, 'backend'))
import xc_common as xc                                    # noqa: E402

# Load xc_blockproc's definitions WITHOUT running its main block (which would read /tmp and exit).
_src = open(os.path.join(REPO, 'backend', 'xc_blockproc.py')).read().split("res = {'ok': False, 'error': 'invalid'}")[0]
BP = {'__name__': 'bp', '__file__': os.path.join(REPO, 'backend', 'xc_blockproc.py')}
exec(compile(_src, 'xc_blockproc', 'exec'), BP)           # noqa: S102

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


diff_for = BP['diff_for']
SEND, RECV = diff_for('send'), diff_for('receive')

# ---- the mapping ----------------------------------------------------------
check(SEND == 0xfffffff800000000, 'send uses the epoch-2 send threshold', '%016x' % SEND)
check(RECV == 0xfffffe0000000000, 'receive uses the epoch-2 receive threshold', '%016x' % RECV)
check(diff_for('open') == RECV, 'an OPEN is a receive — the cheap threshold', '%016x' % diff_for('open'))
check(diff_for('change') == SEND, 'a CHANGE moves no funds but still pays send price',
      '%016x' % diff_for('change'))
check(diff_for('') == SEND and diff_for(None) == SEND,
      'an UNKNOWN subtype falls back to the EXPENSIVE threshold, never the cheap one')
# Direction matters: getting this backwards silently breaks every send on the network.
check(RECV < SEND, 'the receive threshold is genuinely the easier of the two')

# ---- the safety property, with real work ----------------------------------
# A fixed root so the test is deterministic in cost, not in nonce.
root = xc.nano_to_pub('nano_1t4zzmyutha95spnc1ijh84io7kxx69nkk8j3cccime83p3gz84ryis9p59c')
t0 = time.time()
w_recv = BP['_work_local'](root, RECV)
t_recv = time.time() - t0
check(BP['_work_ok'](w_recv, root, RECV), 'receive-grade work is valid at the receive threshold', w_recv)
# THE guard. If this ever passes, cheap work can reach a send and the block is dropped by the network.
check(not BP['_work_ok'](w_recv, root, SEND),
      'receive-grade work is REJECTED for a send', w_recv)
# And the default (no difficulty given) must be the strict one, so a caller that forgets is safe.
check(not BP['_work_ok'](w_recv, root),
      'with NO difficulty argument the strict threshold applies')

# ---- the cache must not launder cheap work into a send --------------------
import json                                              # noqa: E402
cache = BP['_CACHE']
saved = open(cache).read() if os.path.exists(cache) else None
try:
    json.dump({root: w_recv}, open(cache, 'w'))
    check(BP['_cache_valid'](root, RECV) == w_recv, 'the cache serves receive-grade work to a receive')
    check(BP['_cache_valid'](root, SEND) is None,
          'the cache REFUSES to serve receive-grade work to a send', str(BP['_cache_valid'](root, SEND)))
finally:
    if saved is None:
        try: os.remove(cache)
        except OSError: pass
    else:
        open(cache, 'w').write(saved)

print(f'      (receive-grade PoW on this box took {t_recv:.1f}s; the same root at send difficulty is '
      f'~64x the work — that gap is the bug this file exists for)')
print()
print(f'{"PASS" if not fails else "FAIL"} — {checks} checks, {len(fails)} failure(s)')
for f in fails:
    print('  -', f)
sys.exit(1 if fails else 0)
