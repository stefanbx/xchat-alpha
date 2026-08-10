#!/usr/bin/env python3
# ӾChat tip SETTLEMENT — the only thing that touches the Nano ledger. Batched tips settle
# in direct sends, PoW delegated. TIP SPLIT: the creator gets (100-split)% and the RELAY that
# served the post's media gets split% (infrastructure gets paid). Split % comes from settings.
import json, os, time, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = 'http://127.0.0.1:7500'

def dwork(root):
    return json.loads(urllib.request.urlopen(WORK + '/work?hash=' + root, timeout=30).read())['work']

def rd(p, d=''):
    try:
        return open(p).read().strip() or d
    except Exception:
        return d

to = rd('/tmp/xc_settle_to.txt')
amount = rd('/tmp/xc_settle_amt.txt', '0.01')
media = rd('/tmp/xc_settle_media.txt')
reposter = rd('/tmp/xc_settle_reposter.txt')                         # the account that boosted this post (optional)
split = max(0, min(50, int(rd('/tmp/xc_settle_split.txt', '10'))))   # relay reward %, capped 0..50
rsplit = max(0, min(50, int(rd('/tmp/xc_settle_rsplit.txt', '5'))))  # reposter reward %, capped 0..50
amt_raw = int(round(float(amount) * 10**30))
VKEY = xc.wallet_key(); VADDR, VPUB = xc.derive(VKEY)

def send(to_pub, raw):
    vi = xc.rpc({'action': 'account_info', 'account': VADDR})
    prev = vi['frontier']; nb = str(int(vi['balance']) - raw)
    d = xc.sign(VKEY, prev, VPUB, nb, to_pub); wk = dwork(prev)
    r = xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
                'block': {'type': 'state', 'account': d['account'], 'previous': prev, 'representative': d['rep'],
                          'balance': nb, 'link': to_pub, 'signature': d['sig'], 'work': wk}})
    return r.get('hash')

res = {"ok": False, "to": to, "amount": amount}
vi = xc.rpc({'action': 'account_info', 'account': VADDR})
if 'error' not in vi and int(vi['balance']) >= amt_raw and amt_raw > 0:
    # find a relay that serves this post's media, to reward it
    relay_acct = None
    if media:
        for r in xc.discover_relays():
            try:
                if json.loads(urllib.request.urlopen(r + '/haveblob?cid=' + media, timeout=3).read()).get('have'):
                    relay_acct = json.loads(urllib.request.urlopen(r + '/relayacct', timeout=3).read()).get('account')
                    break
            except Exception:
                pass
    relay_raw = (amt_raw * split) // 100 if relay_acct else 0
    reposter_raw = (amt_raw * rsplit) // 100 if reposter else 0      # reward whoever boosted it
    creator_raw = amt_raw - relay_raw - reposter_raw
    blocks = 0
    ch = send(xc.nano_to_pub(to), creator_raw); blocks += 1 if ch else 0
    if relay_acct and relay_raw > 0:
        if send(xc.nano_to_pub(relay_acct), relay_raw): blocks += 1
    if reposter and reposter_raw > 0:
        if send(xc.nano_to_pub(reposter), reposter_raw): blocks += 1
    ts = int(time.time())
    # immutable off-chain reward receipt (signed record of the whole split)
    receipt = {"creator": to, "creator_raw": str(creator_raw), "relay": relay_acct, "relay_raw": str(relay_raw),
               "reposter": reposter or None, "reposter_raw": str(reposter_raw), "media": media or None, "ts": ts}
    rd_ = dict(l.split(' ', 1) for l in subprocess.check_output(
        ['/tmp/xc_sign', VKEY, f"{to}|{creator_raw}|{relay_acct}|{relay_raw}|{reposter}|{reposter_raw}|{ts}"]).decode().splitlines())
    receipt['sig'] = rd_['sig']; receipt['pub'] = rd_['pub']
    c = int(rd('/tmp/xc_onchain_count.txt', '0'))
    open('/tmp/xc_onchain_count.txt', 'w').write(str(c + blocks))
    res = {"ok": ch is not None, "to": to, "amount": amount, "hash": ch,
           "creator_xno": creator_raw / 1e30, "relay": relay_acct, "relay_xno": relay_raw / 1e30,
           "reposter": reposter or None, "reposter_xno": reposter_raw / 1e30, "split_pct": split, "repost_pct": rsplit,
           "onchain_blocks_total": c + blocks, "work_delegated": True, "receipt": receipt,
           "note": f"split {100 - split - rsplit}% creator / {rsplit}% reposter / {split}% media-relay"}
json.dump(res, open('/tmp/xc_settle_result.json', 'w'))
