# xc_tunnel.py — mesh reverse-tunnel: reach a relay behind NAT without any external service, and
# WITHOUT the entry node ever learning which relay it is carrying.
#
# THE PROBLEM. A relay on a home machine / laptop is behind NAT: it can dial OUT but nothing can dial
# IN. The usual fix is a third-party tunnel (Cloudflare, localhost.run, Tailscale) — an external service
# and, worse, a single point of failure. This is the self-hosted, no-SPOF alternative.
#
# THE SHAPE. Any xchat node with a public IP can act as an ENTRY node (a capability, advertised on-chain
# like s1/r1 — permissionless, plural, no owner). A home relay opens OUTBOUND long-poll connections to
# SEVERAL entry nodes at once. A public request to any entry is framed and handed down the held
# connection to the home relay, which serves it against its own local port and posts the response back.
# Kill any one entry node and the relay stays reachable through the others — no single point of failure.
# The entry nodes are discovered on the ledger (on-chain rendezvous), so there is no directory.
#
# ANONYMITY — why routing is by TOKEN, not by ledger account (Layer A). An entry node is the thing
# relaying bytes, so it inevitably sees the flows it carries. What it must NOT be able to do is tie a
# flow to the relay's stable identity. Earlier this transport routed on /r/<account> and signed every
# poll with the relay's LEDGER key, which handed each entry exactly that: "account X is a relay I carry",
# cross-referenceable against the chain and against relaykey records, stable forever. So instead:
#
#   token = pubkey( KDF(rendezvous_secret, entry_id, epoch) )
#
# The relay registers at each entry under this ephemeral pubkey and signs its polls/replies with the
# matching ephemeral key — never the ledger key. The entry learns only an opaque pubkey that (a) is not
# the account and cannot be inverted to it, (b) is DIFFERENT at every entry (entry_id in the KDF), so
# colluding entries can't link a relay across them, and (c) ROTATES every epoch, so no entry can
# aggregate a relay's traffic over time. Clients that hold the rendezvous_secret derive the same token
# and address the relay as /r/<token>/...; the real account rides end-to-end INSIDE the request the
# relay serves, never as the routing key. The secret is shared out-of-band by the operator with the
# users who should reach a private relay (the same private-relay model that keeps it off the ledger).
#
# WHAT LAYER A DOES NOT HIDE. A single forwarding hop can still correlate "this inbound client request
# ↔ this backend poll/reply" by timing, and knows the token is reachable through it right now. Defeating
# that (so no single node sees both ends at once) needs ≥2 hops / a mix layer — Layer B, built on top of
# this token abstraction, separate feature.
#
# WHY LONG-POLL and not WebSocket. Both ends are stdlib http.server (request/response, no ws). A hanging
# GET for work + a POST for the reply needs nothing but http, and passes through every HTTP ingress
# (Fly included) untouched. One extra round-trip of latency, a fine trade for zero new dependencies.
#
# AUTH. Every poll/reply is signed by the token's ephemeral key over a canon that includes the entry's
# own id, so the entry verifies possession of the token key (nobody can register as, or reply for, a
# token whose key they lack) AND a poll captured at one entry can't be replayed at another (its entry_id
# won't match). A freshness window bounds replay. The entry needs neither the relay's key nor its account.

import base64
import hashlib
import json
import os
import queue
import threading
import time
import urllib.request

# --- tunables (env-overridable) --------------------------------------------------------------------
POLL_HOLD_S    = int(os.environ.get('XC_TUNNEL_POLL_HOLD_S', '25'))    # entry holds a poll open this long with no work → 204
PUBLIC_WAIT_S  = int(os.environ.get('XC_TUNNEL_PUBLIC_WAIT_S', '30'))  # public request waits this long for the reply → 504
REFRESH_S      = int(os.environ.get('XC_TUNNEL_REFRESH_S', '60'))      # how often the home relay re-discovers the entry set
EPOCH_S        = int(os.environ.get('XC_TUNNEL_EPOCH_S', '3600'))      # routing-token rotation period (entry can't aggregate past it)
ENTRY_CAP      = 't1'    # capability an entry node advertises on /relays; home relays discover entries by it
CLOCK_SKEW_S   = 120     # accepted |now - ts| on a signed poll/reply — bounds replay
WORKERS        = 4       # parallel poll loops per (entry, epoch) = max concurrent in-flight requests per token
DISPATCH_TO_S  = 20      # timeout dispatching a framed request against the home relay's own local port
_FWD_REQ_HDRS  = ('Content-Type',)   # request headers carried down the tunnel (kept tiny on purpose)
_FWD_RESP_HDRS = ('Content-Type',)   # response headers carried back up
_KDF_DOMAIN    = b'xchat/mesh-tunnel/v1'   # domain separation for the routing-token KDF


# ================================ ROUTING TOKENS (shared by both ends) ==============================
# A per-(entry, epoch) ephemeral keypair derived from the relay's rendezvous secret. The PUBLIC key is
# the routing id the entry sees; the private key signs the relay's polls/replies. A client holding the
# same secret derives the identical token and addresses the relay by it — no ledger account involved.

def epoch_now(now=None):
    return int((time.time() if now is None else now) // EPOCH_S)

def token_seed(secret, entry_id, epoch):
    """Deterministic 32-byte private-key hex for this (entry, epoch). `secret` is the shared rendezvous
    secret (opaque string); `entry_id` is the entry's canonical url (scheme-less), which makes the token
    differ per entry so colluding entries can't link a relay across them."""
    pre = b'|'.join([_KDF_DOMAIN, secret.encode(), entry_id.encode(), str(int(epoch)).encode()])
    return hashlib.blake2b(pre, digest_size=32).hexdigest()

def token_for(xc, secret, entry_id, epoch):
    """(private_key_hex, token_pubkey_hex) for this (entry, epoch). The pubkey IS the routing id."""
    sk = token_seed(secret, entry_id, epoch)
    return sk, xc.derive(sk)[1]

def reach_tokens(xc, secret, entry_id, now=None):
    """The token ids a CLIENT should try for this entry right now: the current epoch plus one on each
    side. The relay serves {e, e+1}; trying {e-1, e, e+1} means any client whose clock is within one
    epoch of the relay's always overlaps a served token (and absorbs the rotation boundary)."""
    e = epoch_now(now)
    return [token_for(xc, secret, entry_id, ep)[1] for ep in (e - 1, e, e + 1)]

def reach_urls(xc, secret, entry_url, now=None):
    """Full /r/<token> urls a client should try to reach the relay through this entry (current window)."""
    base = entry_url.rstrip('/')
    eid = xc.url_norm(entry_url)
    return [f'{base}/r/{tok}' for tok in reach_tokens(xc, secret, eid, now)]


# ================================ ENTRY SIDE (runs on a public node) ================================
# Registry + handoff, keyed entirely by opaque routing TOKEN — the entry never sees an account. A public
# request enqueues a framed item and blocks on an Event; a poll from the home relay (authenticated by the
# token key) dequeues it; the relay's reply sets the holder and wakes the public request. inflight is
# keyed by an unguessable reqid so a reply can find its waiter, and carries the token so a reply is
# checked to belong to the same token the request was for.

class EntryHub:
    def __init__(self, xc, entry_id=''):
        self.xc = xc
        # Our own canonical id, mixed into every signed poll/reply so a signature made for another entry
        # does not verify here. Home relays derive tokens against this same scheme-less url.
        self.entry_id = xc.url_norm(entry_id) if entry_id else ''
        self._q = {}                 # token -> Queue of pending framed items
        self._inflight = {}          # reqid -> {'event','holder','token'}
        self._seen = {}              # token -> last-poll monotonic ts (observability / "who's connected")
        self._lock = threading.Lock()
        self._pruned = 0.0           # last registry sweep (monotonic)

    def _prune(self):
        # Tokens ROTATE every epoch, so a long-running entry would otherwise accumulate one dead
        # token registry per relay per epoch forever. Drop tokens no relay has polled in a while
        # (its epoch expired / it left) — but only their empty queues, so an in-flight request is
        # never dropped out from under its waiter. Cheap: swept at most once per POLL_HOLD_S.
        now = time.monotonic()
        if now - self._pruned < POLL_HOLD_S:
            return
        self._pruned = now
        dead = [t for t, seen in self._seen.items() if now - seen > POLL_HOLD_S * 2]
        for t in dead:
            self._seen.pop(t, None)
            q = self._q.get(t)
            if q is not None and q.empty():
                self._q.pop(t, None)

    # -- queue plumbing --
    def _queue_for(self, token):
        with self._lock:
            q = self._q.get(token)
            if q is None:
                q = self._q[token] = queue.Queue()
            return q

    def _mint_reqid(self):
        # 128-bit random; only ever handed to the authenticated poller for that token.
        return os.urandom(16).hex()

    # -- signature check shared by poll and reply --
    def _auth(self, kind, token, ts, sig, *extra):
        # The token IS the ed25519 public key: verifying the signature with it proves the caller holds
        # the token's private key. entry_id is folded into the canon so the proof is bound to THIS entry.
        xc = self.xc
        try:
            if abs(int(time.time()) - int(ts)) > CLOCK_SKEW_S:
                return False
            if not (token and sig):
                return False
            canon = xc.sig_canon(kind, self.entry_id, *[str(e) for e in extra], str(ts))
            return bool(xc.verify_msg(token, canon, sig))
        except Exception:
            return False

    # -- called by the entry node's PUBLIC /r/<token>/... handler --
    def serve_public(self, token, method, path, headers, body):
        """Frame a public request, hand it to the connected home relay, return (status, resp_headers, body_bytes)."""
        reqid = self._mint_reqid()
        ev = threading.Event()
        slot = {'event': ev, 'holder': None, 'token': token}
        with self._lock:
            self._inflight[reqid] = slot
        item = json.dumps({
            'reqid': reqid, 'method': method, 'path': path,
            'headers': {k: v for k, v in headers.items() if k in _FWD_REQ_HDRS},
            'body_b64': base64.b64encode(body or b'').decode(),
        })
        self._queue_for(token).put(item)
        got = ev.wait(PUBLIC_WAIT_S)
        with self._lock:
            self._inflight.pop(reqid, None)
        if not got or slot['holder'] is None:
            # No home relay connected under this token, or it did not answer in time. The client just
            # tries the NEXT entry node — that is the whole no-SPOF point.
            return 504, {'Content-Type': 'application/json'}, b'{"ok":false,"error":"tunnel: no relay answered"}'
        st, hdrs, body_b64 = slot['holder']
        return st, hdrs, base64.b64decode(body_b64 or '')

    # -- called by the entry node's /_tunnel/poll handler (long-poll for work) --
    def poll(self, token, ts, sig):
        """Return one framed request as a JSON string, or None on 204/timeout. Raises PermissionError on bad auth."""
        if not self._auth('tunnel_poll', token, ts, sig):
            raise PermissionError('tunnel: bad poll signature')
        with self._lock:                              # (not held during the blocking get below)
            self._seen[token] = time.monotonic()
            self._prune()
        try:
            return self._queue_for(token).get(timeout=POLL_HOLD_S)
        except queue.Empty:
            return None

    # -- called by the entry node's /_tunnel/reply handler --
    def reply(self, token, ts, sig, reqid, status, headers, body_b64):
        if not self._auth('tunnel_reply', token, ts, sig, reqid):
            raise PermissionError('tunnel: bad reply signature')
        with self._lock:
            slot = self._inflight.get(reqid)
            if slot is None or slot['token'] != token:
                return False                          # unknown/expired reqid, or token mismatch — drop
            slot['holder'] = (int(status),
                              {k: v for k, v in (headers or {}).items() if k in _FWD_RESP_HDRS},
                              body_b64)
            slot['event'].set()
        return True

    def connected_tokens(self):
        now = time.monotonic()
        return sorted(t for t, seen in self._seen.items() if now - seen < POLL_HOLD_S * 2)


# ============================= CLIENT SIDE (runs on the home relay) =================================
# Dial OUT to each entry node under the CURRENT and NEXT epoch's token, run WORKERS parallel poll loops
# per (entry, epoch), dispatch each framed request against our own local port, post the response back.
# Reconnect/backoff on any error so a flaky or dead entry node never takes the others down. A manager
# thread reconciles the (entry, epoch) set every cycle so entries joining/leaving the ledger — and the
# epoch rolling over — are picked up without a restart.

class MeshClient:
    # secret:   the rendezvous secret; every routing token is derived from it (NOT the ledger key).
    # entries:  an explicit, trusted list (XC_TUNNEL_ENTRIES) — always used, never filtered.
    # discover: a callable -> candidate base urls (the on-chain / gossip relay set). Candidates are
    #           PROBED for the ENTRY_CAP on /relays and only the ones advertising it (and reachable) are
    #           dialed.
    def __init__(self, xc, secret, local_base, entries=None, discover=None,
                 self_url='', workers=WORKERS, log=None):
        self.xc = xc
        self.secret = secret
        self.local_base = local_base.rstrip('/')      # e.g. http://127.0.0.1:7401 — our own relay
        self.static = [e.rstrip('/') for e in (entries or []) if e]
        self.discover = discover
        self.self_url = (self_url or '').rstrip('/')
        self.workers = workers
        self._log = log or (lambda *a: None)
        self._stop = threading.Event()
        self._active = {}                             # (entry_url, epoch) -> per-loop stop Event
        self._entries = set()                         # entry urls currently dialed (for + / - logging)
        self._lock = threading.Lock()

    def current_reach_urls(self, now=None):
        """The /r/<token> urls this relay is reachable at right now (current epoch), one per live entry.
        For local observability/logs ONLY — deliberately NOT announced on-chain (that would republish a
        linkable topology; see the module header)."""
        e = epoch_now(now)
        with self._lock:
            entries = sorted(self._entries)
        return [f'{u}/r/{token_for(self.xc, self.secret, self.xc.url_norm(u), e)[1]}' for u in entries]

    def _sign(self, sk, kind, entry_id, *extra):
        ts = str(int(time.time()))
        canon = self.xc.sig_canon(kind, entry_id, *[str(e) for e in extra], ts)
        lines = dict(l.split(' ', 1) for l in self.xc._sign_lines(sk, canon))
        return ts, lines.get('sig', '')

    def start(self):
        threading.Thread(target=self._manager, daemon=True).start()

    def stop(self):
        self._stop.set()
        with self._lock:
            for ev in self._active.values():
                ev.set()

    # -- discovery: which entry nodes to be reachable through right now --
    def _has_entry_cap(self, url):
        u = url.rstrip('/')
        if u == self.self_url:
            return False
        try:
            with urllib.request.urlopen(u + '/relays', timeout=5) as r:
                d = json.loads(r.read())
            return ENTRY_CAP in (d.get('caps') or [])
        except Exception:
            return False

    def _resolve_targets(self):
        target = set(self.static)                     # explicit entries: trusted, always on
        if self.discover is not None:
            cands = set()
            try:
                cands = {u.rstrip('/') for u in (self.discover() or []) if u}
            except Exception as e:
                self._log(f'mesh tunnel: discovery error ({e})')
            for u in cands - target - {self.self_url}:
                if self._has_entry_cap(u):            # on-chain relay that ADVERTISES it can be an entry node
                    target.add(u)
        return target

    def _manager(self):
        first = True
        while not self._stop.is_set():
            entries = self._resolve_targets()
            e = epoch_now()
            # Serve the CURRENT and NEXT epoch's token so the next token is always pre-registered — no gap
            # at rollover. Clients cover the low side by also trying e-1.
            desired = {(u, ep) for u in entries for ep in (e, e + 1)}
            with self._lock:
                for u in entries - self._entries:
                    self._log(f'mesh tunnel: + entry {u}')
                for u in self._entries - entries:
                    self._log(f'mesh tunnel: - entry {u}')
                self._entries = entries
                for key in desired - set(self._active):
                    u, ep = key
                    ev = threading.Event()
                    self._active[key] = ev
                    sk, tok = token_for(self.xc, self.secret, self.xc.url_norm(u), ep)
                    for i in range(self.workers):
                        threading.Thread(target=self._poll_loop, args=(u, sk, tok, i, ev), daemon=True).start()
                for key in set(self._active) - desired:  # entry gone, or epoch expired → tear its loops down
                    self._active.pop(key).set()
                n = len(self._entries)
            if first:
                self._log(f'mesh tunnel: reachable via {n} entry node(s)'); first = False
            # Wake often enough that an epoch never rolls without us reconciling the token set.
            self._stop.wait(min(REFRESH_S, max(5, EPOCH_S // 4)))

    def _poll_loop(self, entry, token_sk, token_pub, worker, entry_stop):
        entry_id = self.xc.url_norm(entry)
        backoff = 1.0
        while not self._stop.is_set() and not entry_stop.is_set():
            try:
                ts, sig = self._sign(token_sk, 'tunnel_poll', entry_id)
                url = f'{entry}/_tunnel/poll?token={token_pub}&ts={ts}&sig={sig}'
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=POLL_HOLD_S + 10) as r:
                    code = r.getcode()
                    raw = r.read()
                backoff = 1.0                          # a clean poll (200 or 204) resets the backoff
                if code == 204 or not raw:
                    continue                           # no work this round — re-poll immediately
                self._handle(entry, entry_id, token_sk, token_pub, json.loads(raw))
            except Exception as e:
                if self._stop.is_set() or entry_stop.is_set():
                    break
                # Entry node down/unreachable: back off, but keep trying — the OTHER entries carry us.
                self._log(f'mesh tunnel: entry {entry} w{worker} error ({e}); retry in {backoff:.0f}s')
                self._stop.wait(backoff)
                backoff = min(backoff * 2, 30.0)

    def _handle(self, entry, entry_id, token_sk, token_pub, item):
        reqid = item['reqid']
        st, resp_hdrs, body_b64 = self._dispatch_local(item)
        ts, sig = self._sign(token_sk, 'tunnel_reply', entry_id, reqid)
        payload = json.dumps({
            'token': token_pub, 'ts': ts, 'sig': sig,
            'reqid': reqid, 'status': st, 'headers': resp_hdrs, 'body_b64': body_b64,
        }).encode()
        try:
            req = urllib.request.Request(f'{entry}/_tunnel/reply', data=payload,
                                         headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=15).read()
        except Exception as e:
            self._log(f'mesh tunnel: reply to {entry} failed ({e})')

    def _dispatch_local(self, item):
        """Run the framed request against our own relay port; return (status, resp_headers, body_b64)."""
        try:
            body = base64.b64decode(item.get('body_b64') or '')
            method = item.get('method', 'GET')
            url = self.local_base + item.get('path', '/')
            hdrs = {k: v for k, v in (item.get('headers') or {}).items() if k in _FWD_REQ_HDRS}
            req = urllib.request.Request(url, data=(body if method == 'POST' else None),
                                         headers=hdrs, method=method)
            try:
                with urllib.request.urlopen(req, timeout=DISPATCH_TO_S) as r:
                    st, rh, rb = r.getcode(), dict(r.getheaders()), r.read()
            except urllib.error.HTTPError as he:      # a 4xx/5xx from our own relay is still a real answer
                st, rh, rb = he.code, dict(he.headers), he.read()
            resp_hdrs = {k: v for k, v in rh.items() if k in _FWD_RESP_HDRS}
            return st, resp_hdrs, base64.b64encode(rb).decode()
        except Exception as e:
            return 502, {'Content-Type': 'application/json'}, base64.b64encode(
                json.dumps({'ok': False, 'error': f'tunnel dispatch: {e}'}).encode()).decode()
