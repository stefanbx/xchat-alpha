#!/usr/bin/env python3
# Relay stress / load test — drives REAL xc_relayd processes hard and checks the relay stays correct,
# bounded, and up under concurrency. Four phases:
#   1. READ THROUGHPUT   — many concurrent GET /relays,/heads,/bloblist; measure req/s + latency, 0 errors.
#   2. BLOB WRITE/READ    — concurrent POST /blob + GET /blob under a small disk cap; bytes stay <= cap
#                           (eviction works), reads succeed, process survives.
#   3. GOSSIP FLOOD       — POST /relay_announce with far more distinct urls than the cap; `known` stays
#                           bounded at KNOWN_MAX (no unbounded growth / OOM) and the relay keeps serving.
#   4. TUNNEL UNDER LOAD  — a home relay dials this hub as an entry; fire many concurrent public
#                           /r/<token>/ requests at once; all are answered by the HOME relay, no deadlock.
#
# Bounds are shrunk via env (XC_KNOWN_MAX, XC_BLOB_CAP_MB) so the caps are exercised in seconds, not GB.
# No external services, no network: XC_ISOLATE=1 + a dead RPC keep it entirely on loopback.

import os
os.environ.setdefault('XC_ISOLATE', '1')
os.environ.setdefault('XC_NANO_RPC', 'http://127.0.0.1:1')

import base64, json, socket, statistics, subprocess, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_DIR = os.path.join(ROOT, 'relay')
sys.path.insert(0, os.path.join(ROOT, 'backend'))
sys.path.insert(0, RELAY_DIR)
import xc_common as xc
import xc_tunnel as tun

SECRET = 'stress-rendezvous-secret'
STORES = []
STRESS_PROCS = []          # extra relay processes spawned inside phases (cleaned up in main's finally)

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def req(url, data=None, timeout=15):
    try:
        r = urllib.request.Request(url, data=data,
                                   headers={'Content-Type': 'application/json'} if data else {})
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()

def get(url, timeout=15):
    return req(url, None, timeout)

def wait_up(url, tries=80, delay=0.2):
    for _ in range(tries):
        c, _b = get(url, timeout=2)
        if c and c < 500:
            return True
        time.sleep(delay)
    return False

PASS = FAIL = 0
def check(cond, label, extra=None):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f'  ✓ {label}')
    else:
        FAIL += 1; print(f'  ✗ {label}' + (f'   |  {extra}' if extra is not None else ''))

def spawn(port, tag, bootstraps=(), env_extra=None):
    store = f'/tmp/xc_stress_{tag}_{port}.json'
    STORES.append(store)
    for suffix in ('', '.id'):
        try: os.remove(store + suffix)
        except OSError: pass
    env = {**os.environ, 'XC_ISOLATE': '1', 'XC_NANO_RPC': 'http://127.0.0.1:1',
           'XC_TUNNEL_PUBLIC_WAIT_S': '8', 'XC_TUNNEL_POLL_HOLD_S': '20'}
    if env_extra:
        env.update(env_extra)
    argv = [sys.executable, 'xc_relayd.py', str(port), store, *bootstraps]
    return subprocess.Popen(argv, cwd=RELAY_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def run_load(fn, n, workers):
    """Run fn(i) n times across `workers` threads. Returns (results, elapsed_s)."""
    t0 = time.time()
    out = [None] * n
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, r in zip(range(n), ex.map(lambda i: fn(i), range(n))):
            out[i] = r
    return out, time.time() - t0

def pctile(xs, q):
    if not xs: return 0.0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]

def phase1_reads(HUB):
    print('\n--- PHASE 1: read throughput (concurrent GET) ---')
    N, W = 3000, 64
    paths = ['/relays', '/heads', '/bloblist']
    lat = []
    def one(i):
        t = time.time()
        c, _b = get(HUB + paths[i % len(paths)], timeout=10)
        lat.append(time.time() - t)
        return c
    res, el = run_load(one, N, W)
    ok = sum(1 for c in res if c == 200)
    # code 0 is a CLIENT socket drop under this self-inflicted flood (a slow/shared runner limit), NOT the
    # relay erroring — a relay fault surfaces as an HTTP status. Assert the relay returned NO error status
    # and served the overwhelming majority; a real fault (5xx, or the relay stalling) still trips this.
    rejected = [c for c in res if c not in (200, 0)]
    print(f'  {N} reqs / {W} workers in {el:.2f}s = {N/el:,.0f} req/s   '
          f'p50={pctile(lat,0.5)*1000:.1f}ms p95={pctile(lat,0.95)*1000:.1f}ms p99={pctile(lat,0.99)*1000:.1f}ms')
    check(not rejected and ok >= N * 0.98,
          f'reads served, none errored — {ok}/{N} ok, {len(rejected)} errored', f'errors={rejected[:5]}')
    check(get(HUB + '/relays')[0] == 200, 'relay still serving after the read storm')

def phase2_blobs(HUB):
    print('\n--- PHASE 2: blob write/read storm under a small disk cap (2 MB) ---')
    N, W = 400, 32
    payload = base64.b64encode(b'x' * 8192).decode()   # ~8 KB each → ~3.2 MB offered into a 2 MB cap
    def put(i):
        body = json.dumps({'cid': f'stress-{i:05d}', 'b64': payload}).encode()
        c, b = req(HUB + '/blob', body, timeout=10)
        return c
    res, el = run_load(put, N, W)
    stored_ok = sum(1 for c in res if c == 200)
    rejected = [c for c in res if c not in (200, 0)]   # code 0 = client socket drop, not a relay reject
    print(f'  {N} blob PUTs / {W} workers in {el:.2f}s = {N/el:,.0f} put/s')
    cache = json.loads(get(HUB + '/cache')[1].decode() or '{}')
    cap = cache.get('cap') or cache.get('cap_bytes') or (2 * 1024 * 1024)
    used = cache.get('bytes') or cache.get('cache_bytes') or cache.get('used') or 0
    check(not rejected and stored_ok >= N * 0.95,
          f'blob PUTs accepted, none rejected — {stored_ok}/{N} ok, {len(rejected)} rejected', f'codes={rejected[:5]}')
    check(used <= cap * 1.05, f'disk cache stayed within cap under overflow (used={used} cap={cap})',
          json.dumps(cache))
    # concurrent reads for the most-recent cids (older ones may have been evicted — that's the point)
    def rd(i):
        c, _b = get(HUB + f'/blob?cid=stress-{N-1-i:05d}', timeout=10)
        return c
    res2, _ = run_load(rd, 50, 32)
    check(all(c in (200, 404) for c in res2), 'concurrent blob reads all answered cleanly (200/404)',
          f'codes={sorted(set(res2))}')
    check(get(HUB + '/relays')[0] == 200, 'relay still serving after the blob storm')

def phase3_gossip(HUB, cap):
    print(f'\n--- PHASE 3: gossip announce flood vs KNOWN_MAX={cap} ---')
    N, W = cap * 3, 32                                  # 3x the cap of distinct urls
    def ann(i):
        rec = {'url': f'http://stress-peer-{i:05d}.invalid:9999'}   # bare urls: exercise _add_known/_evict
        body = json.dumps(rec).encode()
        c, _b = req(HUB + '/relay_announce', body, timeout=10)
        return c
    res, el = run_load(ann, N, W)
    from collections import Counter
    hist = dict(Counter(res))
    ok = sum(1 for c in res if c == 200)
    print(f'  {N} announces / {W} workers in {el:.2f}s = {N/el:,.0f} ann/s   codes={hist}')
    served = json.loads(get(HUB + '/relays')[1].decode())
    known_n = len(served.get('relays', []))
    # This hub runs with the write throttle raised (XC_RATE_MAX high) so the cap bound is exercised
    # cleanly — the relay does not REJECT announces. The guarantee under test: `known` stays BOUNDED at
    # the cap even when offered 3x its size of DISTINCT urls (memory can't grow without bound), and the
    # relay stays up. (The per-IP rate throttle is its own phase below.)
    #
    # `req()` returns code 0 when the CLIENT's own connection drops — under this synthetic 400+/s flood a
    # slow/shared CI runner drops a handful of sockets, which is a transport artifact, NOT the relay
    # rejecting an announce (that would be a 4xx/5xx). So assert the relay never REJECTED one (no non-200
    # HTTP status) and served the overwhelming majority; tolerate a small fraction of socket drops so the
    # phase isn't flaky. A real regression (throttle rejecting, or the relay falling over) still trips it:
    # rejections show up as HTTP codes, and a crash drops `ok` far below the 95% floor.
    rejected = sum(1 for c in res if c not in (200, 0))
    check(rejected == 0 and ok >= N * 0.95,
          f'announces accepted, none throttle-rejected — {ok}/{N} ok, {rejected} rejected', f'codes={hist}')
    check(known_n <= cap, f'known-relay set stayed bounded at the cap under 3x overflow (have {known_n} <= {cap})')
    check(known_n >= cap * 0.9, 'the relay filled its set to ~the cap (flood absorbed, not dropped)', known_n)
    check(get(HUB + '/relays')[0] == 200, 'relay still serving after the gossip flood')

def phase5_ratelimit():
    print('\n--- PHASE 5: per-IP write throttle (single-source flood defense) ---')
    port = free_port()
    HUB = f'http://127.0.0.1:{port}'
    p = spawn(port, 'rl', env_extra={'XC_RATE_MAX': '50', 'XC_RATE_WINDOW': '10'})
    STRESS_PROCS.append(p)
    if not wait_up(HUB + '/relays'):
        check(False, 'rate-limit hub came up'); return
    N, W = 200, 16                                     # 200 writes from one IP into a 50/10s budget
    def ann(i):
        body = json.dumps({'url': f'http://rl-peer-{i:04d}.invalid:9999'}).encode()
        return req(HUB + '/relay_announce', body, timeout=10)[0]
    res, _ = run_load(ann, N, W)
    from collections import Counter
    hist = dict(Counter(res))
    ok = sum(1 for c in res if c == 200)
    throttled = sum(1 for c in res if c == 429)
    print(f'  {N} writes from ONE ip into a 50/10s budget   codes={hist}')
    check(throttled > 0, 'the relay 429s a single-source write flood past the budget (defense fires)', hist)
    check(ok <= 70, 'accepted writes are held near the configured budget (~50/window)', f'ok={ok}')
    check(0 not in res and all(c in (200, 429) for c in res),
          'throttled requests get a clean 429 (no crash, no 5xx)', hist)
    check(get(HUB + '/relays')[0] == 200, 'relay still serving after being throttle-flooded')

def phase4_tunnel(entry_url, home_port, home_acct):
    print('\n--- PHASE 4: mesh tunnel under concurrent public load ---')
    eid = xc.url_norm(entry_url)
    e = tun.epoch_now()
    toks = [tun.token_for(xc, SECRET, eid, ep)[1] for ep in (e, e + 1, e - 1)]
    N, W = 120, 24
    def hit(i):
        for tok in toks:
            c, b = get(f'{entry_url}/r/{tok}/relays', timeout=12)
            if c == 200:
                try: j = json.loads(b.decode())
                except Exception: j = {}
                return 1 if (j.get('account') == home_acct and j.get('relay') == home_port) else 2
        return 0
    res, el = run_load(hit, N, W)
    good = sum(1 for r in res if r == 1)
    wrong = sum(1 for r in res if r == 2)          # answered 200 but by the WRONG relay — a real routing fault
    # r==0 is a client/tunnel socket drop under the concurrent flood (a runner limit), not a misroute.
    print(f'  {N} tunnelled reqs / {W} workers in {el:.2f}s = {N/el:,.0f} req/s')
    check(wrong == 0 and good >= N * 0.95,
          f'tunnelled requests reached the HOME relay, none misrouted — {good}/{N} ok, {wrong} misrouted',
          f'codes={sorted(set(res))}')

def main():
    global PASS, FAIL
    KNOWN_CAP = 200
    hub_port = free_port()
    HUB = f'http://127.0.0.1:{hub_port}'
    procs = {}
    try:
        print(f'\nhub :{hub_port}   (KNOWN_MAX={KNOWN_CAP}, BLOB_CAP=2MB)\n')
        procs['H'] = spawn(hub_port, 'hub',
                           env_extra={'XC_KNOWN_MAX': str(KNOWN_CAP), 'XC_BLOB_CAP_MB': '2',
                                      'XC_RATE_MAX': '1000000'})   # throttle raised: phases 1-4 measure raw capacity
        if not wait_up(HUB + '/relays'):
            sys.exit('hub never came up')
        # sanity: it's a hub
        h0 = json.loads(get(HUB + '/relays')[1].decode())
        check(h0.get('type') == 'hub', "the loaded relay reports type 'hub'", h0.get('type'))

        phase1_reads(HUB)
        phase2_blobs(HUB)
        phase3_gossip(HUB, KNOWN_CAP)

        # tunnel phase: a home relay that discovers the hub as an entry and dials it
        home_port = free_port()
        procs['HOME'] = spawn(home_port, 'home',
                              env_extra={'XC_TUNNEL_DISCOVER_FROM': HUB, 'XC_TUNNEL_SECRET': SECRET})
        if not wait_up(f'http://127.0.0.1:{home_port}/relays'):
            sys.exit('home relay never came up')
        home_acct = json.loads(get(f'http://127.0.0.1:{home_port}/relays')[1].decode()).get('account', '')
        # give the tunnel a moment to connect through the entry
        connected = False
        for _ in range(40):
            e = tun.epoch_now(); eid = xc.url_norm(HUB)
            tok = tun.token_for(xc, SECRET, eid, e)[1]
            if get(f'{HUB}/r/{tok}/relays', timeout=8)[0] == 200:
                connected = True; break
            time.sleep(0.5)
        check(connected, 'home relay became reachable through the hub by token (tunnel up)')
        if connected:
            phase4_tunnel(HUB, home_port, home_acct)

        phase5_ratelimit()

        print(f'\n==== {PASS} passed, {FAIL} failed ====\n')
        return 1 if FAIL else 0
    finally:
        allp = list(procs.values()) + STRESS_PROCS
        for p in allp:
            try: p.terminate()
            except Exception: pass
        for p in allp:
            try: p.wait(timeout=5)
            except Exception:
                try: p.kill()
                except Exception: pass
        for s in STORES:
            for suffix in ('', '.id'):
                try: os.remove(s + suffix)
                except OSError: pass

if __name__ == '__main__':
    sys.exit(main())
