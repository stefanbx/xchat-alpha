#!/usr/bin/env python3
# Broadcast an APP-SIGNED Nano state block: add delegated PoW (no secret) and `process` it. The block
# arrives fully signed from the phone (built + signed on-device with nanodart), so this helper NEVER
# touches a seed — it only computes proof-of-work and relays the block to the ledger. Reads
# /tmp/xc_block_in.json = {"block": {type,account,previous,representative,balance,link,signature}, "subtype": ...}.
import json, os, time, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = os.environ.get('XC_WORK', 'http://127.0.0.1:7500')      # optional local/dedicated work server
# LAYERED PoW so tips are FAST but NEVER BROKEN. In order: (1) XC_WORK_RPC — a dedicated/paid dPoW you
# point at for INSTANT work (empty by default); (2) free public work RPCs as automatic fallback (measured
# on the node: nanoslo ~0.9s, rainstorm ~5.7s; somenano/rpc.nano.to 403 so they're excluded); (3) on-box
# CPU via nanopy — slow (~1 min on a shared vCPU) but it CANNOT be down, so a tip still settles even if
# every external work service is unreachable. Public read RPCs mostly reject free work_generate, which is
# why PoW uses this dedicated list instead of the shared read cycle.
_DEFAULT_WORK = 'https://nanoslo.0x.no/proxy,https://rainstorm.city/api'
WORK_RPCS = [u.strip().rstrip('/') for u in
             (os.environ.get('XC_WORK_RPC', '') + ',' + _DEFAULT_WORK).split(',') if u.strip()]
LOCAL_WORK = os.environ.get('XC_WORK_LOCAL', '1') != '0'       # on-box CPU as the never-down last resort
_LOCAL_DIFF = int(os.environ.get('XC_WORK_LOCAL_DIFFICULTY', 'fffffff800000000'), 16)   # mainnet send threshold


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


def work_for(root):
    # Delegated PoW, in order: (1) a dedicated/local work server if running (e.g. xc_workd); (2) the
    # work-capable RPCs DIRECTLY, fastest-first (dPoW from XC_WORK_RPC first, then the free ones); (3) the
    # general RPC cycle; (4) on-box CPU — slow but never down. PoW is never money-sensitive here: a wrong/
    # absent work just makes `process` reject the block (no funds move), so aggressive fallback is safe.
    try:
        return json.loads(urllib.request.urlopen(WORK + '/work?hash=' + root, timeout=6).read())['work']
    except Exception:
        pass
    # RACE the work RPCs concurrently and take the FIRST valid result, so one moody endpoint (nanoslo
    # swings 0.9-5.5s) can't stall a tip leg — we always get the fastest responder. dPoW (XC_WORK_RPC) is
    # in this list too, so when set it simply wins the race.
    if WORK_RPCS:
        ex = ThreadPoolExecutor(max_workers=min(4, len(WORK_RPCS)))
        futs = [ex.submit(_work_via, url, root, 15) for url in WORK_RPCS]
        winner = None
        try:
            for f in as_completed(futs, timeout=16):
                try:
                    winner = f.result()
                except Exception:
                    winner = None
                if winner:
                    break
        except Exception:
            pass
        ex.shutdown(wait=False)                         # abandon the losers; the process exits shortly anyway
        if winner:
            return winner
    try:
        w = _rpc_retry({'action': 'work_generate', 'hash': root}).get('work')
        if w:
            return w
    except Exception:
        pass
    if LOCAL_WORK:                                 # every external work source is down -> compute it here
        return _work_local(root)
    return None


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
except Exception as e:
    res = {'ok': False, 'error': str(e)}
json.dump(res, open('/tmp/xc_block_result.json', 'w'))
