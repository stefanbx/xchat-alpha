#!/usr/bin/env python3
"""A relay that is announced but DEAD must leave the set and stay gone.

The live bug this pins: a dead relay (a Cloudflare quick-tunnel that went away) stayed in every
client's /relays list forever. Pruning WAS running — `_forget` drops a url after RELAY_FAIL_MAX failed
probes — but it was undone the same cycle: the peer that hadn't forgotten it yet re-served it, and this
relay re-learned it. A signed record carries a fixed timestamp and is relayable by anyone, so the
corpse circulated indefinitely; the bare url did the same through the flat `relays` list.

The fix makes forgetting STICK: `_forget` leaves a `dead_until` tombstone, `learn_peer` refuses a
tombstoned url (unless a NEWER signed self-announce proves a genuine comeback), and neither serving
path advertises a tombstoned url or a signed record older than RELAY_TTL. A live relay re-announces
with a fresh timestamp every cycle, so it is never affected.

This is a behavioural test (per the dm-lock-and-relay-fanout lesson: source scans hid a live outage).
It loads the real xc_relayd gossip functions in a neutralised harness — no server, no threads, no
network — and drives them.

    python3 test/relay_dead_relay_gc_test.py
"""
import os, sys, time, tempfile, threading, http.server

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'xc_relayd.py')).read()

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   [{detail}]' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def load_relayd():
    """Exec xc_relayd.py with its import-time server + daemon threads neutralised, and a fake __file__
    so it finds no xc_common sibling (xc stays None — no crypto, no identity, no ledger reads)."""
    tmpdir = tempfile.mkdtemp(prefix='xc_relayd_test_')          # no xc_common.py beside it
    store = os.path.join(tmpdir, 'store')
    os.makedirs(store, exist_ok=True)

    saved_argv, saved_start, saved_srv = sys.argv, threading.Thread.start, http.server.ThreadingHTTPServer
    sys.argv = ['xc_relayd', '7401', store]                     # PORT, STORE, then BOOTSTRAPS=[]
    threading.Thread.start = lambda self: None                  # daemons must not run
    http.server.ThreadingHTTPServer = type('Stub', (), {        # the trailing serve_forever() must return
        '__init__': lambda self, *a, **k: None,
        'serve_forever': lambda self: None})
    ns = {'__file__': os.path.join(tmpdir, 'xc_relayd.py'), '__name__': 'xc_relayd_under_test'}
    try:
        exec(compile(SRC, os.path.join(REPO, 'relay', 'xc_relayd.py'), 'exec'), ns)
    finally:
        sys.argv, threading.Thread.start, http.server.ThreadingHTTPServer = saved_argv, saved_start, saved_srv
    return ns


class FakeXc:
    # Just enough for learn_peer's signed path: identity pub->acct, and any signature verifies.
    def pub_to_addr(self, pub):            return pub
    def verify_msg(self, pub, msg, sig):   return True
    def sig_canon(self, mtype, *fields):   return mtype + '|' + '|'.join(map(str, fields))


def signed_rec(acct, url, ts):
    return {'url': url, 'account': acct, 'pub': acct, 'ts': int(ts), 'sig': 'x'}


ns = load_relayd()
SELF = ns['SELF']
DEAD = 'https://dead-tunnel.example'
now = int(time.time())

print('--- setup: module loaded offline, xc is None ---')
check(ns.get('xc') is None, 'xc_common not loaded in the harness (pure gossip logic under test)')
check(SELF not in ns['dead_until'], 'this relay never tombstones itself')

print('\n--- the bare-url resurrection (the actual live bug), signed path off ---')
ns['known'].add(DEAD)
ns['_forget'](DEAD)
check(DEAD not in ns['known'], '_forget drops the dead url from the flat set')
check(ns['dead_until'].get(DEAD, 0) > now, '_forget leaves a tombstone so it can be refused later')
check(DEAD not in ns['_serve_relays'](), 'a tombstoned url is not advertised in /relays')

learned = ns['learn_peer']({'url': DEAD})                       # exactly what a cross-pull re-teaches
check(learned is False, 'learn_peer REFUSES the tombstoned url a peer tries to hand back')
check(DEAD not in ns['known'], 'the dead url does NOT resurrect into the set')  # THE FIX

print('\n--- a genuinely new relay is still learnable (no over-blocking) ---')
FRESH = 'https://brand-new.example'
ns['OPEN_ANNOUNCE'] = True                                      # prod runs open (open_announce: true)
check(bool(ns['learn_peer']({'url': FRESH})), 'an untombstoned url is learned normally')
check(FRESH in ns['_serve_relays'](), 'and it is advertised')

print('\n--- the tombstone lapses so a recovered relay can rejoin ---')
ns['dead_until'][DEAD] = now - 1                                # simulate RELAY_TTL elapsed
check(bool(ns['learn_peer']({'url': DEAD})), 'once the tombstone expires the url can be learned again')
check(DEAD in ns['_serve_relays'](), 'and it is advertised once more')

print('\n--- signed records: freshness + tombstone revive ---')
ns['xc'] = FakeXc()                                            # enable the signed path
TTL = ns['RELAY_TTL']
A, AURL = 'nano_relayA', 'https://relayA.example'

# a stale-but-valid signed record is not served as a live peer
ns['peers_by_acct'][A] = {'url': AURL, 'ts': now - TTL - 10, 'pub': A, 'sig': 'x'}
check(all(p['account'] != A for p in ns['signed_peers']()),
      'signed_peers() never relays a record older than RELAY_TTL')
ns['peers_by_acct'].pop(A, None)

# tombstone A's url, then prove only a NEWER announce revives it
ns['known'].add(AURL); ns['_forget'](AURL)
forget_at = ns['dead_until'][AURL] - TTL                        # dead_until == forget_time + TTL
stale_ok = ns['learn_peer'](signed_rec(A, AURL, forget_at - 100))   # the old record still circulating
check(stale_ok is False and AURL not in ns['known'],
      'an OLD signed record (minted before we forgot it) cannot revive a tombstoned relay')
fresh_ok = ns['learn_peer'](signed_rec(A, AURL, int(time.time()) + 1))  # a comeback announce, minted now
check(bool(fresh_ok), 'a FRESH signed self-announce revives a tombstoned relay (genuine comeback)')
check(AURL not in ns['dead_until'] and AURL in ns['known'], 'revival clears the tombstone and re-adds it')
check(any(p['account'] == A for p in ns['signed_peers']()), 'the revived relay is served as a signed peer')

print(f'\n{checks - len(fails)}/{checks} checks passed')
if fails:
    print('FAILED:', *fails, sep='\n  - ')
    sys.exit(1)
print('all good')
