# xc_tunnel.py — mesh reverse-tunnel: reach a relay behind NAT without any external service.
#
# THE PROBLEM. A relay on a home machine / laptop is behind NAT: it can dial OUT but nothing can dial
# IN. The usual fix is a third-party tunnel (Cloudflare, localhost.run, Tailscale) — an external service
# and, worse, a single point of failure. This is the self-hosted, no-SPOF alternative.
#
# THE SHAPE. Any xchat node with a public IP can act as an ENTRY node (a capability, advertised on-chain
# like s1/r1 — permissionless, plural, no owner). A home relay opens OUTBOUND long-poll connections to
# SEVERAL entry nodes at once and announces itself reachable via each: https://<entry>/r/<account>/... .
# A public request to any entry is framed and handed down the held connection to the home relay, which
# serves it against its own local port and posts the response back. Kill any one entry node and the
# relay stays reachable through the others — the mesh has no single point of failure. The entry nodes
# are discovered on the ledger (on-chain rendezvous), so there is no directory and no external service.
#
# WHY LONG-POLL and not WebSocket. Both ends are stdlib http.server (request/response, no ws). A hanging
# GET for work + a POST for the reply needs nothing but http, and passes through every HTTP ingress
# (Fly included) untouched. One extra round-trip of latency, which for a prototype is a fine trade for
# zero new dependencies.
#
# AUTH. Every poll/reply is signed by the relay's ledger ID key; the entry node checks the signature and
# that pub_to_addr(pub) == the account being claimed, so nobody can register as (or reply for) an
# account whose key they do not hold. Freshness window bounds replay. The entry node never needs the
# home relay's key, only its public account — same trust model as the rest of the mesh.
#
# SCOPE (prototype). Public entry nodes only. Phones (carrier NAT, battery, intermittent) cannot be
# entry nodes and are out of scope here; a phone "mix/forward" layer for anonymity is a separate feature
# built on top. On-chain announce of the /r/<account> addresses is left to the caller (see MeshClient
# .public_urls); the transport and its failover are what this module proves.

import base64
import json
import os
import queue
import threading
import time
import urllib.request

# --- tunables (prototype; env-overridable) ---------------------------------------------------------
POLL_HOLD_S    = int(os.environ.get('XC_TUNNEL_POLL_HOLD_S', '25'))    # entry holds a poll open this long with no work → 204
PUBLIC_WAIT_S  = int(os.environ.get('XC_TUNNEL_PUBLIC_WAIT_S', '30'))  # public request waits this long for the reply → 504
CLOCK_SKEW_S   = 120     # accepted |now - ts| on a signed poll/reply — bounds replay
WORKERS        = 4       # parallel poll loops per entry node = max concurrent in-flight requests per node
DISPATCH_TO_S  = 20      # timeout dispatching a framed request against the home relay's own local port
_FWD_REQ_HDRS  = ('Content-Type',)   # request headers carried down the tunnel (kept tiny on purpose)
_FWD_RESP_HDRS = ('Content-Type',)   # response headers carried back up


# ================================ ENTRY SIDE (runs on a public node) ================================
# Registry + handoff. A public request enqueues a framed item and blocks on an Event; a poll from the
# home relay dequeues it; the relay's reply sets the holder and wakes the public request. inflight is
# keyed by an unguessable reqid so a reply can find its waiter, and carries the account so a reply is
# checked to belong to the same account the request was for.

class EntryHub:
    def __init__(self, xc):
        self.xc = xc
        self._q = {}                 # account -> Queue of pending framed items
        self._inflight = {}          # reqid -> {'event','holder','account'}
        self._seen = {}              # account -> last-poll monotonic ts (observability / "who's connected")
        self._lock = threading.Lock()
        self._n = 0                  # reqid counter (mixed with time; unguessability comes from os.urandom)

    # -- queue plumbing --
    def _queue_for(self, account):
        with self._lock:
            q = self._q.get(account)
            if q is None:
                q = self._q[account] = queue.Queue()
            return q

    def _mint_reqid(self):
        # 128-bit random; only ever handed to the authenticated poller for that account.
        import os
        return os.urandom(16).hex()

    # -- signature check shared by poll and reply --
    def _auth(self, kind, account, pub, ts, sig, *extra):
        xc = self.xc
        try:
            if abs(int(time.time()) - int(ts)) > CLOCK_SKEW_S:
                return False
            if not (account and pub and sig):
                return False
            if xc.pub_to_addr(pub) != account:          # the pub must actually derive the claimed account
                return False
            canon = xc.sig_canon(kind, account, *[str(e) for e in extra], str(ts))
            return bool(xc.verify_msg(pub, canon, sig))
        except Exception:
            return False

    # -- called by the entry node's PUBLIC /r/<account>/... handler --
    def serve_public(self, account, method, path, headers, body):
        """Frame a public request, hand it to the connected home relay, return (status, resp_headers, body_bytes)."""
        reqid = self._mint_reqid()
        ev = threading.Event()
        slot = {'event': ev, 'holder': None, 'account': account}
        with self._lock:
            self._inflight[reqid] = slot
        item = json.dumps({
            'reqid': reqid, 'method': method, 'path': path,
            'headers': {k: v for k, v in headers.items() if k in _FWD_REQ_HDRS},
            'body_b64': base64.b64encode(body or b'').decode(),
        })
        self._queue_for(account).put(item)
        got = ev.wait(PUBLIC_WAIT_S)
        with self._lock:
            self._inflight.pop(reqid, None)
        if not got or slot['holder'] is None:
            # No home relay connected for this account, or it did not answer in time. The client just
            # tries the NEXT entry node it announced — that is the whole no-SPOF point.
            return 504, {'Content-Type': 'application/json'}, b'{"ok":false,"error":"tunnel: no relay answered"}'
        st, hdrs, body_b64 = slot['holder']
        return st, hdrs, base64.b64decode(body_b64 or '')

    # -- called by the entry node's /_tunnel/poll handler (long-poll for work) --
    def poll(self, account, pub, ts, sig):
        """Return one framed request as a JSON string, or None on 204/timeout. Raises PermissionError on bad auth."""
        if not self._auth('tunnel_poll', account, pub, ts, sig):
            raise PermissionError('tunnel: bad poll signature')
        self._seen[account] = time.monotonic()
        try:
            return self._queue_for(account).get(timeout=POLL_HOLD_S)
        except queue.Empty:
            return None

    # -- called by the entry node's /_tunnel/reply handler --
    def reply(self, account, pub, ts, sig, reqid, status, headers, body_b64):
        if not self._auth('tunnel_reply', account, pub, ts, sig, reqid):
            raise PermissionError('tunnel: bad reply signature')
        with self._lock:
            slot = self._inflight.get(reqid)
            if slot is None or slot['account'] != account:
                return False                          # unknown/expired reqid, or account mismatch — drop
            slot['holder'] = (int(status),
                              {k: v for k, v in (headers or {}).items() if k in _FWD_RESP_HDRS},
                              body_b64)
            slot['event'].set()
        return True

    def connected_accounts(self):
        now = time.monotonic()
        return sorted(a for a, t in self._seen.items() if now - t < POLL_HOLD_S * 2)


# ============================= CLIENT SIDE (runs on the home relay) =================================
# Dial OUT to each entry node, run WORKERS parallel poll loops per node, dispatch each framed request
# against our own local port, post the response back. Reconnect/backoff on any error so a flaky or dead
# entry node never takes the others down.

class MeshClient:
    def __init__(self, xc, account, id_key, local_base, entries, workers=WORKERS, log=None):
        self.xc = xc
        self.account = account
        self.id_key = id_key
        self.local_base = local_base.rstrip('/')      # e.g. http://127.0.0.1:7401 — our own relay
        self.entries = [e.rstrip('/') for e in entries if e]
        self.workers = workers
        self._log = log or (lambda *a: None)
        self._stop = threading.Event()
        self._threads = []

    def public_urls(self):
        """The addresses to announce on-chain: one per entry node. Any one up == reachable."""
        return [f'{e}/r/{self.account}' for e in self.entries]

    def _sign(self, kind, *extra):
        ts = str(int(time.time()))
        canon = self.xc.sig_canon(kind, self.account, *[str(e) for e in extra], ts)
        lines = dict(l.split(' ', 1) for l in self.xc._sign_lines(self.id_key, canon))
        return ts, lines.get('pub', ''), lines.get('sig', '')

    def start(self):
        for entry in self.entries:
            for i in range(self.workers):
                t = threading.Thread(target=self._poll_loop, args=(entry, i), daemon=True)
                t.start()
                self._threads.append(t)
        self._log(f'mesh tunnel: dialing {len(self.entries)} entry node(s), {self.workers} workers each')

    def stop(self):
        self._stop.set()

    def _poll_loop(self, entry, worker):
        backoff = 1.0
        while not self._stop.is_set():
            try:
                ts, pub, sig = self._sign('tunnel_poll')
                url = f'{entry}/_tunnel/poll?account={self.account}&pub={pub}&ts={ts}&sig={sig}'
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=POLL_HOLD_S + 10) as r:
                    code = r.getcode()
                    raw = r.read()
                backoff = 1.0                          # a clean poll (200 or 204) resets the backoff
                if code == 204 or not raw:
                    continue                           # no work this round — re-poll immediately
                self._handle(entry, json.loads(raw))
            except Exception as e:
                if self._stop.is_set():
                    break
                # Entry node down/unreachable: back off, but keep trying — the OTHER entries carry us.
                self._log(f'mesh tunnel: entry {entry} w{worker} error ({e}); retry in {backoff:.0f}s')
                self._stop.wait(backoff)
                backoff = min(backoff * 2, 30.0)

    def _handle(self, entry, item):
        reqid = item['reqid']
        st, resp_hdrs, body_b64 = self._dispatch_local(item)
        ts, pub, sig = self._sign('tunnel_reply', reqid)
        payload = json.dumps({
            'account': self.account, 'pub': pub, 'ts': ts, 'sig': sig,
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
