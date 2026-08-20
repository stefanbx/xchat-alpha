#!/usr/bin/env python3
"""Tip PoW discovery reaches hub-fronted MESH work-providers, not just the public relay set.

A GPU laptop behind NAT runs as a public mesh node: it serves /work and advertises `work: true` on
/relayacct, but — being private-by-secret — it never appears in the /relays gossip set that
discover_relays() walks. So before this change the tip work race in xc_blockproc could never use it,
and all that hub-fronted GPU capacity sat idle while GPU-less nodes fell back to slow public RPC.

The fix: _refresh_work_relays now also sweeps each hub's /mesh_nodes for the <hub>/r/<token> reach
bases and probes them for the work cap, so a work:true mesh node joins the same race. Every work answer
is still validated locally, so no trust in the mesh node is introduced.

This test stands up a stub hub (a /mesh_nodes list + tunnel-fronted /relayacct and /work) and drives the
real discovery + race helpers against it.

    python3 test/mesh_work_provider_test.py
"""
import json, os, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault('XC_ISOLATE', '1')                       # keep xc_common off the real ledger
os.environ.setdefault('XC_NANO_RPC', 'http://127.0.0.1:1')
os.environ['XC_WORK_PEERS_CACHE'] = tempfile.mktemp(suffix='.json')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location('xc_blockproc', os.path.join(REPO, 'backend', 'xc_blockproc.py'))
bp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bp)

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

GPU_TOK  = 'a' * 64          # a mesh node that advertises work:true (the GPU laptop)
IDLE_TOK = 'b' * 64          # a mesh node that does NOT serve work
WORK_HEX = '0123456789abcdef'

class Hub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path.split('?', 1)[0]
        if p == '/relays':                       # the public set the gossip walk sees — no work relays here
            return self._json({'relays': [], 'peers': []})
        if p == '/mesh_nodes':                    # the hub lists its attached public mesh nodes here
            return self._json({'nodes': [GPU_TOK, IDLE_TOK], 'hub': SELF})
        if p == f'/r/{GPU_TOK}/relayacct':        # tunnel-fronted: the GPU node advertises work
            return self._json({'work': True, 'account': 'nano_gpu'})
        if p == f'/r/{IDLE_TOK}/relayacct':       # the idle node does not
            return self._json({'work': False, 'account': 'nano_idle'})
        if p == f'/r/{GPU_TOK}/work':             # and it can actually serve a solve for the race
            return self._json({'work': WORK_HEX})
        self._json({'error': 'not found'}, 404)

srv = ThreadingHTTPServer(('127.0.0.1', 0), Hub)
SELF = f'http://127.0.0.1:{srv.server_address[1]}'
threading.Thread(target=srv.serve_forever, daemon=True).start()

try:
    print('--- 1. the hub sweep turns /mesh_nodes into reach bases ---')
    cands = bp._mesh_work_candidates([SELF])
    check(f'{SELF}/r/{GPU_TOK}' in cands, 'the GPU mesh node becomes a <hub>/r/<token> candidate')
    check(f'{SELF}/r/{IDLE_TOK}' in cands, 'candidates are collected before the work-cap probe (both appear)')
    check(bp._mesh_work_candidates([f'{SELF}/r/{GPU_TOK}']) == [], 'a reach url is not itself swept (no recursion)')
    check(bp._mesh_work_candidates(['http://127.0.0.1:9']) == [], 'an unreachable / non-hub is skipped, not fatal')

    print('\n--- 2. discovery adds the work:true mesh node to the race, and only that one ---')
    bp.xc.discover_relays = lambda *a, **k: [SELF]     # the public set is just this hub, with no work relays
    found = bp._refresh_work_relays()
    check(f'{SELF}/r/{GPU_TOK}' in found, 'the GPU mesh node (work:true) is discovered as a work provider')
    check(f'{SELF}/r/{IDLE_TOK}' not in found, 'the idle mesh node (work:false) is excluded')
    check(SELF not in found, 'the hub itself (no /relayacct work) is not a work provider')

    print('\n--- 3. the discovered reach base actually serves the race ---')
    w = bp._work_via_relay(f'{SELF}/r/{GPU_TOK}', '00' * 32, 5)
    check(w == WORK_HEX, 'the race can fetch /work from the discovered mesh reach base')

    print('\n--- 4. it is gated by the same discover switch (privacy) ---')
    # _mesh_work_candidates is reached only from _refresh_work_relays, itself only from _work_relays when
    # WORK_DISCOVER is on — assert the plumbing exists rather than re-import with a different env.
    src = open(os.path.join(REPO, 'backend', 'xc_blockproc.py')).read()
    check('_mesh_work_candidates(relays)' in src, '_refresh_work_relays calls the mesh sweep')
    check('WORK_DISCOVER' in src and 'if not WORK_DISCOVER' in src, 'discovery (mesh included) is behind XC_WORK_DISCOVER')
finally:
    srv.shutdown()

print()
if fails:
    print(f'FAIL — {checks} checks, {len(fails)} failure(s)')
    sys.exit(1)
print(f'PASS — {checks} checks, 0 failure(s)')
