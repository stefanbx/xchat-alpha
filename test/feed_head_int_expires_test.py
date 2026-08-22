#!/usr/bin/env python3
# REGRESSION: the feed aggregator must build a head's post from the head's fields EXACTLY as signed.
# sig_canon stringifies every field with str(), so a head whose `expires` (or `seq`) is an integer on
# the wire signs a preimage containing "1787..." — if xc_feed coerces that field to float before
# re-deriving the preimage ("1787...0.0"), EVERY head fails signature verification and the whole feed
# goes blank for everyone. This test signs a head with an integer expires+seq, serves it from a stub
# relay, runs the real xc_feed.py, and asserts the post lands in the feed cache. It also serves one
# MALFORMED head alongside it to prove a bad record is skipped (not fatal), never blanking the good one.
import json, os, sys, time, base64, hashlib, tempfile, subprocess, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(REPO, "backend", "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

# --- a signed author + a content blob addressed by a sha256 CID (no IPFS daemon needed) ---
priv = hashlib.sha256(b'feed-int-expires-test-key').hexdigest()      # deterministic 32-byte key
author, pub = xc.derive(priv)
content = json.dumps({'posts': [{'id': 'p_int', 'ts': 1700000000, 'text': 'hello from an int-expires head'}]}).encode()
cid = 'sha256-' + hashlib.sha256(content).hexdigest()
assert xc.content_matches_cid(cid, content)

seq = 7                                                # INTEGER seq
expires = int(time.time()) + 3600                      # INTEGER expires, an hour out
lines = xc._sign_lines(priv, xc.sig_canon('head', author, seq, cid, expires))
sig = [l.split(' ', 1)[1] for l in lines if l.startswith('sig ')][0]
good_head = {'author': author, 'seq': seq, 'cid': cid, 'pub': pub, 'sig': sig, 'expires': expires}
bad_head = {'author': author, 'seq': 'not-a-number', 'cid': cid, 'pub': pub, 'sig': sig}  # must be skipped

class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/heads'):   self._j({'heads': [good_head, bad_head]})
        elif self.path.startswith('/relays'): self._j({'relays': []})
        elif self.path.startswith('/reports'): self._j({'reports': {}})
        elif self.path.startswith('/blob'):   self._j({'b64': base64.b64encode(content).decode()})
        else: self._j({})

srv = HTTPServer(('127.0.0.1', 0), Stub)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
STUB = f'http://127.0.0.1:{port}'

feed_cache = tempfile.mktemp(suffix='.json')
empty_ipfs = tempfile.mkdtemp()                        # no repo -> ipfs cat fails fast -> relay /blob fallback
env = dict(os.environ, XC_ISOLATE='1', XCHAT_BOOTSTRAP=STUB, XC_FEED_CACHE=feed_cache,
           XC_CONTENT_CACHE=tempfile.mkdtemp(), IPFS_PATH=empty_ipfs, XC_FEED_WORKERS='4')
r = subprocess.run([sys.executable, os.path.join(REPO, 'backend', 'xc_feed.py')],
                   env=env, capture_output=True, text=True, timeout=60)

fails = 0
def check(cond, msg):
    global fails
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: fails += 1

check(os.path.exists(feed_cache), 'feed cache was written')
doc = json.load(open(feed_cache)) if os.path.exists(feed_cache) else {}
posts = doc.get('posts', [])
check(doc.get('authors', 0) == 1, f'the int-expires head verified (authors=1, got {doc.get("authors")})')
check(any(p.get('id') == 'p_int' for p in posts),
      'the post from the int-expires head is in the feed (would be EMPTY if expires were coerced to float)')
check(doc.get('relays_up', 0) == 1, 'the stub relay counted as up')

srv.shutdown()
print(f"\n{'PASS' if fails == 0 else 'FAIL'} — {fails} failure(s)")
sys.exit(1 if fails else 0)
