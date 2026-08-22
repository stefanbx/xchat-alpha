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
import os, sys, json, time, urllib.request
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


def announce_mainnet(urls):
    # MAINNET announce with an OPERATOR's funded key (no dev genesis, URL-in-link as ASCII).
    # Key comes from the environment so it never lands in a command line or the repo:
    #   XC_RELAY_OPERATOR_SEED=<64-hex seed>   (index 0)   OR   XC_RELAY_OPERATOR_KEY=<64-hex privkey>
    import os
    keyhex = os.environ.get('XC_RELAY_OPERATOR_KEY', '')
    seed = os.environ.get('XC_RELAY_OPERATOR_SEED', '')
    if seed and not keyhex:
        import nanopy
        keyhex = nanopy.deterministic_key(seed, 0)
    if not keyhex:
        print('set XC_RELAY_OPERATOR_SEED (64-hex) or XC_RELAY_OPERATOR_KEY (funded account)'); return 2
    urls = [u for u in urls if u.strip()]
    if not urls:
        print('usage: xc_reldir.py announce-mainnet URL [URL ...]'); return 2
    # This is a MAINNET action, but xc_common defaults XC_NANO_RPC to a local DEV node — which is a
    # different ledger and can't see the operator's real funds. Unless the operator explicitly pointed
    # XC_NANO_RPC at their own mainnet node, use public mainnet proxies for ledger reads + broadcast
    # (PoW goes to WORK_RPCS separately, since the proxies refuse work_generate).
    if any(('127.0.0.1' in u or 'localhost' in u) for u in xc.RPCS):
        xc.RPCS = ['https://nanoslo.0x.no/proxy', 'https://rainstorm.city/api', 'https://node.somenano.com/proxy']
        print('mainnet RPCs:', ', '.join(xc.RPCS), '| PoW:', ', '.join(xc.WORK_RPCS))
    for u in urls:
        acct, url = xc.relay_announce_operator(u, keyhex)
        print(f'announced {url}\n  operator account {acct}')
    print('rendezvous:', ', '.join(xc.rendezvous_accts()))
    print('discovery will see it on the next ledger scan (xc_reldir.py resolve)')
    return 0


def ensure(urls):
    # IDEMPOTENT self-announce, meant to run on every node/relay startup. Reads the operator key from the
    # ENV (a secret — never a CLI arg) and the URL from the arg or NODE_PUBLIC_URL / RELAY_PUBLIC_URL.
    # Announces ONLY if this URL isn't already the operator account's readable on-chain URL, so restarts
    # don't spam the ledger. NON-FATAL by design: no key, unfunded, or RPC down all log-and-return 0 —
    # self-announce must never delay or block the node from serving. Fund the operator account once and
    # set XC_RELAY_OPERATOR_SEED; the node then keeps itself discoverable with no manual step.
    import os
    keyhex = os.environ.get('XC_RELAY_OPERATOR_KEY', '')
    seed = os.environ.get('XC_RELAY_OPERATOR_SEED', '')
    if seed and not keyhex:
        try:
            import nanopy
            keyhex = nanopy.deterministic_key(seed, 0)
        except Exception as e:
            print('self-announce: bad XC_RELAY_OPERATOR_SEED:', str(e)[:80]); return 0
    if not keyhex:
        print('self-announce: no XC_RELAY_OPERATOR_SEED/KEY set — skipping (ledger discovery stays manual)')
        return 0
    url = (urls[0] if urls else '') or os.environ.get('NODE_PUBLIC_URL', '') or os.environ.get('RELAY_PUBLIC_URL', '')
    if not url:
        print('self-announce: no URL (set NODE_PUBLIC_URL or pass one) — skipping'); return 0
    # A mainnet action: if the operator hasn't pointed XC_NANO_RPC at their own mainnet node, use public
    # mainnet proxies for reads+broadcast (PoW goes to WORK_RPCS separately).
    if any(('127.0.0.1' in u or 'localhost' in u) for u in xc.RPCS):
        xc.RPCS = ['https://nanoslo.0x.no/proxy', 'https://rainstorm.city/api', 'https://node.somenano.com/proxy']
    want = xc.url_norm(url)
    try:
        acct = xc.derive(keyhex)[0]
        cur = xc._relay_url(acct)                          # URL (if any) this account already announces
        if cur and xc.url_norm(cur) == want:
            print(f'self-announce: {want} already on-chain (operator {acct}) — nothing to do'); return 0
    except Exception as e:
        print('self-announce: pre-check inconclusive, will announce:', str(e)[:80])
    try:
        a, u = xc.relay_announce_operator(url, keyhex)
        print(f'self-announced {u} (operator {a})'); return 0
    except Exception as e:
        print(f'self-announce failed (non-fatal): {str(e)[:160]}'); return 0


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
    # Hide persistently-dead relays from the panel: a ledger-announced relay that is down AND has 0%
    # uptime in the rolling window (answered no probe) is just noise — e.g. an old lhr.life tunnel a peer
    # abandoned. Keep anything up or recently-flapping (reliability > 0). Server-side so even clients that
    # predate the app-side filter stop showing them.
    health = [h for h in health if h.get('up') or (h.get('reliability') or 0) > 0]
    doc = {'rendezvous': xc.rendezvous_accts(),
           'relays': onchain,                           # kept: the ledger-announced set (back-compat)
           'count': len(onchain),
           'active': active,                            # relays this node reads from right now
           'source': 'xno-scan' if onchain else ('bootstrap' if active else 'none'),
           'health': health}
    # NB: do NOT overwrite the bootstrap file with only the ledger set — that would drop this node's
    # own co-located relay. onchain_relays() already caches the discovered set; _bootstrap unions them.
    with open('/tmp/xc_relaydir_%s.json' % os.environ.get('XC_NS', ''), 'w') as f:
        json.dump(doc, f)
    print(json.dumps(doc))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'resolve'
    if cmd == 'accts':
        print('\n'.join(xc.rendezvous_accts())); sys.exit(0)
    if cmd == 'announce':
        sys.exit(announce(sys.argv[2:]))
    if cmd == 'announce-mainnet':
        sys.exit(announce_mainnet(sys.argv[2:]))
    if cmd == 'ensure':
        sys.exit(ensure(sys.argv[2:]))
    if cmd == 'resolve':
        sys.exit(resolve())
    if cmd == 'engine':
        sys.exit(engine())
    print('usage: xc_reldir.py accts|announce URL...|announce-mainnet URL...|ensure [URL]|resolve|engine')
    sys.exit(2)
