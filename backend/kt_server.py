#!/usr/bin/env python3
# ӾChat backend node — a small, hostable HTTP server that bridges the app to the network.
#
# Pure Python: it exposes the /api/* routes by delegating to the helper scripts alongside it
# (xc_feed.py, xc_post.py, xc_reldir.py, ...) and signs with nanopy (ed25519-blake2b). Anyone can
# run this — `python3 kt_server.py <port>` — on any OS, so the app is not tied to one machine.
# Wallet state is namespaced per instance (XC_NS = port): one node = one identity ("run your own node").
#
#   python3 kt_server.py 8790            # serve on :8790 (binds 0.0.0.0 so a phone/relay can reach it)
import os, sys, json, subprocess, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
NS = str(PORT)
# The helpers import xc_common (nanopy), so the right interpreter is by definition THIS one — it
# already imported it below. Defaulting to a bare 'python3' picked whichever came first on PATH,
# which on a machine with more than one Python is a different install with no nanopy: every helper
# then died and the node answered with a STALE result file (see read()).
PY = os.environ.get('XC_PYTHON', sys.executable or 'python3')
DM_PY = os.environ.get('XC_DM_PYTHON', PY)                  # kept as an override; xc_dm needs no extras now
sys.path.insert(0, HERE)
import xc_common as xc                                       # for api_me + wallet paths

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

# ---- inline routes ----
def api_me(acct):
    # SEEDLESS: the account comes from the app (it holds the key); the node only reads the balance.
    # The IDENTITY therefore needs no ledger at all, and must survive one being unreachable — a node
    # pointed at a down RPC should still let you see who you are, not fail to answer.
    bal = '0'
    if acct:
        try:
            ai = xc.rpc({'action': 'account_info', 'account': acct})
            bal = ai.get('balance', '0') if 'error' not in ai else '0'
        except Exception:
            bal = '0'
    return json.dumps({'handle': 'you.xno', 'account': acct, 'balance': bal})

def api_feed():
    spawn('xc_feed.py')
    content = read('/tmp/xc_feed_agg.json', '{}')
    blocks = read('/tmp/xc_onchain_count.txt', '0') or '0'
    return ('{"onchain_blocks":' + blocks +
            ',"transport":"plural relays + signed mutable heads","content":' + content + '}')

def api_labels():                                            # moderation labels (ported lazily; empty = off)
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
        return json.dumps({'opened': False, 'frontier': '0' * 64, 'balance': '0', 'representative': acct})
    return json.dumps({'opened': True, 'frontier': ai['frontier'], 'balance': ai['balance'],
                       'representative': ai.get('representative', acct)})

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

def api_media_relay(cid):
    # which relay serves this post's media (so a tip can reward it) — a public read across relays
    for r in xc.discover_relays():
        try:
            if json.loads(urllib.request.urlopen(r + '/haveblob?cid=' + cid, timeout=3).read()).get('have'):
                acct = json.loads(urllib.request.urlopen(r + '/relayacct', timeout=3).read()).get('account')
                return json.dumps({'account': acct or ''})
        except Exception:
            pass
    return json.dumps({'account': ''})

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

def api_status():
    try:
        bc = xc.rpc({'action': 'block_count'})
        return json.dumps({'online': True, 'height': bc.get('count', '0')})
    except Exception:
        return '{"online":false}'

# ---- dispatch: path -> handler(query, body) -> response string ----
def route(path, query, body):
    q = lambda k: (query.get(k, [''])[0])
    b = lambda k: (body.get(k, '') if isinstance(body, dict) else '')

    if path.startswith('/api/feed'):        return api_feed()
    if path.startswith('/api/relaydir'):     spawn('xc_reldir.py', 'engine');                     return read('/tmp/xc_relaydir.json', '{}')
    # prefix collisions: /api/media_relay must precede /api/media, which must precede /api/me.
    if path.startswith('/api/media_relay'):   return api_media_relay(q('cid'))
    if path.startswith('/api/media'):        put('/tmp/xc_media_cid.txt', q('cid')); spawn('xc_media.py');    return read('/tmp/xc_media_result.json', '{}')
    if path.startswith('/api/me'):           return api_me(q('account'))
    if path.startswith('/api/status'):       return api_status()
    if path.startswith('/api/labels'):       return api_labels()

    # on-device posting: two-step round-trip. These are prefixes of /api/post, so match them FIRST.
    if path.startswith('/api/post_prepare'):
        put('/tmp/xc_post_rec.json', json.dumps(body)); spawn('xc_post.py', 'prepare')   # app-signed post event
        return read('/tmp/xc_post_result.json', '{}')
    if path.startswith('/api/post_submit'):
        put('/tmp/xc_head_rec.json', json.dumps(body)); spawn('xc_post.py', 'submit')     # app-signed head
        return read('/tmp/xc_post_result.json', '{}')

    # SEEDLESS NODE: the legacy node-signed /api/post, /api/wallet and /api/settle are removed. Posting,
    # tips, sends and the wallet seed are all on-device now (see /api/post_prepare + /api/post_submit and
    # /api/block_process). The node never receives, stores, or signs with a seed.

    if path.startswith('/api/like'):         spawn('xc_engage.py', 'like', b('post_id'), b('delta'));        return read('/tmp/xc_engage_result.json', '{}')
    if path.startswith('/api/repost'):       put('/tmp/xc_reshare_acct.txt', b('account')); spawn('xc_engage.py','repost',b('post_id'),b('delta')); return read('/tmp/xc_engage_result.json','{}')
    if path.startswith('/api/tipstat'):      spawn('xc_engage.py', 'tip', b('post_id'), b('raw'));           return read('/tmp/xc_engage_result.json', '{}')
    if path.startswith('/api/view'):         spawn('xc_engage.py', 'view', b('post_id'), b('delta'));        return read('/tmp/xc_engage_result.json', '{}')
    if path.startswith('/api/engagement'):   spawn('xc_engage.py', 'get');                                    return read('/tmp/xc_engage_result.json', '{}')
    if path.startswith('/api/notify_push'):
        for k, fn in (('to','xc_np_to'),('from','xc_np_from'),('kind','xc_np_kind'),('text','xc_np_text')):
            put(f'/tmp/{fn}.txt', b(k))
        spawn('xc_engage.py', 'notify');     return read('/tmp/xc_engage_result.json', '{}')
    if path.startswith('/api/notify'):       spawn('xc_notify.py');                                           return read('/tmp/xc_notify.json', '{}')

    # on-device money: the app builds + signs every state block; the node only reads ledger state and
    # adds delegated PoW + broadcasts a fully-signed block (send / receive / open / change / settle).
    if path.startswith('/api/account_state'): return api_account_state(q('account'))
    if path.startswith('/api/receivables'):   return api_receivables(q('account'))
    if path.startswith('/api/block_process'):
        put('/tmp/xc_block_in.json', json.dumps(body)); spawn('xc_blockproc.py')   # app-signed block; node adds PoW + broadcasts
        return read('/tmp/xc_block_result.json', '{}')

    if path.startswith('/api/follows_set'):  put('/tmp/xc_follows_rec.json', json.dumps(body)); spawn('xc_follows.py','pub'); return read('/tmp/xc_follows_result.json','{}')
    if path.startswith('/api/follows_get'):  put('/tmp/xc_follows_acct.txt', q('account')); spawn('xc_follows.py', 'get');  return read('/tmp/xc_follows_result.json', '{}')

    if path.startswith('/api/comment_post'):
        put('/tmp/xc_comment_rec.json', json.dumps(body))   # app-signed record; node verifies + relays
        spawn('xc_comments.py', 'post');     return read('/tmp/xc_comments_result.json', '{}')
    if path.startswith('/api/comments_get'): put('/tmp/xc_comment_post.txt', q('post')); spawn('xc_comments.py','get'); return read('/tmp/xc_comments_result.json','{}')

    if path.startswith('/api/profile_set'):
        put('/tmp/xc_profile_rec.json', json.dumps(body))   # app-signed record; node verifies + relays
        spawn('xc_profile.py', 'pub');       return read('/tmp/xc_profile_result.json', '{}')
    if path.startswith('/api/profile_get'):  put('/tmp/xc_profile_account.txt', q('account')); spawn('xc_profile.py','get'); return read('/tmp/xc_profile_result.json','{}')

    if path.startswith('/api/poll_vote'):    put('/tmp/xc_poll_rec.json', json.dumps(body)); spawn('xc_poll.py','vote'); return read('/tmp/xc_poll_result.json','{}')
    if path.startswith('/api/poll_get'):     put('/tmp/xc_poll_id.txt', q('poll')); put('/tmp/xc_poll_acct.txt', q('account')); spawn('xc_poll.py','get'); return read('/tmp/xc_poll_result.json', '{}')

    # on-device DMs: the app seals/opens locally; the node verifies the signed key record + relays ciphertext.
    if path.startswith('/api/dm_key_set'):   put('/tmp/xc_dm_rec.json', json.dumps(body)); spawn('xc_dm.py','register'); return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_key_get'):   put('/tmp/xc_dm_peer.txt', q('account')); spawn('xc_dm.py','keyget');       return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_send'):      put('/tmp/xc_dm_msg.json', json.dumps(body)); spawn('xc_dm.py','send');    return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_inbox'):     put('/tmp/xc_dm_acct.txt', q('account')); spawn('xc_dm.py','inbox');       return read('/tmp/xc_dm_result.json','{}')

    if path.startswith('/api/blob_put'):     put('/tmp/xc_blob_in.txt', b('b64')); spawn('xc_blobput.py');    return read('/tmp/xc_blobput_result.json', '{}')

    if path.startswith('/api/release_check'): put('/tmp/xc_rel_current.txt', q('current')); spawn('xc_release.py','check'); return read('/tmp/xc_release_result.json','{}')
    if path.startswith('/api/release_fetch'): put('/tmp/xc_rel_cid.txt', b('cid')); put('/tmp/xc_rel_sha.txt', b('sha256')); spawn('xc_release.py','fetch'); return read('/tmp/xc_release_result.json','{}')

    if path.startswith('/api/head'):         return api_head(q('account'))   # app re-signs it to republish (seedless)
    if path.startswith('/api/gossip'):       spawn('xc_gossip.py');                                           return read('/tmp/xc_gossip_result.json', '{}')
    if path.startswith('/api/pincontent'):   spawn('xc_pin.py');                                              return read('/tmp/xc_pin_result.json', '{}')
    if path.startswith('/api/supporter'):
        put('/tmp/xc_supporter_in.json', json.dumps({'account': b('account'), 'on': b('on'), 'ts': b('ts')}))
        spawn('xc_supporter.py');            return read('/tmp/xc_supporter_result.json', '{}')

    return '{"error":"not found"}'


class H(BaseHTTPRequestHandler):
    def _send(self, body):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self, body):
        u = urllib.parse.urlparse(self.path)
        self._send(route(u.path, urllib.parse.parse_qs(u.query), body))

    def do_GET(self):
        try:
            self._handle({})
        except Exception as e:
            self._send(json.dumps({'error': str(e)}))

    def do_POST(self):
        try:
            n = int(self.headers.get('Content-Length', 0) or 0)
            raw = self.rfile.read(n) if n else b''
            try:
                body = json.loads(raw or b'{}')
            except Exception:
                body = {}
            self._handle(body)
        except Exception as e:
            self._send(json.dumps({'error': str(e)}))

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), H)
    print(f'ӾChat backend (python) on http://0.0.0.0:{PORT}  helpers={HERE}  XC_NS={NS}')
    srv.serve_forever()
