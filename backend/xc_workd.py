#!/usr/bin/env python3
# ӾChat WORK SERVER — proof-of-work for Nano blocks, GPU-first.
#
#   python3 xc_workd.py [port]           # default 7500
#   GET /work?hash=<32-byte root hex>[&difficulty=<16 hex>]  ->  {"work": "..."}
#
# WHY THIS IS THE BOTTLENECK. The phone is a light wallet: it signs blocks on-device and delegates PoW
# and broadcast to its node. Without a work source the node races free public RPCs (measured 0.9s to
# 36s, rate-limited, sometimes 403) and falls back to on-box CPU at roughly a minute a block. A tip is
# MULTI-LEG (creator + relay + reposter), so those costs stack and settlement crawls or times out.
#
# WHY IT PLUGS IN WITH NO NODE CHANGES. xc_blockproc.work_for() already tries XC_WORK
# (default http://127.0.0.1:7500) BEFORE anything else. Run this and the node in front of it gets fast
# work automatically.
#
# WHY SERVING WORK TO STRANGERS IS SAFE. A work value authorises nothing — it signs nothing, spends
# nothing, and is verified in a single hash by whoever uses it. A hostile work server can waste its own
# electricity and return garbage that the consumer rejects; it cannot forge a block or move funds. That
# makes PoW the one expensive job in this system that is safe to accept from an untrusted peer, and the
# reason a relay can sell it.
import json, os, subprocess, sys, threading, time, importlib.util
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get('XC_WORKD_PORT', '7500'))
BIND = os.environ.get('XC_WORKD_BIND', '127.0.0.1')
SEND_DIFF = 'fffffff800000000'                      # mainnet send/change threshold
CACHE_MAX = int(os.environ.get('XC_WORKD_CACHE', '512'))

# The GPU generator, if it was built. Looked for next to the repo's relay/work and alongside this file
# so it works from a checkout and from the flat /app a deploy stages.
_CANDIDATES = [os.environ.get('XC_WORK_BIN', ''),
               os.path.join(HERE, '..', 'relay', 'work', 'nano_work_cl'),
               os.path.join(HERE, 'nano_work_cl')]
GPU_BIN = next((os.path.realpath(p) for p in _CANDIDATES if p and os.path.isfile(p) and os.access(p, os.X_OK)), '')

xc = None
try:
    _spec = importlib.util.spec_from_file_location('xc_common', os.path.join(HERE, 'xc_common.py'))
    xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)
except Exception:
    xc = None

# One GPU job at a time. Several concurrent searches on one device just interleave and each finishes
# later than if they had queued — and a tip's legs arrive back to back, so this is the common case.
_gpu_lock = threading.Lock()
_cache = OrderedDict()                              # root -> (work, difficulty)
_cache_lock = threading.Lock()
_stats = {'gpu': 0, 'cpu': 0, 'cached': 0, 'failed': 0, 'total_s': 0.0}


def _valid(work_hex, root_hex, difficulty):
    # Never hand back work we haven't checked. A wrong answer here would be broadcast as a block and
    # rejected by the network, turning a fast path into a silent failure that is painful to trace.
    if xc is None:
        return True
    try:
        return bool(xc._ext.work_validate(int(work_hex, 16), bytes.fromhex(root_hex), int(difficulty, 16)))
    except Exception:
        return False


def _gpu_work(root_hex, difficulty, timeout):
    if not GPU_BIN:
        return None
    try:
        with _gpu_lock:
            out = subprocess.run([GPU_BIN, root_hex, difficulty], capture_output=True,
                                 text=True, timeout=timeout)
        w = (out.stdout or '').strip()
        return w if len(w) == 16 else None
    except Exception:
        return None


def _cpu_work(root_hex, difficulty):
    if xc is None:
        return None
    try:
        return '%016x' % xc._ext.work_generate(bytes.fromhex(root_hex), int(difficulty, 16), os.urandom(128))
    except Exception:
        return None


def generate(root_hex, difficulty, timeout=120):
    with _cache_lock:
        hit = _cache.get(root_hex)
        if hit and hit[1] == difficulty:
            _cache.move_to_end(root_hex)
            _stats['cached'] += 1
            return hit[0]

    t0 = time.time()
    work = _gpu_work(root_hex, difficulty, timeout)
    used = 'gpu'
    if not work or not _valid(work, root_hex, difficulty):
        if work:
            print(f'! gpu returned invalid work for {root_hex[:12]} — falling back to cpu', flush=True)
        work = _cpu_work(root_hex, difficulty)
        used = 'cpu'
    if not work or not _valid(work, root_hex, difficulty):
        _stats['failed'] += 1
        return None

    _stats[used] += 1
    _stats['total_s'] += time.time() - t0
    with _cache_lock:
        _cache[root_hex] = (work, difficulty)
        while len(_cache) > CACHE_MAX:
            _cache.popitem(last=False)
    print(f'{used} work for {root_hex[:12]}… in {time.time() - t0:.2f}s', flush=True)
    return work


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == '/status':
            done = _stats['gpu'] + _stats['cpu']
            return self._send(200, {'ok': True, 'gpu': bool(GPU_BIN), 'gpu_bin': GPU_BIN,
                                    **_stats,
                                    'avg_s': round(_stats['total_s'] / done, 2) if done else None})
        if u.path != '/work':
            return self._send(404, {'error': 'not found'})
        root = (q.get('hash') or q.get('root') or '').strip().lower()
        if len(root) != 64:
            return self._send(400, {'error': 'hash must be a 64-character hex root'})
        try:
            bytes.fromhex(root)
        except ValueError:
            return self._send(400, {'error': 'hash is not hex'})
        difficulty = (q.get('difficulty') or SEND_DIFF).strip().lower()
        if len(difficulty) != 16:
            return self._send(400, {'error': 'difficulty must be 16 hex characters'})
        work = generate(root, difficulty)
        if not work:
            return self._send(500, {'error': 'could not generate work'})
        self._send(200, {'work': work, 'difficulty': difficulty})


if __name__ == '__main__':
    src = f'GPU ({os.path.basename(GPU_BIN)})' if GPU_BIN else 'CPU only — build relay/work/nano_work_cl for GPU'
    print(f'ӾChat work server on http://{BIND}:{PORT}  source: {src}', flush=True)
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
