#!/usr/bin/env python3
# Broadcast an APP-SIGNED Nano state block: add delegated PoW (no secret) and `process` it. The block
# arrives fully signed from the phone (built + signed on-device with nanodart), so this helper NEVER
# touches a seed — it only computes proof-of-work and relays the block to the ledger. Reads
# /tmp/xc_block_in.json = {"block": {type,account,previous,representative,balance,link,signature}, "subtype": ...}.
import json, os, sys, time, subprocess, fcntl, threading, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = os.environ.get('XC_WORK', 'http://127.0.0.1:7500')      # optional local/dedicated work server
# A GPU solve is ~2s median but the search is exponential, so the tail runs past any short deadline.
# The old 6s cut off perfectly good solves and fell through to public RPCs that are frequently down —
# throwing away the fastest source at exactly the moment it was about to answer.
WORK_TIMEOUT = float(os.environ.get('XC_WORK_TIMEOUT', '30'))
# LAYERED PoW so tips are FAST but NEVER BROKEN. In order: (1) XC_WORK_RPC — a dedicated/paid dPoW you
# point at for INSTANT work (empty by default); (2) free public work RPCs as automatic fallback (measured
# on the node: nanoslo ~0.9s, rainstorm ~5.7s; somenano/rpc.nano.to 403 so they're excluded); (3) on-box
# CPU via nanopy — slow (~1 min on a shared vCPU) but it CANNOT be down, so a tip still settles even if
# every external work service is unreachable. Public read RPCs mostly reject free work_generate, which is
# why PoW uses this dedicated list instead of the shared read cycle.
_DEFAULT_WORK = 'https://rpcproxy.bnano.info/proxy,https://nanoslo.0x.no/proxy,https://rainstorm.city/api'
WORK_RPCS = [u.strip().rstrip('/') for u in
             (os.environ.get('XC_WORK_RPC', '') + ',' + _DEFAULT_WORK).split(',') if u.strip()]
LOCAL_WORK = os.environ.get('XC_WORK_LOCAL', '1') != '0'       # on-box CPU as the never-down last resort
_LOCAL_DIFF = int(os.environ.get('XC_WORK_LOCAL_DIFFICULTY', 'fffffff800000000'), 16)   # mainnet send threshold

# DISCOVERED work sources. The lists above have to be configured by whoever runs the node; this one
# finds work the same way the app finds everything else — by walking the relay gossip. Relays that can
# compute PoW advertise 'work' on /relayacct, and any of them may be raced.
#
# Trust: none required, which is the whole reason this can be open. Work authorises nothing, and every
# answer is validated locally before use, so a hostile relay achieves nothing but wasting its own
# electricity. Contrast with signing, which never leaves the phone.
#
# Privacy: a work request carries the block ROOT (a previous-block hash, or an account public key for a
# first block) — public ledger data, but it does reveal that this account is about to publish. Set
# XC_WORK_DISCOVER=0 on a node where that matters.
WORK_DISCOVER = os.environ.get('XC_WORK_DISCOVER', '1') != '0'
_WORK_PEERS_CACHE = os.environ.get('XC_WORK_PEERS_CACHE', '/tmp/xc_work_peers.json')
_WORK_PEERS_TTL = float(os.environ.get('XC_WORK_PEERS_TTL', '600'))


def _work_relays():
    # Cached, because discovery is a multi-hop gossip walk and a tip fires several blocks back to back.
    #
    # A STALE cache is served immediately and refreshed in the background. Blocking on rediscovery would
    # put a multi-hop walk on the critical path of a tip every time the TTL lapsed — several seconds
    # added to the very operation this code exists to speed up, and paid by whichever unlucky user
    # tipped first. A list a few minutes out of date costs nothing: a relay that has gone away just
    # loses the race, and one that is new is picked up on the next refresh.
    if not WORK_DISCOVER:
        return []
    cached = None
    try:
        c = json.load(open(_WORK_PEERS_CACHE))
        cached = c.get('relays', [])
        if time.time() - c.get('t', 0) < _WORK_PEERS_TTL:
            return cached
    except Exception:
        pass
    if cached is not None:
        threading.Thread(target=_refresh_work_relays, daemon=True).start()
        return cached
    return _refresh_work_relays()          # nothing cached at all: this one call has to wait


def _refresh_work_relays():
    found = []
    try:
        def _probe(r):
            try:
                d = json.loads(urllib.request.urlopen(r.rstrip('/') + '/relayacct', timeout=3).read())
                return r.rstrip('/') if d.get('work') else None
            except Exception:
                return None
        relays = [r for r in xc.discover_relays() if r.startswith('http')]
        if relays:
            with ThreadPoolExecutor(max_workers=min(8, len(relays))) as ex:
                found = [r for r in ex.map(_probe, relays) if r]
    except Exception:
        found = []
    try:
        json.dump({'t': time.time(), 'relays': found}, open(_WORK_PEERS_CACHE, 'w'))
    except Exception:
        pass
    return found


def _work_via_relay(url, root, timeout):
    d = json.loads(urllib.request.urlopen(f'{url}/work?hash={root}', timeout=timeout).read())
    w = d.get('work')
    if not w:
        raise ValueError(str(d.get('error') or 'no work'))
    return w


def _rpc_retry(o, tries=4):
    # Public Nano RPCs rate-limit a BURST: a multi-leg tip settle fires several blocks back-to-back, and
    # the 2nd+ `process`/`work_generate` gets throttled across every endpoint, so xc.rpc() raises. The
    # limit resets within ~1-2s, so back off and retry — this is what made a tip's relay/reposter leg
    # silently fail to broadcast while the (first) creator leg went through. Only transport failures
    # raise here; a genuine ledger error (fork/old block) returns as a dict and is NOT retried.
    last = None
    for i in range(tries):
        try:
            return xc.rpc(o)
        except Exception as e:
            last = e
            time.sleep(0.8 * (i + 1))
    raise last


def _work_ok(work, root):
    # One C-level hash. Cheap enough to run on anything we didn't compute ourselves.
    try:
        return bool(xc._ext.work_validate(int(work, 16), bytes.fromhex(root), _LOCAL_DIFF))
    except Exception:
        return False


def _work_via(url, root, timeout):
    r = urllib.request.urlopen(urllib.request.Request(
        url, json.dumps({'action': 'work_generate', 'hash': root}).encode(),
        {'Content-Type': 'application/json'}), timeout=timeout)
    d = json.loads(r.read())
    if d.get('work') and 'error' not in d:
        return d['work']
    raise ValueError(str(d.get('error') or 'no work'))


def _work_local(root):
    # Zero-dependency last resort: compute PoW on THIS box via nanopy. Slow (~1 min on a shared vCPU at
    # mainnet difficulty) but it can't be down. Send-difficulty work is also valid for receive/open.
    return '%016x' % xc._ext.work_generate(bytes.fromhex(root), _LOCAL_DIFF, os.urandom(128))


# --- work PRECACHE: after a settle we compute the account's NEXT frontier's work in the BACKGROUND, so
# the next block (the common single-leg tip) finds it ready and settles instantly. A cached entry is
# ALWAYS re-verified locally (work_validate — a microsecond C check) before use, so a stale/invalid entry
# (e.g. after a difficulty epoch) can never make us broadcast bad PoW; it's just recomputed. ---
_CACHE = os.environ.get('XC_WORK_CACHE', '/tmp/xc_work_cache.json')


def _cache_load():
    try:
        return json.load(open(_CACHE))
    except Exception:
        return {}


def _cache_valid(root):
    w = _cache_load().get(root)
    if not w:
        return None
    try:
        return w if xc._ext.work_validate(int(w, 16), bytes.fromhex(root), _LOCAL_DIFF) else None
    except Exception:
        return None


def _cache_put(root, work):
    try:
        d = _cache_load(); d[root] = work
        if len(d) > 500:                              # bound: keep the newest 500 (dict preserves order)
            for k in list(d)[:len(d) - 500]:
                d.pop(k, None)
        tmp = _CACHE + '.tmp'; json.dump(d, open(tmp, 'w')); os.replace(tmp, _CACHE)
    except Exception:
        pass


def _compute_work_rpc(root):
    # external work only (I/O-bound, cheap): local work server, then the work RPCs RACED (first valid wins,
    # so one moody endpoint can't stall a leg; XC_WORK_RPC dPoW is in the race and wins when set), then the
    # general RPC cycle. Returns None if every external source failed.
    # EVERY external answer is validated before it is returned. Work arrives here from a local port,
    # a raced pool of public endpoints and a general RPC cycle — none of which we control, and all of
    # which have been observed returning work that does NOT meet the mainnet send threshold: a dev
    # work server answering in milliseconds, and public RPCs generating at the far easier RECEIVE
    # difficulty. Unvalidated, that work goes into a block that the network then rejects, so a tip
    # fails with nothing in the logs anywhere near the real cause. Validation is a single C-level hash,
    # and turns each of those into a clean fall-through to the next source.
    try:
        w = json.loads(urllib.request.urlopen(WORK + '/work?hash=' + root, timeout=WORK_TIMEOUT).read())['work']
        if w and _work_ok(w, root):
            return w
    except Exception:
        pass
    # Race the configured work RPCs together with any DISCOVERED work-capable relays. They go in the
    # same race on purpose: a laptop GPU on a home tunnel and a public dPoW endpoint have wildly
    # different and unpredictable latencies, so rather than ranking them, ask everyone and take the
    # first answer that validates.
    peers = _work_relays()
    if WORK_RPCS or peers:
        pool = len(WORK_RPCS) + len(peers)
        ex = ThreadPoolExecutor(max_workers=min(8, max(1, pool)))
        futs = [ex.submit(_work_via, url, root, 15) for url in WORK_RPCS]
        futs += [ex.submit(_work_via_relay, url, root, 20) for url in peers]
        winner = None
        try:
            for f in as_completed(futs, timeout=16):
                try:
                    cand = f.result()
                except Exception:
                    cand = None
                if cand and _work_ok(cand, root):       # a fast answer at the wrong difficulty is not a win
                    winner = cand
                    break
        except Exception:
            pass
        ex.shutdown(wait=False)                        # abandon the losers; the process exits shortly anyway
        if winner:
            return winner
    try:
        w = _rpc_retry({'action': 'work_generate', 'hash': root}).get('work')
        if w and _work_ok(w, root):
            return w
    except Exception:
        pass
    return None


def work_for(root):
    # (0) a precomputed, locally-VERIFIED cache hit -> instant. Then external RPCs, then on-box CPU (never
    # down). PoW is never money-sensitive: a wrong/absent work just makes `process` reject (no funds move).
    hit = _cache_valid(root)
    if hit:
        return hit
    w = _compute_work_rpc(root)
    if not w and LOCAL_WORK:                           # every external source down -> compute it here (~1 min)
        w = _work_local(root)
    if w:
        _cache_put(root, w)                            # idempotent: a retry of the same block is now instant
    return w


# PRECACHE MODE: `xc_blockproc.py precache <root>` — fetch+cache work for one root, then exit. Spawned
# detached after a settle so the account's NEXT block is instant. A flock SINGLE-FLIGHT lock ensures only
# ONE precache runs at a time — so even the on-box CPU fallback (used when the free RPCs are down) can
# never stack and peg the shared vCPU. flock auto-releases on exit, so a killed precache leaves no stale lock.
if len(sys.argv) > 2 and sys.argv[1] == 'precache':
    _root = sys.argv[2]
    if not _cache_valid(_root):
        _fd = os.open('/tmp/xc_precache.lock', os.O_CREAT | os.O_WRONLY, 0o644)
        try:
            fcntl.flock(_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)   # skip if another precache is already running
            if not _cache_valid(_root):                        # re-check under the lock
                _w = _compute_work_rpc(_root)
                if not _w and LOCAL_WORK:                      # RPCs down -> compute locally so the next tip is still instant
                    _w = _work_local(_root)
                if _w and xc._ext.work_validate(int(_w, 16), bytes.fromhex(_root), _LOCAL_DIFF):
                    _cache_put(_root, _w)
        except BlockingIOError:
            pass                                               # another precache holds the lock; nothing to do
        except Exception:
            pass
        finally:
            try:
                os.close(_fd)
            except Exception:
                pass
    sys.exit(0)


res = {'ok': False, 'error': 'invalid'}
try:
    inp = json.load(open('/tmp/xc_block_in.json'))
    block = inp['block']; subtype = inp.get('subtype', 'send')
    if not xc.verify_block(block):        # reject a forged/malformed block BEFORE spending PoW on it
        raise ValueError('block signature invalid')
    prev = block.get('previous', '0' * 64)
    # work is over the previous hash, or (for an OPEN block, previous == 0) the account's public key
    root = prev if set(prev) != {'0'} else xc.nano_to_pub(block['account'])
    block['work'] = work_for(root)
    # retry the broadcast too: `process` is idempotent for a given signed block (same hash), so a
    # burst-throttled retry can't double-spend — it just lands the block the first attempt couldn't.
    r = _rpc_retry({'action': 'process', 'json_block': 'true', 'subtype': subtype, 'block': block})
    res = {'ok': 'hash' in r, 'hash': r.get('hash'), 'error': r.get('error')}
    # The new frontier IS this block's hash -> precompute its work in the BACKGROUND so the account's next
    # block (the common single-leg tip) is instant. Detached + RPC-only, so it never blocks this response.
    if res.get('ok') and res.get('hash'):
        try:
            subprocess.Popen([sys.executable, os.path.abspath(__file__), 'precache', res['hash']],
                             start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
except Exception as e:
    res = {'ok': False, 'error': str(e)}
json.dump(res, open('/tmp/xc_block_result.json', 'w'))
