#!/usr/bin/env python3
# ӾChat backend node — a small, hostable HTTP server that bridges the app to the network.
#
# Pure Python: it exposes the /api/* routes by delegating to the helper scripts alongside it
# (xc_feed.py, xc_post.py, xc_reldir.py, ...) and signs with nanopy (ed25519-blake2b). Anyone can
# run this — `python3 kt_server.py <port>` — on any OS, so the app is not tied to one machine.
# Wallet state is namespaced per instance (XC_NS = port): one node = one identity ("run your own node").
#
#   python3 kt_server.py 8790            # serve on :8790 (binds 0.0.0.0 so a phone/relay can reach it)
import os, sys, json, subprocess, urllib.parse, urllib.request, time, threading, base64, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
NS = str(PORT)
# The node runs its own relay on loopback; kt_server owns /api/* and forwards every OTHER path to it,
# so the node's PUBLIC url doubles as a fully-working relay (/heads, /push, /blob, /relays,
# /relay_announce, …). That's what lets a peer relay bootstrap TO the node and discover it.
RELAY_ORIGIN = 'http://127.0.0.1:%d' % int(os.environ.get('XC_RELAY_PORT', '7401'))
# The helpers import xc_common (nanopy), so the right interpreter is by definition THIS one — it
# already imported it below. Defaulting to a bare 'python3' picked whichever came first on PATH,
# which on a machine with more than one Python is a different install with no nanopy: every helper
# then died and the node answered with a STALE result file (see read()).
PY = os.environ.get('XC_PYTHON', sys.executable or 'python3')
DM_PY = os.environ.get('XC_DM_PYTHON', PY)                  # kept as an override; xc_dm needs no extras now
sys.path.insert(0, HERE)
import xc_common as xc                                       # for api_me + wallet paths
import xc_engage                                             # hot engagement path, called IN-PROCESS (no spawn)

# Human landing / download page, served on the node's PUBLIC url (/, /download, /get, /app). The node
# is the app's front door AND its own relay, so hosting the page here means ӾChat's own censorship-
# resistant infra serves its download — no third party (app store, artifact host, Pages) can pull it.
# Loaded once at startup; a minimal inline fallback keeps the front door serving if the file is missing.
try:
    with open(os.path.join(HERE, 'download.html'), encoding='utf-8') as _f:
        DOWNLOAD_PAGE = _f.read()
except Exception:
    DOWNLOAD_PAGE = ('<!doctype html><meta charset=utf-8><title>ӾChat</title>'
                     '<body style="background:#050607;color:#eef3f7;font-family:sans-serif;text-align:center;padding:14vh 6vw">'
                     '<h1>ӾChat</h1><p>A censorship-free X on the Nano ledger.</p>'
                     '<p><a style="color:#2ca6e0" href="https://github.com/stefanbx/xchat-alpha/raw/master/apk/xchat-alpha.apk">Download the Android APK</a></p>'
                     '<p><a style="color:#2ca6e0" href="https://github.com/stefanbx/xchat-alpha">Source &amp; checksums</a></p></body>')
DOWNLOAD_PATHS = ('/', '/download', '/get', '/app')

def _env():
    return {**os.environ, 'XC_NS': NS,
            'PATH': os.environ.get('PATH', '/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin')}

def wallet_file():
    return f'/tmp/xc_wallet_seed_{NS}.txt'

def put(path, text):                                         # write a /tmp input file for a helper
    with open(path, 'w') as f:
        f.write(text or '')

def spawn(script, *args, py=None):                           # run a helper exactly like the engine did
    try:
        subprocess.run([py or PY, os.path.join(HERE, script), *[a for a in args if a is not None]],
                       env=_env(), timeout=180)
    except Exception:
        pass

def read(path, default=''):
    # CONSUME the result: a helper writes its result file fresh on every run, so reading one and
    # leaving it behind means the NEXT request gets this answer if its helper crashes. That is a
    # silent wrong answer — a failed post reported as the successful post before it — and it is
    # exactly what happened when the helpers were being started with the wrong interpreter.
    try:
        out = open(path).read()
    except Exception:
        return default
    try:
        os.remove(path)
    except Exception:
        pass
    return out or default

# The server is a ThreadingHTTPServer, but the file-based helpers talk over FIXED /tmp paths
# (/tmp/xc_<group>_rec.json + _result.json). Two concurrent requests to the same helper would
# race: A writes its rec, B overwrites it before A's helper reads it (A verifies B's payload), or
# B's result is read back as A's answer. Serialize the whole put→spawn→read triple PER HELPER
# GROUP so different endpoints stay concurrent while same-endpoint requests can't interleave on
# their shared files. (The hot like/repost/view path is in-process and never touches these files.)
_ipc_locks = {}
_ipc_locks_guard = threading.Lock()
def ipc_lock(group):
    with _ipc_locks_guard:
        lk = _ipc_locks.get(group)
        if lk is None:
            lk = _ipc_locks[group] = threading.Lock()
        return lk

# ---- inline routes ----
def api_me(acct):
    # SEEDLESS: the account comes from the app (it holds the key); the node only reads the balance.
    # The IDENTITY therefore needs no ledger at all, and must survive one being unreachable — a node
    # pointed at a down RPC should still let you see who you are, not fail to answer.
    bal = '0'
    if acct:
        try:
            ai = xc.rpc_cached({'action': 'account_info', 'account': acct})  # display balance; a few s stale is fine
            bal = ai.get('balance', '0') if 'error' not in ai else '0'
        except Exception:
            bal = '0'
    return json.dumps({'handle': 'you.xno', 'account': acct, 'balance': bal})

# The feed aggregation (spawn a helper, pull every relay, verify sigs) is far too heavy to run per
# request — that made /api/feed the whole node's bottleneck (~4 req/s). Cache it for a few seconds:
# clients read the cached JSON, and at most one thread re-aggregates per window (others serve stale
# rather than pile on). A social feed being a few seconds behind is invisible; the throughput is not.
FEED_TTL = float(os.environ.get('XC_FEED_TTL', '5'))
_feed_ts = [0.0]
_feed_lock = threading.Lock()

def api_feed(query=None):
    now = time.time()
    if not os.path.exists('/tmp/xc_feed_agg.json'):
        # COLD START (fresh node, or a redeploy cleared /tmp): BLOCK on the first aggregation so the very
        # first feed is never empty. Only one caller aggregates per TTL window; others wait on the lock,
        # then read the fresh file. If it fails, they fall through to empty fast (no thundering herd).
        with _feed_lock:
            if not os.path.exists('/tmp/xc_feed_agg.json') and time.time() - _feed_ts[0] > FEED_TTL:
                _feed_ts[0] = time.time()
                spawn('xc_feed.py')
    elif now - _feed_ts[0] > FEED_TTL and _feed_lock.acquire(blocking=False):
        try:
            _feed_ts[0] = now                                # warm refresh: serve the stale cache meanwhile
            spawn('xc_feed.py')
        finally:
            _feed_lock.release()
    # The aggregation file is a CACHE that must persist for FEED_TTL, so read it WITHOUT consuming it —
    # unlike a one-shot helper result. (read() deletes what it reads; using it here defeated the cache
    # and re-aggregated on every request, which is what made the feed blink slow-or-empty.)
    try:
        content = open('/tmp/xc_feed_agg.json').read() or '{}'
    except Exception:
        content = '{}'
    blocks = read('/tmp/xc_onchain_count.txt', '0') or '0'
    # Incremental: ?since=<ts> returns ONLY posts newer than what the client already has, so a poll
    # usually returns an empty list instead of the whole feed. Aggregation is still cached whole (the
    # expensive part); this just slices it on the way out. No `since` = the full feed (unchanged).
    try:
        since = int((query or {}).get('since', ['0'])[0])   # router parses the query and passes it in
    except Exception:
        since = 0
    if since > 0:
        try:
            c = json.loads(content)
            c['posts'] = [p for p in c.get('posts', []) if int(p.get('ts', 0)) > since]
            c['incremental'] = True
            content = json.dumps(c)
        except Exception:
            pass
    return ('{"onchain_blocks":' + blocks +
            ',"transport":"plural relays + signed mutable heads","content":' + content + '}')

LABELS_TTL = float(os.environ.get('XC_LABELS_TTL', '15'))    # community-report aggregation cache (s)
_labels_ts = [0.0]
_labels_lock = threading.Lock()

def api_labels():
    # Moderation = COMMUNITY REPORTS. Aggregate signed reports across the relays into one "community"
    # labeler: verify each report's signature, count distinct reporters per post, and expose a per-post
    # fraction (reporters / quorum) the app filters against. Cached like the feed.
    now = time.time()
    if now - _labels_ts[0] > LABELS_TTL and _labels_lock.acquire(blocking=False):
        try:
            _labels_ts[0] = now
            spawn('xc_labels.py')                            # async refresh; serve the cache meanwhile
        finally:
            _labels_lock.release()
    # cache — read WITHOUT consuming, or every /api/labels re-runs the (RPC-heavy) trust aggregation.
    try:
        return open('/tmp/xc_labels.json').read() or '{"labelers":[]}'
    except Exception:
        return '{"labelers":[]}'

# ---- on-device money: PUBLIC ledger reads (no seed) that let the app build + sign its own blocks ----
def api_account_state(acct):
    # frontier + balance + representative for an account; the app needs these to build a state block.
    # An unreachable ledger is reported AS an error: the app must not read it as "unopened" and go on
    # to sign an open block over a balance nobody confirmed.
    try:
        ai = xc.rpc({'action': 'account_info', 'account': acct, 'representative': 'true'})
    except Exception as e:
        return json.dumps({'ok': False, 'error': f'ledger unreachable: {e}'})
    if 'error' in ai:                                        # unopened account: the app will send an OPEN block
        return json.dumps({'opened': False, 'frontier': '0' * 64, 'balance': '0',
                           'representative': acct, 'block_count': 0})
    return json.dumps({'opened': True, 'frontier': ai['frontier'], 'balance': ai['balance'],
                       'representative': ai.get('representative', acct),
                       # total blocks on this account's chain = every on-chain transaction it has made
                       # (opens/receives/sends/changes). The app shows this as the user's "Nano txns".
                       'block_count': int(ai.get('block_count', 0) or 0)})

def api_receivables(acct):
    try:
        pend = xc.rpc({'action': 'receivable', 'account': acct, 'count': '25', 'source': 'true',
                       'include_only_confirmed': 'false'})
    except Exception as e:
        return json.dumps({'ok': False, 'error': f'ledger unreachable: {e}', 'receivables': []})
    blocks = pend.get('blocks') or {}
    out = []
    items = blocks.items() if isinstance(blocks, dict) else [(h, None) for h in blocks]
    for h, info in items:
        amt = info['amount'] if isinstance(info, dict) else \
            xc.rpc({'action': 'block_info', 'json_block': 'true', 'hash': h}).get('amount', '0')
        out.append({'hash': h, 'amount': amt})
    return json.dumps({'ok': True, 'receivables': out})

def _blob_matches_cid(cid, b64):
    # A relay earns the media split only if it actually SERVES the exact content — not just claims to.
    # Media is content-addressed as 'sha256-<hex>', so verify the served bytes hash to the cid. A relay
    # that lies about hosting (self-attested /haveblob) or serves garbage fails here and isn't paid.
    # Non-sha256 cids (the IPFS demo) aren't cheaply verifiable, so the split is skipped (creator keeps
    # 100%) rather than paid on an unverifiable claim — safe by default.
    if not b64 or not cid.startswith('sha256-'):
        return False
    try:
        return hashlib.sha256(base64.b64decode(b64)).hexdigest() == cid.split('sha256-', 1)[1]
    except Exception:
        return False

def api_media_relay(cid):
    # which relay serves this post's media (so a tip can reward it) — a public read across relays.
    # The claim is VERIFIED (bytes must hash to the cid) so a lying relay can't skim the media split.
    cq = urllib.parse.quote(cid, safe='')
    for r in xc.discover_relays():
        try:
            if not json.loads(urllib.request.urlopen(r + '/haveblob?cid=' + cq, timeout=3).read()).get('have'):
                continue
            b64 = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cq, timeout=6).read()).get('b64')
            if not _blob_matches_cid(cid, b64):
                continue
            acct = json.loads(urllib.request.urlopen(r + '/relayacct', timeout=3).read()).get('account')
            return json.dumps({'account': acct or ''})
        except Exception:
            pass
    return json.dumps({'account': ''})

def api_pin_targets():
    # PUBLIC relays the app can pay + POST /pin to directly (skip the node's loopback relay), each with
    # the account a pinner sends to. The app: send XNO to account -> POST relay/pin {cid, payhash}.
    out, seen = [], set()
    for r in xc.discover_relays():
        if '127.0.0.1' in r or 'localhost' in r or not r.startswith('https'):
            continue
        try:
            acct = json.loads(urllib.request.urlopen(r + '/relayacct', timeout=3).read()).get('account')
            if acct and acct not in seen:
                seen.add(acct)
                out.append({'url': r.rstrip('/'), 'account': acct})
        except Exception:
            pass
    return json.dumps({'relays': out})

def api_head(acct):
    # the account's current signed head (seq + cid) across relays — the app re-signs it with a fresh
    # expiry to republish (keep it alive past TTL). A public read; no seed.
    best = None
    for r in xc.discover_relays():
        try:
            for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=3).read()).get('heads', []):
                if h.get('author') == acct and (best is None or h.get('seq', 0) >= best.get('seq', 0)):
                    best = h
        except Exception:
            pass
    if not best:
        return json.dumps({'ok': True, 'head': None})
    return json.dumps({'ok': True, 'head': {'seq': best['seq'], 'cid': best['cid'], 'handle': best.get('handle', '')}})

_PRESENCE_WINDOW = float(os.environ.get('XC_PRESENCE_WINDOW', '150'))   # seconds a head stays "online"
def api_presence():
    # Accounts online right now = those whose signed head was refreshed within the presence window.
    # The app republishes its head every ~45s while open (see Api.republish), and the relay stamps each
    # head's receive time as `ts`, so a fresh head ≈ an open app. A public read across relays (max ts
    # per account), no seed, no per-account tracking beyond the head every account already publishes.
    now = time.time()
    latest = {}
    for r in xc.discover_relays():
        try:
            for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=3).read()).get('heads', []):
                a = h.get('author'); ts = float(h.get('ts', 0) or 0)
                if a and ts > 0:
                    latest[a] = max(latest.get(a, 0.0), ts)
        except Exception:
            pass
    online = [a for a, ts in latest.items() if now - ts <= _PRESENCE_WINDOW]
    return json.dumps({'ok': True, 'online': online, 'window': int(_PRESENCE_WINDOW)})

def api_channels():
    # Directory of channels across relays: union by account, taking the max online/follower counts a
    # relay reports (relays converge but may lag). Public read; the relay computes the per-channel
    # follower + online-reader tallies from its own profiles/follows/heads.
    merged = {}
    for r in xc.discover_relays():
        try:
            for c in json.loads(urllib.request.urlopen(r + '/channels', timeout=4).read()).get('channels', []):
                a = c.get('account')
                if not a:
                    continue
                m = merged.get(a)
                if m is None:
                    merged[a] = dict(c)
                else:
                    m['online'] = max(m.get('online', 0), c.get('online', 0))
                    m['followers'] = max(m.get('followers', 0), c.get('followers', 0))
                    if not m.get('display'): m['display'] = c.get('display', '')
                    if not m.get('avatar'): m['avatar'] = c.get('avatar', '')
        except Exception:
            pass
    return json.dumps({'ok': True, 'channels': list(merged.values())})

RELAYDIR_TTL = float(os.environ.get('XC_RELAYDIR_TTL', '180'))
_relaydir_ts = [0.0]
_relaydir_lock = threading.Lock()
_RELAYDIR_CACHE = '/tmp/xc_relaydir_cache.json'
_RELAYDIR_WARMING = '{"source":"warming","relays":[],"active":[],"count":0,"health":[],"rendezvous":[]}'
def api_relaydir():
    # The relay-directory panel does an on-chain scan + per-relay pings. A COLD scan can take ~80s and
    # pegs the single shared CPU — running it on the request thread hung the WHOLE node under the app's
    # launch burst (which calls this every start). It's a non-critical display, so NEVER block on it:
    # serve the cached result immediately and refresh in ONE background thread (single-flight).
    now = time.time()
    if now - _relaydir_ts[0] > RELAYDIR_TTL and _relaydir_lock.acquire(blocking=False):
        _relaydir_ts[0] = now                         # claim the window so a burst doesn't stack refreshes
        def _bg():
            try:
                spawn('xc_reldir.py', 'engine')
                if os.path.exists('/tmp/xc_relaydir.json'):
                    os.replace('/tmp/xc_relaydir.json', _RELAYDIR_CACHE)
            finally:
                try:
                    _relaydir_lock.release()
                except Exception:
                    pass
        threading.Thread(target=_bg, daemon=True).start()
    try:
        return open(_RELAYDIR_CACHE).read() or _RELAYDIR_WARMING
    except Exception:
        return _RELAYDIR_WARMING

_relcheck_cache = {}   # current -> (result_str, ts)
def api_release_check(current):
    # Cache the check like the feed. It spawns a helper (relay fan-out) and holds the HTTP connection
    # open ~1s+; under the app's launch burst on a single machine that piles up open connections until
    # Fly's proxy can't route ("no good candidate") and a phone's check fails though the node is healthy.
    # A short-TTL cache makes repeat/concurrent checks return in microseconds, freeing the connection.
    now = time.time()
    c = _relcheck_cache.get(current)
    if c and now - c[1] < 20:
        return c[0]
    with ipc_lock('release'):
        put('/tmp/xc_rel_current.txt', current)
        spawn('xc_release.py', 'check')
        r = read('/tmp/xc_release_result.json', '{}')
    try:
        ok = json.loads(r).get('ok') is True
    except Exception:
        ok = False
    if ok:                                            # don't cache a transient failure (would stick 20s)
        _relcheck_cache[current] = (r, now)
        if len(_relcheck_cache) > 64:
            _relcheck_cache.pop(next(iter(_relcheck_cache)), None)
    return r

# The pinned publisher account — the ONLY identity whose announcement the node will serve. Overridable
# for self-hosters, but defaults to the same account that signs releases.
PUBLISHER_ACCT = (os.environ.get('XC_PUBLISHER_ACCOUNT', '')
                  or 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8')

def api_announcement():
    # A coordinated-event banner (e.g. a network migration). Served ONLY if a publisher-SIGNED, unexpired
    # record is present — so a rogue relay or a node operator without the publisher key can't forge the
    # "back up your seed / move your funds" message. No record => nothing shown (normal operation).
    raw = os.environ.get('XC_ANNOUNCEMENT', '')
    if not raw:
        try:
            with open(os.path.join(HERE, 'announcement.json'), encoding='utf-8') as f:
                raw = f.read()
        except Exception:
            return '{"active": false}'
    try:
        a = json.loads(raw)
        canon = xc.sig_canon('announce', a['text'], a['ts'], a['expires'])
        if (xc.pub_to_addr(a['pub']) == PUBLISHER_ACCT and xc.verify_msg(a['pub'], canon, a['sig'])
                and int(time.time()) < int(a['expires'])):
            return json.dumps({'active': True, 'text': a['text'], 'expires': int(a['expires'])})
    except Exception:
        pass
    return '{"active": false}'

def api_status():
    try:
        bc = xc.rpc_cached({'action': 'block_count'}, ttl=10)  # chain height for display; 10s stale is invisible
        return json.dumps({'online': True, 'height': bc.get('count', '0')})
    except Exception:
        return '{"online":false}'

# ---- dispatch: path -> handler(query, body) -> response string ----
def route(path, query, body):
    q = lambda k: (query.get(k, [''])[0])
    b = lambda k: (body.get(k, '') if isinstance(body, dict) else '')

    if path.startswith('/api/feed'):        return api_feed(query)
    if path.startswith('/api/relaydir'):     return api_relaydir()   # cached + background-refreshed (never blocks)
    if path.startswith('/api/pin_targets'):  return api_pin_targets()
    # prefix collisions: /api/media_relay must precede /api/media, which must precede /api/me.
    if path.startswith('/api/media_relay'):   return api_media_relay(q('cid'))
    if path.startswith('/api/media'):
        with ipc_lock('media'):
            put('/tmp/xc_media_cid.txt', q('cid')); spawn('xc_media.py'); return read('/tmp/xc_media_result.json', '{}')
    if path.startswith('/api/me'):           return api_me(q('account'))
    if path.startswith('/api/status'):       return api_status()
    if path.startswith('/api/announcement'):  return api_announcement()
    if path.startswith('/api/labels'):       return api_labels()

    # on-device posting: two-step round-trip. These are prefixes of /api/post, so match them FIRST.
    if path.startswith('/api/post_prepare'):
        with ipc_lock('post'):
            put('/tmp/xc_post_rec.json', json.dumps(body)); spawn('xc_post.py', 'prepare')   # app-signed post event
            return read('/tmp/xc_post_result.json', '{}')
    if path.startswith('/api/post_delete'):
        with ipc_lock('post'):
            put('/tmp/xc_delete_rec.json', json.dumps(body)); spawn('xc_post.py', 'delete')  # app-signed delete event
            return read('/tmp/xc_post_result.json', '{}')
    if path.startswith('/api/post_submit'):
        with ipc_lock('post'):
            put('/tmp/xc_head_rec.json', json.dumps(body)); spawn('xc_post.py', 'submit')     # app-signed head
            return read('/tmp/xc_post_result.json', '{}')

    # SEEDLESS NODE: the legacy node-signed /api/post, /api/wallet and /api/settle are removed. Posting,
    # tips, sends and the wallet seed are all on-device now (see /api/post_prepare + /api/post_submit and
    # /api/block_process). The node never receives, stores, or signs with a seed.

    # Hottest endpoints — IN-PROCESS (no subprocess spawn / /tmp round-trip). ~0.18s/call saved + better
    # under concurrency; they're just relay fan-out (fire-and-forget writes, aggregated reads).
    if path.startswith('/api/like'):         return json.dumps(xc_engage.like(b('post_id'), b('delta')))
    if path.startswith('/api/repost'):       return json.dumps(xc_engage.repost(body))   # body = app-signed reshare rec
    if path.startswith('/api/tipstat'):      return json.dumps(xc_engage.tip(b('post_id'), b('raw')))
    if path.startswith('/api/view'):         return json.dumps(xc_engage.view(b('post_id'), b('delta')))
    if path.startswith('/api/engagement'):   return json.dumps(xc_engage.get())
    if path.startswith('/api/notify_push'):
        return json.dumps(xc_engage.notify({'to': b('to'), 'from': b('from'), 'kind': b('kind'),
                                            'text': b('text'), 'ts': int(time.time())}))
    if path.startswith('/api/notify'):
        with ipc_lock('notify'):
            put('/tmp/xc_notify_acct.txt', q('account'))   # route by the viewer's unique account, not a shared handle
            spawn('xc_notify.py'); return read('/tmp/xc_notify.json', '{}')

    # on-device money: the app builds + signs every state block; the node only reads ledger state and
    # adds delegated PoW + broadcasts a fully-signed block (send / receive / open / change / settle).
    if path.startswith('/api/account_state'): return api_account_state(q('account'))
    if path.startswith('/api/receivables'):   return api_receivables(q('account'))
    if path.startswith('/api/block_process'):
        with ipc_lock('block'):
            put('/tmp/xc_block_in.json', json.dumps(body)); spawn('xc_blockproc.py')   # app-signed block; node adds PoW + broadcasts
            return read('/tmp/xc_block_result.json', '{}')

    if path.startswith('/api/report'):
        with ipc_lock('report'):
            put('/tmp/xc_report_rec.json', json.dumps(body)); spawn('xc_report.py'); return read('/tmp/xc_report_result.json', '{}')
    if path.startswith('/api/follows_set'):
        with ipc_lock('follows'):
            put('/tmp/xc_follows_rec.json', json.dumps(body)); spawn('xc_follows.py','pub'); return read('/tmp/xc_follows_result.json','{}')
    if path.startswith('/api/follows_get'):
        with ipc_lock('follows'):
            put('/tmp/xc_follows_acct.txt', q('account')); spawn('xc_follows.py', 'get');  return read('/tmp/xc_follows_result.json', '{}')

    if path.startswith('/api/comment_post'):
        with ipc_lock('comment'):
            put('/tmp/xc_comment_rec.json', json.dumps(body))   # app-signed record; node verifies + relays
            spawn('xc_comments.py', 'post');     return read('/tmp/xc_comments_result.json', '{}')
    if path.startswith('/api/comments_get'):
        with ipc_lock('comment'):
            put('/tmp/xc_comment_post.txt', q('post')); spawn('xc_comments.py','get'); return read('/tmp/xc_comments_result.json','{}')

    if path.startswith('/api/profile_set'):
        with ipc_lock('profile'):
            put('/tmp/xc_profile_rec.json', json.dumps(body))   # app-signed record; node verifies + relays
            spawn('xc_profile.py', 'pub');       return read('/tmp/xc_profile_result.json', '{}')
    if path.startswith('/api/profile_get'):
        with ipc_lock('profile'):
            put('/tmp/xc_profile_account.txt', q('account')); spawn('xc_profile.py','get'); return read('/tmp/xc_profile_result.json','{}')

    if path.startswith('/api/poll_vote'):
        with ipc_lock('poll'):
            put('/tmp/xc_poll_rec.json', json.dumps(body)); spawn('xc_poll.py','vote'); return read('/tmp/xc_poll_result.json','{}')
    if path.startswith('/api/poll_get'):
        with ipc_lock('poll'):
            put('/tmp/xc_poll_id.txt', q('poll')); put('/tmp/xc_poll_acct.txt', q('account')); spawn('xc_poll.py','get'); return read('/tmp/xc_poll_result.json', '{}')

    # on-device DMs: the app seals/opens locally; the node verifies the signed key record + relays ciphertext.
    if path.startswith('/api/dm_key_set'):
        with ipc_lock('dm'):
            put('/tmp/xc_dm_rec.json', json.dumps(body)); spawn('xc_dm.py','register'); return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_key_get'):
        with ipc_lock('dm'):
            put('/tmp/xc_dm_peer.txt', q('account')); spawn('xc_dm.py','keyget');       return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_send'):
        with ipc_lock('dm'):
            put('/tmp/xc_dm_msg.json', json.dumps(body)); spawn('xc_dm.py','send');    return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_inbox'):
        with ipc_lock('dm'):
            put('/tmp/xc_dm_acct.txt', q('account')); spawn('xc_dm.py','inbox');       return read('/tmp/xc_dm_result.json','{}')

    if path.startswith('/api/blob_put'):
        with ipc_lock('blob'):
            put('/tmp/xc_blob_in.txt', b('b64')); spawn('xc_blobput.py');    return read('/tmp/xc_blobput_result.json', '{}')

    if path.startswith('/api/release_check'): return api_release_check(q('current'))
    if path.startswith('/api/release_fetch'):
        with ipc_lock('release'):
            put('/tmp/xc_rel_cid.txt', b('cid')); put('/tmp/xc_rel_sha.txt', b('sha256')); spawn('xc_release.py','fetch'); return read('/tmp/xc_release_result.json','{}')

    if path.startswith('/api/channels'):     return api_channels()           # channel directory + online readers
    if path.startswith('/api/presence'):     return api_presence()           # accounts online now (fresh heads)
    if path.startswith('/api/head'):         return api_head(q('account'))   # app re-signs it to republish (seedless)
    if path.startswith('/api/gossip'):
        with ipc_lock('gossip'):
            spawn('xc_gossip.py'); return read('/tmp/xc_gossip_result.json', '{}')
    if path.startswith('/api/pincontent'):
        with ipc_lock('pin'):
            spawn('xc_pin.py'); return read('/tmp/xc_pin_result.json', '{}')
    if path.startswith('/api/supporter'):
        with ipc_lock('supporter'):
            put('/tmp/xc_supporter_in.json', json.dumps({'account': b('account'), 'on': b('on'), 'ts': b('ts')}))
            spawn('xc_supporter.py');            return read('/tmp/xc_supporter_result.json', '{}')

    return '{"error":"not found"}'


MAX_JSON_BODY = int(os.environ.get('XC_MAX_JSON_BODY', str(512 * 1024)))        # non-blob request cap
MAX_BLOB_BODY = int(os.environ.get('XC_MAX_BLOB_BODY', str(32 * 1024 * 1024)))  # blob/APK-sized cap


class H(BaseHTTPRequestHandler):
    def _send(self, body):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_html(self, html):
        data = html.encode() if isinstance(html, str) else html
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'public, max-age=300')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy_relay(self, raw):
        # Forward a relay-owned request to the loopback relay, verbatim (method + path + query + body).
        # Pass the REAL client IP so the relay throttles per-attacker: without this every proxied write
        # arrives from 127.0.0.1 and all users share one bucket (one abuser 429s everyone). The relay
        # trusts X-Forwarded-For only from a loopback peer (us), so this can't be spoofed end-to-end.
        client_ip = (self.headers.get('Fly-Client-IP')
                     or self.headers.get('X-Forwarded-For', '').split(',')[0].strip()
                     or self.client_address[0])
        req = urllib.request.Request(RELAY_ORIGIN + self.path,
                                     data=(raw if self.command == 'POST' else None),
                                     headers={'Content-Type': 'application/json',
                                              'X-Forwarded-For': client_ip}, method=self.command)
        try:
            self._send(urllib.request.urlopen(req, timeout=10).read())
        except Exception as e:
            self._send(json.dumps({'error': 'relay: ' + str(e)}))

    def _handle(self, body, raw=b''):
        u = urllib.parse.urlparse(self.path)
        if self.command == 'GET' and u.path in DOWNLOAD_PATHS:  # human landing / download page (front door)
            return self._send_html(DOWNLOAD_PAGE)
        if not u.path.startswith('/api/') and u.path != '/':   # /api/* is kt_server's; the rest is the relay's
            return self._proxy_relay(raw)
        self._send(route(u.path, urllib.parse.parse_qs(u.query), body))

    def do_GET(self):
        try:
            self._handle({})
        except Exception as e:
            self._send(json.dumps({'error': str(e)}))

    def do_POST(self):
        try:
            # Bound the request body: records are tiny; only blob uploads are large. Without a cap a
            # single multi-GB body is read whole into RAM (one thread per connection) → OOM.
            p = urllib.parse.urlparse(self.path).path
            limit = MAX_BLOB_BODY if 'blob' in p else MAX_JSON_BODY
            try:
                n = int(self.headers.get('Content-Length', 0) or 0)
            except ValueError:
                self._send(json.dumps({'error': 'bad content-length'})); return
            if n < 0 or n > limit:
                self._send(json.dumps({'error': 'body too large'})); return
            raw = self.rfile.read(n) if n else b''
            try:
                body = json.loads(raw or b'{}')
            except Exception:
                body = {}
            self._handle(body, raw)
        except Exception as e:
            self._send(json.dumps({'error': str(e)}))

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), H)
    print(f'ӾChat backend (python) on http://0.0.0.0:{PORT}  helpers={HERE}  XC_NS={NS}')
    srv.serve_forever()
