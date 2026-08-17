#!/usr/bin/env python3
"""Sending a DM must not stall behind one slow or dead relay.

The node fans a DM out to every relay. Serially — the old code — one relay in the set being down (a
sleeping laptop, a churned tunnel) meant every send waited out that relay's 4s timeout before it
finished. Stacked with the per-relay key fetch, "message a peer" spun for 15-30s. Watched it happen
live while a relay was down.

The fix fans out in parallel, so a send costs the SLOWEST single relay, not the sum. This drives the
REAL xc_dm.py send path against stub relays where one is slow, and asserts the whole send finishes in
about one slow-relay-time, not two.

    python3 test/dm_send_parallel_test.py
"""
import json, os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, 'backend')
SLOW = 2.0                       # each stub relay sleeps this long on a write

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p


class StubRelay:
    """Answers /relays instantly (so discovery finds it) and SLOWLY on the write paths."""

    def __init__(self):
        port = free_port()
        self.url = f'http://127.0.0.1:{port}'
        u = self.url

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, obj):
                b = json.dumps(obj).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)

            def do_GET(self):
                if self.path.startswith('/relays'):
                    self._send({'relays': [u], 'peers': []})
                elif self.path.startswith('/dmkey'):
                    time.sleep(SLOW)                 # slow key lookup
                    self._send({'record': None})
                else:
                    self._send({})

            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0) or 0)
                self.rfile.read(n)
                if self.path.startswith('/dm'):
                    time.sleep(SLOW)                 # slow write — the thing that used to stall the send
                self._send({'ok': True, 'stored': 1})

        self.srv = ThreadingHTTPServer(('127.0.0.1', port), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def stop(self):
        self.srv.shutdown()


def run_send(bootstrap, record):
    """Drive the REAL xc_dm.py 'send' against the given relays; return wall-clock seconds."""
    open('/tmp/xc_dm_msg.json', 'w').write(json.dumps(record))
    env = dict(os.environ, XC_ISOLATE='1', XCHAT_BOOTSTRAP=','.join(bootstrap),
               XC_NANO_RPC='http://127.0.0.1:9')
    t0 = time.time()
    subprocess.run([sys.executable, 'xc_dm.py', 'send'], cwd=BACKEND, env=env, timeout=30)
    return time.time() - t0


REC = {'to': 'nano_1bob', 'from': 'nano_1alice', 'from_pk': 'aa' * 32,
       'to_pk': 'bb' * 32, 'ct': 'CIPHER', 'ts': 1786900000}

stubs = [StubRelay() for _ in range(3)]
try:
    print(f'--- three relays, each {SLOW}s on a write ---')
    dt = run_send([s.url for s in stubs], REC)
    # Serial would be 3 x SLOW = 6s. Parallel is ~1 x SLOW plus a little discovery overhead.
    check(dt < SLOW * 2, f'the send fans out in parallel, not in series ({dt:.1f}s)',
          f'{dt:.1f}s — serial would be ~{SLOW * 3:.0f}s')
    # And it must still actually report the write result.
    res = json.load(open('/tmp/xc_dm_result.json'))
    check(res.get('ok') is True, 'the send still reports its result', json.dumps(res))

    print('\n--- one live relay + two DEAD ones (nothing listening) ---')
    dead = [f'http://127.0.0.1:{free_port()}' for _ in range(2)]   # closed ports
    # Discovery only finds relays that answer /relays, so a purely-dead URL is dropped before the
    # write fan-out. The point stands: a live send is not held hostage by dead peers.
    dt2 = run_send([stubs[0].url] + dead, REC)
    check(dt2 < SLOW * 2.5, f'a send with dead relays in the mix still returns promptly ({dt2:.1f}s)',
          f'{dt2:.1f}s')
finally:
    for s in stubs:
        s.stop()

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
