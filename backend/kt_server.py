#!/usr/bin/env python3
# ӾChat backend — a HOSTABLE port of the Keel engine (kt_server.kl).
#
# The Keel engine only runs on macOS/arm64, so a public APK can't use it. This is the same server
# in Python: it exposes the identical /api/* routes by reusing the very same helper scripts the Keel
# engine spawned (xc_feed.py, xc_post.py, xc_reldir.py, ...). Anyone can run this — `python3 kt_server.py
# <port>` — on any OS, so the app is not tied to one person's Mac. Wallet state is namespaced per
# instance (XC_NS = port), matching the engine: one backend = one identity ("run your own node").
#
#   python3 kt_server.py 8790            # serve on :8790 (binds 0.0.0.0 so a phone/relay can reach it)
import os, sys, json, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
NS = str(PORT)
PY = os.environ.get('XC_PYTHON', 'python3')                 # helper interpreter
DM_PY = os.environ.get('XC_DM_PYTHON', PY)                  # xc_dm needs PyNaCl; override if separate
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
    try:
        return open(path).read()
    except Exception:
        return default

# ---- inline routes (were Keel crypto/curl) ----
def api_me():
    try:
        acct = xc.wallet_acct()
        ai = xc.rpc({'action': 'account_info', 'account': acct})
        bal = ai.get('balance', '0') if 'error' not in ai else '0'
    except Exception:
        acct, bal = '', '0'
    return json.dumps({'handle': 'you.xno', 'account': acct, 'balance': bal})

def api_feed():
    spawn('xc_feed.py')
    content = read('/tmp/xc_feed_agg.json', '{}')
    blocks = read('/tmp/xc_onchain_count.txt', '0') or '0'
    return ('{"onchain_blocks":' + blocks +
            ',"transport":"plural relays + signed mutable heads","content":' + content + '}')

def api_labels():                                            # moderation labels (ported lazily; empty = off)
    return '{"labelers":[]}'

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
    if path.startswith('/api/me'):           return api_me()
    if path.startswith('/api/status'):       return api_status()
    if path.startswith('/api/labels'):       return api_labels()

    if path.startswith('/api/media'):        put('/tmp/xc_media_cid.txt', q('cid')); spawn('xc_media.py');    return read('/tmp/xc_media_result.json', '{}')

    if path.startswith('/api/post'):
        for k, fn in (('text','xc_post_in'),('media','xc_post_media'),('quote','xc_post_quote'),
                      ('reply_to','xc_post_reply'),('title','xc_post_title'),('poll','xc_post_poll'),
                      ('mediakind','xc_post_mediakind')):
            put(f'/tmp/{fn}.txt', b(k))
        spawn('xc_post.py');                 return read('/tmp/xc_post_result.json', '{}')

    if path.startswith('/api/wallet'):
        seed = b('seed')
        if len(seed) < 64: return '{"ok":false,"error":"seed must be 64 hex chars"}'
        put(wallet_file(), seed[:64]); spawn('xc_wallet.py');                                     return read('/tmp/xc_wallet_result.json', '{}')

    if path.startswith('/api/settle'):
        for k, fn in (('to','xc_settle_to'),('amount','xc_settle_amt'),('media','xc_settle_media'),
                      ('split','xc_settle_split'),('reposter','xc_settle_reposter'),('rsplit','xc_settle_rsplit')):
            put(f'/tmp/{fn}.txt', b(k))
        put('/tmp/xc_settle_result.json', '{"ok":false,"error":"settlement did not complete"}')
        spawn('xc_settle.py');               return read('/tmp/xc_settle_result.json', '{}')

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

    if path.startswith('/api/send'):
        put('/tmp/xc_send_to.txt', b('to')); put('/tmp/xc_send_amt.txt', b('amount'))
        put('/tmp/xc_send_result.json', '{"ok":false,"error":"send did not complete"}')
        spawn('xc_send.py');                  return read('/tmp/xc_send_result.json', '{}')
    if path.startswith('/api/receive'):      spawn('xc_receive.py');                                          return read('/tmp/xc_receive_result.json', '{}')
    if path.startswith('/api/rep_get'):      spawn('xc_changerep.py', 'get');                                 return read('/tmp/xc_rep_result.json', '{}')
    if path.startswith('/api/rep_set'):      put('/tmp/xc_rep_to.txt', b('representative')); spawn('xc_changerep.py','set'); return read('/tmp/xc_rep_result.json','{}')

    if path.startswith('/api/follows_set'):  put('/tmp/xc_follows_csv.txt', b('follows')); spawn('xc_follows.py','pub'); return read('/tmp/xc_follows_result.json','{}')
    if path.startswith('/api/follows_get'):  spawn('xc_follows.py', 'get');                                   return read('/tmp/xc_follows_result.json', '{}')

    if path.startswith('/api/comment_post'):
        for k, fn in (('post_id','xc_comment_post'),('text','xc_comment_text'),('handle','xc_comment_handle'),('parent','xc_comment_parent')):
            put(f'/tmp/{fn}.txt', b(k))
        spawn('xc_comments.py', 'post');     return read('/tmp/xc_comments_result.json', '{}')
    if path.startswith('/api/comments_get'): put('/tmp/xc_comment_post.txt', q('post')); spawn('xc_comments.py','get'); return read('/tmp/xc_comments_result.json','{}')

    if path.startswith('/api/profile_set'):
        for k, fn in (('display','xc_profile_display'),('bio','xc_profile_bio'),('avatar','xc_profile_avatar'),('banner','xc_profile_banner')):
            put(f'/tmp/{fn}.txt', b(k))
        spawn('xc_profile.py', 'pub');       return read('/tmp/xc_profile_result.json', '{}')
    if path.startswith('/api/profile_get'):  put('/tmp/xc_profile_account.txt', q('account')); spawn('xc_profile.py','get'); return read('/tmp/xc_profile_result.json','{}')

    if path.startswith('/api/poll_vote'):    put('/tmp/xc_poll_id.txt', b('poll_id')); put('/tmp/xc_poll_option.txt', b('option')); spawn('xc_poll.py','vote'); return read('/tmp/xc_poll_result.json','{}')
    if path.startswith('/api/poll_get'):     put('/tmp/xc_poll_id.txt', q('poll')); spawn('xc_poll.py','get');  return read('/tmp/xc_poll_result.json', '{}')

    if path.startswith('/api/dm_send'):      put('/tmp/xc_dm_to.txt', b('to')); put('/tmp/xc_dm_text.txt', b('text')); spawn('xc_dm.py','send',py=DM_PY); return read('/tmp/xc_dm_result.json','{}')
    if path.startswith('/api/dm_inbox'):     spawn('xc_dm.py', 'inbox', py=DM_PY);                             return read('/tmp/xc_dm_result.json', '{}')

    if path.startswith('/api/blob_put'):     put('/tmp/xc_blob_in.txt', b('b64')); spawn('xc_blobput.py');    return read('/tmp/xc_blobput_result.json', '{}')

    if path.startswith('/api/release_check'): put('/tmp/xc_rel_current.txt', q('current')); spawn('xc_release.py','check'); return read('/tmp/xc_release_result.json','{}')
    if path.startswith('/api/release_fetch'): put('/tmp/xc_rel_cid.txt', b('cid')); put('/tmp/xc_rel_sha.txt', b('sha256')); spawn('xc_release.py','fetch'); return read('/tmp/xc_release_result.json','{}')

    if path.startswith('/api/republish'):    spawn('xc_republish.py');                                        return read('/tmp/xc_republish_result.json', '{}')
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
