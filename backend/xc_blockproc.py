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
# Nano has TWO epoch-2 work thresholds and they are not close: send/change needs fffffff8_00000000
# (~2^29 tries) while receive/open needs only fffffe00_00000000 (~2^23) — SIXTY-FOUR times cheaper.
# Asking for the send threshold on every block is valid but wildly wasteful, and on a node whose only
# PoW is public RPC or a shared vCPU it is the difference between a receive landing and timing out.
# Measured on a real stuck open: 67.5s at the send threshold, 11.4s at the correct one.
_SEND_DIFF = int(os.environ.get('XC_WORK_LOCAL_DIFFICULTY', 'fffffff800000000'), 16)
_RECV_DIFF = int(os.environ.get('XC_WORK_RECV_DIFFICULTY', 'fffffe0000000000'), 16)
_LOCAL_DIFF = _SEND_DIFF                       # kept: the default when a caller has no subtype

def diff_for(subtype):
    # Anything that only ADDS funds (receive, open) uses the cheap threshold; everything else pays full.
    return _RECV_DIFF if str(subtype) in ('receive', 'open') else _SEND_DIFF

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
_MESH_WORK_MAX = int(os.environ.get('XC_MESH_WORK_MAX', '40'))   # cap mesh reach bases taken from one hub


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


def _mesh_work_candidates(hubs):
    # Public MESH nodes (e.g. a GPU laptop behind NAT) are reachable ONLY through a hub, by an ephemeral
    # token the hub lists on /mesh_nodes. Being private-by-secret, they never enter the /relays gossip set
    # that discover_relays() walks — so without this they could never join the work race, however fast
    # their GPU, which is exactly the "hub-fronted reach" capacity going unused. Sweep each known hub's
    # /mesh_nodes for the reach bases (<hub>/r/<token>); a non-hub simply 404s and is skipped. Each base is
    # then probed for the 'work' cap like any other relay, and every answer it returns is validated
    # locally (_work_ok), so nothing here has to trust a mesh node.
    out = []
    for hub in hubs:
        base = hub.rstrip('/')
        if '/r/' in base:                              # already a reach url, not a hub — don't sweep it
            continue
        try:
            d = json.loads(urllib.request.urlopen(base + '/mesh_nodes', timeout=4).read())
        except Exception:
            continue                                   # not a hub / unreachable — skip
        for tok in (d.get('nodes') or [])[:_MESH_WORK_MAX]:
            if isinstance(tok, str) and tok:
                out.append('%s/r/%s' % (base, tok))
    return out


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
        # Add hub-fronted mesh nodes: they advertise the work cap too but never appear in /relays (above).
        relays += _mesh_work_candidates(relays)
        relays = list(dict.fromkeys(r.rstrip('/') for r in relays))   # dedupe, keep first-seen order
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


def _work_ok(work, root, difficulty=None):
    # One C-level hash. Cheap enough to run on anything we didn't compute ourselves.
    try:
        return bool(xc._ext.work_validate(int(work, 16), bytes.fromhex(root),
                                          _LOCAL_DIFF if difficulty is None else difficulty))
    except Exception:
        return False


def _work_via(url, root, timeout, difficulty=None):
    # ASK for the threshold we need. A provider given no difficulty computes at ITS default (usually
    # send), so a receive silently costs 64x more than it has to even when the provider is willing.
    req = {'action': 'work_generate', 'hash': root}
    if difficulty is not None:
        req['difficulty'] = '%016x' % difficulty
    r = urllib.request.urlopen(urllib.request.Request(
        url, json.dumps(req).encode(),
        {'Content-Type': 'application/json'}), timeout=timeout)
    d = json.loads(r.read())
    if d.get('work') and 'error' not in d:
        return d['work']
    raise ValueError(str(d.get('error') or 'no work'))


def _work_local(root, difficulty=None):
    # Zero-dependency last resort: compute PoW on THIS box via nanopy. It cannot be down, but on a
    # shared vCPU the send threshold takes ~a minute — which is why using the RECEIVE threshold for a
    # receive matters most here: same box, ~64x less work, and a receive that actually completes.
    return '%016x' % xc._ext.work_generate(bytes.fromhex(root),
                                           _LOCAL_DIFF if difficulty is None else difficulty,
                                           os.urandom(128))


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


def _cache_valid(root, difficulty=None):
    # Validate against the difficulty THIS block needs, not a fixed one. The precache is filled at send
    # difficulty, which is harder, so it stays usable for a receive — but the reverse must never happen:
    # handing cheap receive-grade work to a send would broadcast a block the network drops.
    w = _cache_load().get(root)
    if not w:
        return None
    try:
        need = _LOCAL_DIFF if difficulty is None else difficulty
        return w if xc._ext.work_validate(int(w, 16), bytes.fromhex(root), need) else None
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


def _compute_work_rpc(root, difficulty=None):
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
        # Validate against THIS block's threshold, not the fixed send default. A receive needs only
        # _RECV_DIFF; validating the local server's (valid, receive-grade) answer at the harder send
        # difficulty rejected it, so every receive fell through to the slow RPC race — the "tips slow"
        # symptom. Send-grade work still passes the easier receive check, so this only ever accepts more.
        if w and _work_ok(w, root, difficulty):
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
        futs = [ex.submit(_work_via, url, root, 15, difficulty) for url in WORK_RPCS]
        futs += [ex.submit(_work_via_relay, url, root, 20) for url in peers]
        winner = None
        try:
            for f in as_completed(futs, timeout=16):
                try:
                    cand = f.result()
                except Exception:
                    cand = None
                if cand and _work_ok(cand, root, difficulty):   # a fast answer at the wrong difficulty is not a win
                    winner = cand
                    break
        except Exception:
            pass
        ex.shutdown(wait=False)                        # abandon the losers; the process exits shortly anyway
        if winner:
            return winner
    try:
        req = {'action': 'work_generate', 'hash': root}
        if difficulty is not None:
            req['difficulty'] = '%016x' % difficulty
        w = _rpc_retry(req).get('work')
        if w and _work_ok(w, root, difficulty):
            return w
    except Exception:
        pass
    return None


def work_for(root, difficulty=None):
    # (0) a precomputed, locally-VERIFIED cache hit -> instant. Then external RPCs, then on-box CPU (never
    # down). PoW is never money-sensitive: a wrong/absent work just makes `process` reject (no funds move).
    hit = _cache_valid(root, difficulty)
    if hit:
        return hit
    w = _compute_work_rpc(root, difficulty)
    if not w and LOCAL_WORK:                           # every external source down -> compute it here
        # This is the branch that matters most on a hosted node with no GPU and flaky public RPCs: it is
        # the one that always eventually runs. At the send threshold a shared vCPU needs ~a minute, which
        # is longer than the proxy in front of it will wait — so a receive would be computed and then
        # thrown away by a timeout, forever. At the receive threshold it is ~64x less work.
        w = _work_local(root, difficulty)
    if w:
        # Cache under the difficulty it SATISFIES. Storing receive-grade work unqualified would let a
        # later send pick it up and broadcast a block the network drops; _cache_valid re-checks against
        # what the caller needs, so the only requirement here is that we never claim more than we have.
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
    block['work'] = work_for(root, diff_for(subtype))
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
