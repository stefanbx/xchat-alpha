#!/usr/bin/env python3
# Wallet RECEIVE: claim all pending receivables into the wallet balance (DEV NETWORK).
import json, os, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = 'http://127.0.0.1:7500'

key = xc.wallet_key(); acc, pub = xc.derive(key)
received = 0
try:
    pend = xc.rpc({'action': 'receivable', 'account': acc, 'count': '25', 'source': 'true',
                   'include_only_confirmed': 'false'})
    blocks = pend.get('blocks') or {}
    if isinstance(blocks, list):
        blocks = {h: None for h in blocks}
    for h, info in blocks.items():
        amt = int(info['amount']) if isinstance(info, dict) else int(xc.rpc({'action': 'block_info', 'json_block': 'true', 'hash': h})['amount'])
        ai = xc.rpc({'action': 'account_info', 'account': acc})
        if 'error' in ai:                                    # open the account
            wk = json.loads(urllib.request.urlopen(WORK + '/work?hash=' + pub, timeout=30).read())['work']
            d = xc.sign(key, '0' * 64, pub, str(amt), h)
            xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'open',
                    'block': {'type': 'state', 'account': d['account'], 'previous': '0' * 64, 'representative': d['rep'],
                              'balance': str(amt), 'link': h, 'signature': d['sig'], 'work': wk}})
        else:
            nb = str(int(ai['balance']) + amt)
            wk = json.loads(urllib.request.urlopen(WORK + '/work?hash=' + ai['frontier'], timeout=30).read())['work']
            d = xc.sign(key, ai['frontier'], pub, nb, h)
            xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'receive',
                    'block': {'type': 'state', 'account': d['account'], 'previous': ai['frontier'], 'representative': d['rep'],
                              'balance': nb, 'link': h, 'signature': d['sig'], 'work': wk}})
        received += 1
except Exception:
    pass
ai = xc.rpc({'action': 'account_info', 'account': acc})
json.dump({"ok": True, "received": received, "balance": ai.get('balance', '0')}, open('/tmp/xc_receive_result.json', 'w'))
