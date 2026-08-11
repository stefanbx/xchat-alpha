#!/usr/bin/env python3
# A ӾChat RELAY. Holds signed author HEADS ({author, handle, seq, cid, expires, sig, pub}),
# gossips relay membership (bootstrap + /relays), and expires stale heads (TTL). Independent
# and swappable — run several; clients DISCOVER the set from a bootstrap, no hardcoding.
# Usage: xc_relayd.py <port> <store.json> [bootstrap_url ...]
import json, sys, os, time, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import importlib.util
xc = None                                       # xc_common: relay account + pay-to-pin ledger reads
_here = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_here, "xc_common.py"),          # staged next to the relay (deploy)
           os.path.join(_here, "..", "backend", "xc_common.py")):  # repo layout
    if os.path.exists(_p):
        try:
            _spec = importlib.util.spec_from_file_location("xc_common", _p)
            xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)
            break
        except Exception:
            xc = None

PORT = int(sys.argv[1]); STORE = sys.argv[2]
BIND = os.environ.get('BIND_HOST', '127.0.0.1')      # '0.0.0.0' when hosted (Fly.io)
# public URL other nodes reach this relay at; defaults to loopback for local runs
SELF = os.environ.get('RELAY_PUBLIC_URL', f'http://127.0.0.1:{PORT}')
# this relay's Nano account (for tip-split rewards). Env-first so a hosted relay (Fly.io / Linux)
# needs no Mac-native key tool; falls back to deriving it locally.
RELAY_ACCT = os.environ.get('RELAY_ACCT') or ''
if not RELAY_ACCT and xc is not None:
    try:
        RELAY_ACCT = xc.acct(0x50 + (PORT - 7401))
    except Exception:
        RELAY_ACCT = ''
engage = {}                                    # post_id -> {"likes": n, "tips_raw": int}
BOOTSTRAPS = sys.argv[3:]
heads = {}
notifs = {}
supporters = {}
blobs = {}                           # cid -> base64 content (a relay is also a content cache)
follows = {}                         # account -> signed follow-list record (portable follow graph)
comments = {}                        # post_id -> list of signed comment events (off-chain replies)
releases = {}                        # publisher account -> signed release record (self-update head)
profiles = {}                        # account -> signed profile record (display name, bio, avatar/banner CIDs)
dmkeys = {}                          # account -> signed X25519 DM public key record (E2E encryption)
dms = []                             # list of encrypted direct messages (ciphertext only; relay can't read)
pollvotes = {}                       # poll_id -> {account: signed vote record} (one vote per account)
known = {SELF}                       # relays this relay knows about

# --- content cache: a relay is a CACHE, not an archive ---
# Blobs are held under a byte cap and evicted least-recently-used, so the store can't grow without
# bound and OOM the box. Pay-to-pin (below) is the exception: a CID someone has PAID to keep is
# protected from eviction until the paid span elapses. Heads already expire on their own TTL.
BLOB_CAP = int(float(os.environ.get('XC_BLOB_CAP_MB', '128')) * 1024 * 1024)   # cache size ceiling
PIN_DAYS_PER_XNO = float(os.environ.get('XC_PIN_DAYS_PER_XNO', '30000'))       # 0.001 XNO ≈ 30 days pinned
_PIN_S_PER_RAW = PIN_DAYS_PER_XNO * 86400.0 / 1e30
pinned = {}                          # cid -> pin-expiry epoch (paid); survives eviction until then
pins_paid = {}                       # payment block hash -> cid (consumed once; audit + no double-claim)
blob_meta = {}                       # cid -> {'size': bytes, 'last': epoch}  (LRU bookkeeping; rebuilt on load)
_blob_lock = threading.Lock()

def _blob_total():
    return sum(m['size'] for m in blob_meta.values())

def blob_put(cid, b64, tips=0.0):
    with _blob_lock:
        blobs[cid] = b64
        m = blob_meta.get(cid) or {}
        m.update({'size': len(b64 or ''), 'last': time.time(),
                  'tips': max(float(tips or 0), float(m.get('tips', 0)))})   # value only ratchets up
        blob_meta[cid] = m
        _evict_locked()

def blob_touch(cid):                 # a read counts as use, so popular content isn't the first evicted
    m = blob_meta.get(cid)
    if m:
        m['last'] = time.time()

def _evict_locked():
    # Keep everything until the cap is reached, then drop the LEAST-VALUABLE unpinned blobs first:
    # untipped before tipped, and within a tip level the least-recently-used. So old + untipped go
    # first, well-tipped content stays longest, and paid pins are never touched. (Sync, elsewhere,
    # replicates the most-valued; the weak stay single-copy; evicted is gone.)
    total = _blob_total()
    if total <= BLOB_CAP:
        return
    now = time.time()
    victims = sorted((m.get('tips', 0.0), m['last'], c)
                     for c, m in blob_meta.items() if pinned.get(c, 0) <= now)   # low value + old first
    for _tips, _last, c in victims:
        if total <= BLOB_CAP:
            break
        total -= blob_meta[c]['size']
        blobs.pop(c, None)
        blob_meta.pop(c, None)

def blob_rebuild_meta():             # after a restart, rebuild sizes from the loaded blobs
    now = time.time()
    for c, b in list(blobs.items()):
        blob_meta.setdefault(c, {'size': len(b or ''), 'last': now, 'tips': 0.0})

def grant_pin(cid, payhash):
    # PAY-TO-PIN: verify payhash is a confirmed Nano send TO this relay's account, then protect cid
    # from eviction for a span proportional to the amount. A public ledger read — no key needed, the
    # relay never moves funds; the PINNER paid. Each payment is consumed once (no double-claim).
    if xc is None or not RELAY_ACCT or not cid or not payhash or payhash in pins_paid:
        return 0
    try:
        bi = xc.rpc({'action': 'block_info', 'json_block': 'true', 'hash': payhash})
        c = bi.get('contents', {})
        to_us = (c.get('link_as_account') == RELAY_ACCT
                 or c.get('link', '').upper() == xc.nano_to_pub(RELAY_ACCT).upper())
        amt = int(bi.get('amount', '0'))
    except Exception:
        return 0
    if not to_us or amt <= 0:
        return 0
    pins_paid[payhash] = cid
    exp = max(pinned.get(cid, 0.0), time.time()) + amt * _PIN_S_PER_RAW
    pinned[cid] = exp
    save()
    return exp

# --- persistence: the WHOLE relay state survives a restart, not just heads ---
# (in-memory before this meant comments, uploaded media, likes, poll votes vanished on restart)
_STATE_KEYS = ('engage', 'notifs', 'supporters', 'blobs', 'follows', 'comments',
               'releases', 'profiles', 'dmkeys', 'dms', 'pollvotes', 'pinned', 'pins_paid')

def load_state():
    global heads
    if not os.path.exists(STORE):
        return
    try:
        d = json.load(open(STORE))
        if isinstance(d, list):                      # legacy format: a bare list of heads
            heads = {h['author']: h for h in d}
            return
        heads = {h['author']: h for h in d.get('heads', [])}
        for k in _STATE_KEYS:
            v = d.get(k)
            g = globals()[k]                          # freshly-empty dict/list at import time
            if isinstance(g, dict) and isinstance(v, dict):
                g.update(v)
            elif isinstance(g, list) and isinstance(v, list):
                g.extend(v)
    except Exception:
        pass

def save():
    # atomic write of the full state (heads + everything else)
    state = {'heads': list(heads.values())}
    for k in _STATE_KEYS:
        state[k] = globals()[k]
    tmp = STORE + '.tmp'
    try:
        json.dump(state, open(tmp, 'w'))
        os.replace(tmp, STORE)
    except Exception:
        pass

load_state()
blob_rebuild_meta()

def _autosave():                                     # flush every few seconds so a restart loses ≤5s
    while True:
        time.sleep(5)
        save()
threading.Thread(target=_autosave, daemon=True).start()

def qs(path):
    return {k: v[0] for k, v in parse_qs(urlparse(path).query).items()}

def post_json(url, obj):
    try:
        urllib.request.urlopen(urllib.request.Request(url, json.dumps(obj).encode(),
                               {'Content-Type': 'application/json'}), timeout=3).read()
    except Exception:
        pass

def bootstrap():
    time.sleep(0.4)
    for bp in BOOTSTRAPS:
        known.add(bp)
        post_json(bp + '/relay_announce', {'url': SELF})   # tell the bootstrap we exist
        try:
            d = json.loads(urllib.request.urlopen(bp + '/relays', timeout=3).read())
            for u in d.get('relays', []):
                known.add(u)
        except Exception:
            pass

def live_heads():
    now = time.time()
    return [h for h in heads.values() if h.get('expires', 9e18) >= now]   # drop expired pointers

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/heads'):
            self._send(200, json.dumps({'relay': PORT, 'heads': live_heads()}))
        elif self.path.startswith('/relays'):
            self._send(200, json.dumps({'relay': PORT, 'relays': sorted(known)}))
        elif self.path.startswith('/notify'):
            h = qs(self.path).get('handle', '')
            self._send(200, json.dumps({'relay': PORT, 'notifs': notifs.get(h, [])}))
        elif self.path.startswith('/supporters'):
            self._send(200, json.dumps({'relay': PORT, 'count': len(supporters),
                                        'accounts': list(supporters.keys())}))
        elif self.path.startswith('/blob'):
            cid = qs(self.path).get('cid', '')
            blob_touch(cid)                                             # a read is use → LRU keeps it longer
            self._send(200, json.dumps({'cid': cid, 'b64': blobs.get(cid)}))   # serve cached content
        elif self.path.startswith('/cache'):                           # cache health: size vs cap, pins
            now = time.time()
            self._send(200, json.dumps({'relay': PORT, 'blobs': len(blobs), 'bytes': _blob_total(),
                                        'cap': BLOB_CAP, 'pinned': sum(1 for e in pinned.values() if e > now)}))
        elif self.path.startswith('/haveblob'):
            cid = qs(self.path).get('cid', '')
            self._send(200, json.dumps({'cid': cid, 'have': cid in blobs,
                                        'pinned_until': int(pinned.get(cid, 0))}))
        elif self.path.startswith('/followers'):
            # count how many stored follow-records include this account (for a profile's follower tally)
            acc = qs(self.path).get('account', '')
            n = sum(1 for rec in follows.values() if acc in (rec.get('follows') or []))
            self._send(200, json.dumps({'account': acc, 'followers': n}))
        elif self.path.startswith('/follows'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': follows.get(acc)}))
        elif self.path.startswith('/profile'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': profiles.get(acc)}))
        elif self.path.startswith('/dmkey'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': dmkeys.get(acc)}))
        elif self.path.startswith('/pollvotes'):
            pid = qs(self.path).get('poll', '')
            self._send(200, json.dumps({'poll': pid, 'votes': list(pollvotes.get(pid, {}).values())}))
        elif self.path.startswith('/dm'):
            # every encrypted message this account is a party to (ciphertext only — relay can't read)
            acc = qs(self.path).get('account', '')
            mine = [m for m in dms if m.get('to') == acc or m.get('from') == acc]
            self._send(200, json.dumps({'account': acc, 'dms': mine}))
        elif self.path.startswith('/comments'):
            pid = qs(self.path).get('post', '')
            self._send(200, json.dumps({'post': pid, 'comments': comments.get(pid, [])}))
        elif self.path.startswith('/releases'):
            pub = qs(self.path).get('pub', '')
            self._send(200, json.dumps({'pub': pub, 'records': releases.get(pub, [])}))
        elif self.path.startswith('/engagement'):
            self._send(200, json.dumps({'relay': PORT, 'engage': engage}))
        elif self.path.startswith('/relayacct'):
            self._send(200, json.dumps({'port': PORT, 'account': RELAY_ACCT}))
        else:
            self._send(404, '{"error":"not found"}')
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(n) if n else b'{}'
        if self.path.startswith('/push'):
            try:
                h = json.loads(raw); cur = heads.get(h['author'])
                if cur is None or h.get('seq', 0) > cur.get('seq', 0) or h.get('expires', 0) > cur.get('expires', 0):
                    heads[h['author']] = h; save()          # newer seq OR a fresher TTL (republish)
                    self._send(200, '{"ok":true,"accepted":true}')
                else:
                    self._send(200, '{"ok":true,"accepted":false,"reason":"stale"}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/relay_announce'):
            try:
                u = json.loads(raw).get('url', '')
                if u and u != SELF:
                    known.add(u)
                self._send(200, json.dumps({'ok': True, 'relays': sorted(known)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/notify_push'):
            try:
                m = json.loads(raw); to = m['to']
                notifs.setdefault(to, []).append({'from': m.get('from', ''), 'text': m.get('text', ''),
                                                  'ts': m.get('ts', 0), 'kind': m.get('kind', 'mention')})
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/supporter'):
            try:
                m = json.loads(raw); acc = m['account']
                if m.get('on'):
                    supporters[acc] = m.get('ts', 0)
                else:
                    supporters.pop(acc, None)
                self._send(200, json.dumps({'ok': True, 'count': len(supporters)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/blob'):
            # a supporter caches content here (content-addressed — cid names the bytes); byte-capped + LRU
            try:
                m = json.loads(raw); cid = m['cid']; new = cid not in blobs
                blob_put(cid, m['b64'], tips=m.get('tips', 0))   # tips = the post's value, ranks eviction
                self._send(200, json.dumps({'ok': True, 'stored': new, 'cache_bytes': _blob_total()}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/pin'):
            # PAY-TO-PIN: {cid, payhash} — protect cid from eviction, paid for by a Nano send to this relay
            try:
                m = json.loads(raw or '{}')
                cid = m.get('cid') or qs(self.path).get('cid', '')
                payhash = m.get('payhash') or qs(self.path).get('payhash', '')
                exp = grant_pin(cid, payhash)
                if exp:
                    self._send(200, json.dumps({'ok': True, 'cid': cid, 'pinned_until': int(exp),
                                                'days': round((exp - time.time()) / 86400, 2)}))
                else:
                    self._send(402, json.dumps({'ok': False, 'pay_to': RELAY_ACCT,
                                                'rate_days_per_xno': PIN_DAYS_PER_XNO,
                                                'error': 'no unconsumed confirmed payment to this relay for that cid'}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/follows'):
            # signed follow-list record, keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = follows.get(acc)
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    follows[acc] = m
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/profile'):
            # signed profile record (display name, bio, avatar/banner CIDs), keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = profiles.get(acc)
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    profiles[acc] = m
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/dmkey'):
            # signed X25519 DM public-key record, keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = dmkeys.get(acc)
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    dmkeys[acc] = m
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/pollvote'):
            # one signed vote per account per poll; latest ts wins (lets a voter change their choice)
            try:
                m = json.loads(raw); pid = m['poll_id']; acc = m['account']
                votes = pollvotes.setdefault(pid, {})
                if acc not in votes or m.get('ts', 0) >= votes[acc].get('ts', 0):
                    votes[acc] = m
                self._send(200, json.dumps({'ok': True, 'total': len(votes)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/dm'):
            # store an encrypted DM (dedup by (from, ts)). The relay only holds ciphertext.
            try:
                m = json.loads(raw); key = (m.get('from'), m.get('ts'))
                if not any((x.get('from'), x.get('ts')) == key for x in dms):
                    dms.append(m)
                self._send(200, json.dumps({'ok': True, 'stored': len(dms)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/release'):
            # append-only list of signed release records per publisher. The relay does NOT verify
            # (clients do) — so a FORGED record can be stored, but keeping a LIST means it can't
            # EVICT the real one: on check the client keeps the highest VALID (signed) version.
            try:
                m = json.loads(raw); pub = m['publisher']
                lst = releases.setdefault(pub, [])
                if not any(x.get('sig') == m.get('sig') for x in lst):
                    lst.append(m)
                releases[pub] = lst[-24:]                 # cap; real record survives forged noise
                self._send(200, json.dumps({'ok': True, 'stored': len(releases[pub])}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/comment'):
            # a signed off-chain reply. Stored under its parent post; dedup by (account, ts).
            # Verification (sig + pub↔account) happens client-side on fetch, like /follows.
            try:
                m = json.loads(raw); pid = m['post_id']
                lst = comments.setdefault(pid, [])
                key = (m.get('account'), m.get('ts'))
                if not any((c.get('account'), c.get('ts')) == key for c in lst):
                    lst.append(m)
                self._send(200, json.dumps({'ok': True, 'count': len(lst)}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/like'):
            try:
                m = json.loads(raw); e = engage.setdefault(m['post_id'], {'likes': 0, 'tips_raw': 0, 'reposts': 0})
                e['likes'] = max(0, e.get('likes', 0) + int(m.get('delta', 1)))
                self._send(200, json.dumps({'ok': True, 'likes': e['likes']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/repost'):
            try:
                m = json.loads(raw); e = engage.setdefault(m['post_id'], {'likes': 0, 'tips_raw': 0, 'reposts': 0})
                delta = int(m.get('delta', 1)); acc = m.get('account')
                e['reposts'] = max(0, e.get('reposts', 0) + delta)
                # record WHO reshared, earliest-first (so tips can reward the spreader). Dedup.
                rs = e.setdefault('resharers', [])
                if acc:
                    if delta > 0 and acc not in rs:
                        rs.append(acc)
                    elif delta < 0 and acc in rs:
                        rs.remove(acc)
                self._send(200, json.dumps({'ok': True, 'reposts': e['reposts'], 'resharers': rs}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/tipstat'):
            try:
                m = json.loads(raw); e = engage.setdefault(m['post_id'], {'likes': 0, 'tips_raw': 0, 'reposts': 0})
                e['tips_raw'] += int(m.get('raw', 0))
                self._send(200, json.dumps({'ok': True, 'tips_raw': e['tips_raw']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/view'):
            # impression counter for a post or comment cid (client dedups one view per session)
            try:
                m = json.loads(raw); e = engage.setdefault(m['post_id'], {'likes': 0, 'tips_raw': 0, 'reposts': 0})
                e['views'] = e.get('views', 0) + int(m.get('delta', 1))
                self._send(200, json.dumps({'ok': True, 'views': e['views']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        else:
            self._send(404, '{"error":"not found"}')

if BOOTSTRAPS:
    threading.Thread(target=bootstrap, daemon=True).start()
ThreadingHTTPServer((BIND, PORT), H).serve_forever()
