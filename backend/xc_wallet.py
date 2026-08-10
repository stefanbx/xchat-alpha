#!/usr/bin/env python3
# After the app sets/restores the wallet seed, make sure the account exists and is funded
# (dev network) so tips can settle. No-op if it already has a balance.
import json, os
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

key = xc.wallet_key(); acc, pub = xc.derive(key)
ai = xc.rpc({'action': 'account_info', 'account': acc})
funded = False
if 'error' in ai:                                     # brand-new account → fund + open
    sh = xc.gsend(pub, 10**30)                        # 1 XNO from genesis
    wk = xc.rpc({'action': 'work_generate', 'hash': pub})['work']
    d = xc.sign(key, '0' * 64, pub, str(10**30), sh)
    xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'open',
            'block': {'type': 'state', 'account': d['account'], 'previous': '0' * 64, 'representative': d['rep'],
                      'balance': str(10**30), 'link': sh, 'signature': d['sig'], 'work': wk}})
    funded = True
elif int(ai['balance']) < 10**29:                     # low → top up
    sh = xc.gsend(pub, 10**30)
    ai2 = xc.rpc({'action': 'account_info', 'account': acc}); nb = str(int(ai2['balance']) + 10**30)
    wk = xc.rpc({'action': 'work_generate', 'hash': ai2['frontier']})['work']
    d = xc.sign(key, ai2['frontier'], pub, nb, sh)
    xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'receive',
            'block': {'type': 'state', 'account': d['account'], 'previous': ai2['frontier'], 'representative': d['rep'],
                      'balance': nb, 'link': sh, 'signature': d['sig'], 'work': wk}})
    funded = True
ai = xc.rpc({'action': 'account_info', 'account': acc})
json.dump({"ok": True, "account": acc, "handle": "you.xno",
           "balance": ai.get('balance', '0'), "funded": funded}, open('/tmp/xc_wallet_result.json', 'w'))
