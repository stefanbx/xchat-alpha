#!/usr/bin/env python3
# Wallet SEND: move XNO from the user's wallet to any address (DEV NETWORK, valueless tokens).
# PoW delegated. Reads /tmp/xc_send_to.txt + /tmp/xc_send_amt.txt.
import json, os, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = 'http://127.0.0.1:7500'

to = open('/tmp/xc_send_to.txt').read().strip()
amount = open('/tmp/xc_send_amt.txt').read().strip() or "0"
res = {"ok": False, "to": to, "amount": amount, "error": "invalid"}
try:
    amt_raw = int(round(float(amount) * 10**30))
    VKEY = xc.wallet_key(); VADDR, VPUB = xc.derive(VKEY)
    topub = xc.nano_to_pub(to)                                    # validates the address shape
    vi = xc.rpc({'action': 'account_info', 'account': VADDR})
    if 'error' in vi:
        res = {"ok": False, "to": to, "amount": amount, "error": "wallet empty"}
    elif amt_raw <= 0 or int(vi['balance']) < amt_raw:
        res = {"ok": False, "to": to, "amount": amount, "error": "insufficient balance"}
    else:
        prev = vi['frontier']; nb = str(int(vi['balance']) - amt_raw)
        wk = json.loads(urllib.request.urlopen(WORK + '/work?hash=' + prev, timeout=30).read())['work']
        d = xc.sign(VKEY, prev, VPUB, nb, topub)
        r = xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
                    'block': {'type': 'state', 'account': d['account'], 'previous': prev, 'representative': d['rep'],
                              'balance': nb, 'link': topub, 'signature': d['sig'], 'work': wk}})
        res = {"ok": 'hash' in r, "to": to, "amount": amount, "hash": r.get('hash'), "balance": nb}
except Exception as e:
    res = {"ok": False, "to": to, "amount": amount, "error": str(e)}
json.dump(res, open('/tmp/xc_send_result.json', 'w'))
