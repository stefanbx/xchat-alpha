#!/usr/bin/env python3
# ӾChat encrypted DIRECT MESSAGES — end-to-end, keyed to the Nano identity.
#
# ON-DEVICE: all X25519 crypto_box sealing/opening happens IN THE APP (pinenacl, byte-compatible with
# PyNaCl). This node helper holds NO seed and does NO decryption — it only:
#   register  — verifies an APP-SIGNED DM-public-key record and relays it (so peers can encrypt to us)
#   keyget    — fetches + verifies a peer's DM public key
#   send      — relays an APP-SEALED ciphertext record (the relays only ever see ciphertext)
#   inbox     — returns the RAW ciphertext records for an account; the APP decrypts them locally
# (No `nacl` import → no special interpreter needed anymore.)
# Usage: xc_dm.py register | keyget | send | inbox
import json, os, sys, time, urllib.parse, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'inbox'


def rd(p, d=''):
    return open(p).read().strip() if os.path.exists(p) else d


def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False


def post(path, obj):
    # Fan out to every relay IN PARALLEL. Serially, one dead relay blocks the whole write behind its
    # 4s timeout — and with a relay in the set down (a sleeping laptop, a churned tunnel), that is why
    # sending a DM would spin for 15-30s while the recipient's own relay timed out. This is the send
    # side of the same fix already applied to the inbox read: the fan-out now costs the SLOWEST single
    # relay (~4s worst case), not the sum, so one down relay can no longer stall a send for everyone.
    import concurrent.futures as _cf
    body = json.dumps(obj).encode()

    def _one(r):
        try:
            urllib.request.urlopen(urllib.request.Request(
                r + path, body, {'Content-Type': 'application/json'}), timeout=4).read()
            return 1
        except Exception:
            return 0

    if not RELAYS:
        return 0
    with _cf.ThreadPoolExecutor(max_workers=len(RELAYS)) as ex:
        return sum(ex.map(_one, RELAYS))


def peer_dm_pk(account):                                   # fetch + verify a peer's signed DM public key
    # Query relays IN PARALLEL and take the first VERIFIED key. Serially, a dead relay ahead of a live
    # one cost its full 4s timeout before the key was even fetched — and this runs BEFORE every send,
    # so it stacked with the send fan-out to make "message a peer" spin. The verification is per-record
    # (signature bound to the account), so accepting whichever verified answer returns first is safe:
    # a relay cannot forge a key, only fail to have one.
    import concurrent.futures as _cf

    def _one(r):
        try:
            rec = json.loads(urllib.request.urlopen(
                r + '/dmkey?account=' + account, timeout=4).read()).get('record')
            if not rec:
                return None
            msg = xc.sig_canon('dmkey', rec['account'], rec['ts'], rec['dm_pk'])
            if rec['account'] == account and xc.pub_to_addr(rec['pub']) == account \
               and verify(rec['pub'], msg, rec['sig']):
                return rec['dm_pk']
        except Exception:
            pass
        return None

    if not RELAYS:
        return None
    with _cf.ThreadPoolExecutor(max_workers=len(RELAYS)) as ex:
        for pk in ex.map(_one, RELAYS):
            if pk:
                return pk
    return None


if mode == 'register':
    # The DM-key record is ALREADY SIGNED BY THE APP. Verify the Nano-key binding, then relay it.
    rec = json.load(open('/tmp/xc_dm_rec.json'))
    acc = rec.get('account', ''); dm_pk = rec.get('dm_pk', ''); ts = rec.get('ts')
    sig = rec.get('sig', ''); pub = rec.get('pub', '')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, xc.sig_canon('dmkey', acc, ts, dm_pk), sig)):
        json.dump({'ok': False, 'error': 'bad signature'}, open('/tmp/xc_dm_result.json', 'w')); sys.exit()
    relays = post('/dmkey', {'account': acc, 'dm_pk': dm_pk, 'ts': ts, 'sig': sig, 'pub': pub})
    json.dump({'ok': True, 'relays': relays}, open('/tmp/xc_dm_result.json', 'w'))

elif mode == 'keyget':
    account = rd('/tmp/xc_dm_peer.txt')
    json.dump({'ok': True, 'account': account, 'dm_pk': peer_dm_pk(account)},
              open('/tmp/xc_dm_result.json', 'w'))

elif mode == 'send':
    # The record is ALREADY SEALED BY THE APP (nonce+ciphertext in `ct`). The node just relays it.
    msg = json.load(open('/tmp/xc_dm_msg.json'))
    relays = post('/dm', msg)
    json.dump({'ok': True, 'relays': relays, 'ts': msg.get('ts')}, open('/tmp/xc_dm_result.json', 'w'))

else:                                                      # inbox: return RAW ciphertext records (app decrypts)
    acc = rd('/tmp/xc_dm_acct.txt')
    # INCREMENTAL: with ?since=<unix>, return only ciphertext at or after it. The app keeps every
    # message it has already decrypted, so re-sending the whole history on every 5s poll is pure
    # transfer for nothing — and it grows forever.
    #
    # The app deliberately asks with an OVERLAP rather than its exact newest timestamp, and does a
    # full sweep periodically, because `since` is not safe on its own: relays gossip, so a message can
    # arrive here AFTER one with a later ts, and a strict cutoff would skip it permanently. Filtering
    # is cheap and correctness lives on the client, which is the only side that knows what it holds.
    try:
        since = int(rd('/tmp/xc_dm_since.txt', '0') or 0)
    except ValueError:
        since = 0
    # The app signs "I own this mailbox" and the node forwards it verbatim. The node CANNOT produce
    # this itself — it holds no seed — which is the point: a relay that enforces is trusting the
    # account's own key, not the node vouching for whoever asked.
    auth = rd('/tmp/xc_dm_auth.json', '')
    qs = ''
    if auth:
        try:
            a = json.loads(auth)
            if a.get('sig') and a.get('pub') and a.get('ts'):
                qs = '&ts=%d&sig=%s&pub=%s' % (int(a['ts']),
                                               urllib.parse.quote(a['sig']),
                                               urllib.parse.quote(a['pub']))
        except Exception:
            qs = ''
    # Fetch every relay IN PARALLEL. Serially, one dead quick-tunnel at the 4s timeout blocks all the
    # others behind it, so an inbox read cost ~10s with a few dead relays in the set — slow on its own
    # and, run under the node's DM lock, slow enough to starve every other DM request (that outage is
    # written up in kt_server's _dm_watch). In parallel the whole fan-out costs the SLOWEST single
    # relay, ~4s worst case, and a healthy set answers in well under a second.
    import concurrent.futures as _cf

    def _one(r):
        try:
            return json.loads(urllib.request.urlopen(
                r + '/dm?account=' + acc + qs, timeout=4).read()).get('dms', [])
        except Exception:
            return []

    seen = set(); dms = []
    with _cf.ThreadPoolExecutor(max_workers=max(1, len(RELAYS))) as ex:
        for got in ex.map(_one, RELAYS):
            for m in got:
                k = (m.get('from'), m.get('ts'))
                if k in seen:
                    continue
                seen.add(k)
                if since and int(m.get('ts') or 0) < since:
                    continue
                dms.append(m)
    json.dump({'ok': True, 'account': acc, 'since': since, 'dms': dms},
              open('/tmp/xc_dm_result.json', 'w'))
