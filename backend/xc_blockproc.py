#!/usr/bin/env python3
# Broadcast an APP-SIGNED Nano state block: add delegated PoW (no secret) and `process` it. The block
# arrives fully signed from the phone (built + signed on-device with nanodart), so this helper NEVER
# touches a seed — it only computes proof-of-work and relays the block to the ledger. Reads
# /tmp/xc_block_in.json = {"block": {type,account,previous,representative,balance,link,signature}, "subtype": ...}.
import json, os, time, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = 'http://127.0.0.1:7500'


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


def work_for(root):
    # delegated PoW: try the work server, fall back to the node's own work_generate (with burst-retry)
    try:
        return json.loads(urllib.request.urlopen(WORK + '/work?hash=' + root, timeout=30).read())['work']
    except Exception:
        return _rpc_retry({'action': 'work_generate', 'hash': root}).get('work')


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
