#!/usr/bin/env python3
# SPOF-free relay discovery for ӾChat.
#
# There is no directory owner. Each relay is self-sovereign: it owns its own XNO account, commits its
# URL on ITS OWN chain (signed by itself — the account IS the pubkey), and checks in by sending 1-raw
# dust to a set of keyless RENDEZVOUS accounts. Discovery scans a rendezvous' receivable/history for the
# set of relay accounts, then reads each relay's own chain for its URL. No key controls the relay set;
# rendezvous points are plural and only ever read. Relays run the same scan to find each other.
#
#   python3 xc_reldir.py accts                     # print the rendezvous anchor addresses
#   python3 xc_reldir.py announce URL [URL ...]     # each URL self-announces as its own relay
#   python3 xc_reldir.py resolve                    # scan the ledger -> relays (+ persist the list)
#   python3 xc_reldir.py engine                     # machine-readable form for the engine endpoint
import sys, json, time, urllib.request
import xc_common as xc

_HEALTH = '/tmp/xc_relay_health.json'  # rolling window of the last N up/down samples per relay

def _measure(relays, window=10):  # ping each relay: live latency + a rolling reliability %
    try:
        hist = json.load(open(_HEALTH))
    except Exception:
        hist = {}
    out = []
    for u in relays:
        up, ms = False, None
        t0 = time.time()
        try:
            urllib.request.urlopen(u + '/relays', timeout=3).read()
            up, ms = True, int((time.time() - t0) * 1000)
        except Exception:
            up = False
        h = (hist.get(u, []) + [1 if up else 0])[-window:]   # append this sample, keep last N
        hist[u] = h
        out.append({'url': u, 'up': up, 'ms': ms,
                    'reliability': round(sum(h) / len(h), 2) if h else None, 'samples': len(h)})
    for u in list(hist):                                     # forget relays no longer in the set
        if u not in relays:
            del hist[u]
    try:
        json.dump(hist, open(_HEALTH, 'w'))
    except Exception:
        pass
    return out


def announce(urls):
    urls = [u.rstrip('/') for u in urls if u.strip()]
    if not urls:
        print('no relay URLs given'); return 2
    for u in urls:
        acct, cid = xc.relay_self_announce(u)
        print(f'relay {u}\n  account {acct}\n  url-CID {cid}')
    print('rendezvous:', ', '.join(xc.rendezvous_accts()))
    return 0


def resolve():
    relays = xc.onchain_relays(ttl=0)               # force a fresh ledger scan
    print('rendezvous points :', len(xc.rendezvous_accts()), '(keyless, plural — no SPOF)')
    if not relays:
        print('no relays self-announced on-chain yet (run "announce" first)')
        return 1
    print('relays (scanned)   :')
    for r in relays:
        print('   ', r)
    with open('/tmp/xchat_bootstrap.txt', 'w') as f:
        f.write('\n'.join(relays) + '\n')
    print('persisted          : /tmp/xc_known_relays.json + /tmp/xchat_bootstrap.txt')
    return 0


def engine():  # machine-readable form for the engine's /api/relaydir endpoint
    onchain = xc.onchain_relays(ttl=60)                 # relays that self-announced on the ledger
    active = [u.rstrip('/') for u in xc.discover_relays()]   # relays actually serving this node now
    # The panel used to show ONLY the ledger scan, so it read 0/0 while a bootstrap relay was happily
    # serving the feed (the header's "1/1"). Report BOTH: the relays serving you, and how many of
    # those are ledger-announced — 0 announced is a "not SPOF-free yet" state, not "no relays".
    allr = list(dict.fromkeys(active + onchain))        # de-duped union, active first
    onchain_set = set(onchain)
    health = _measure(allr)
    for h in health:
        h['onchain'] = h['url'] in onchain_set          # announced on the ledger vs bootstrap-only
    doc = {'rendezvous': xc.rendezvous_accts(),
           'relays': onchain,                           # kept: the ledger-announced set (back-compat)
           'count': len(onchain),
           'active': active,                            # relays this node reads from right now
           'source': 'xno-scan' if onchain else ('bootstrap' if active else 'none'),
           'health': health}
    if onchain:
        try:
            open('/tmp/xchat_bootstrap.txt', 'w').write('\n'.join(onchain) + '\n')
        except Exception:
            pass
    with open('/tmp/xc_relaydir.json', 'w') as f:
        json.dump(doc, f)
    print(json.dumps(doc))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'resolve'
    if cmd == 'accts':
        print('\n'.join(xc.rendezvous_accts())); sys.exit(0)
    if cmd == 'announce':
        sys.exit(announce(sys.argv[2:]))
    if cmd == 'resolve':
        sys.exit(resolve())
    if cmd == 'engine':
        sys.exit(engine())
    print('usage: xc_reldir.py accts|announce URL...|resolve|engine'); sys.exit(2)
