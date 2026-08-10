#!/usr/bin/env python3
# A ӾChat RELAY. Holds signed author HEADS ({author, handle, seq, cid, expires, sig, pub}),
# gossips relay membership (bootstrap + /relays), and expires stale heads (TTL). Independent
# and swappable — run several; clients DISCOVER the set from a bootstrap, no hardcoding.
# Usage: xc_relayd.py <port> <store.json> [bootstrap_url ...]
import json, sys, os, time, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import importlib.util
try:                                            # xc_common only needed to DERIVE this relay's account
    _spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(os.path.abspath(__file__)), "xc_common.py"))
    xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)
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

# --- persistence: the WHOLE relay state survives a restart, not just heads ---
# (in-memory before this meant comments, uploaded media, likes, poll votes vanished on restart)
_STATE_KEYS = ('engage', 'notifs', 'supporters', 'blobs', 'follows', 'comments',
               'releases', 'profiles', 'dmkeys', 'dms', 'pollvotes')

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
            self._send(200, json.dumps({'cid': cid, 'b64': blobs.get(cid)}))   # serve cached content
        elif self.path.startswith('/haveblob'):
            cid = qs(self.path).get('cid', '')
            self._send(200, json.dumps({'cid': cid, 'have': cid in blobs}))
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
            # a supporter pins content here (content-addressed — cid names the bytes)
            try:
                m = json.loads(raw); cid = m['cid']; new = cid not in blobs
                blobs[cid] = m['b64']
                self._send(200, json.dumps({'ok': True, 'stored': new}))
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
