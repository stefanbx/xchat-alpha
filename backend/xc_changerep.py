#!/usr/bin/env python3
# Wallet: read / CHANGE the account's Nano REPRESENTATIVE (DEV NETWORK). A representative change is
# a state block with the SAME balance and previous frontier but a new `representative` — subtype
# `change`, link = 0, NO value moves. PoW delegated. Reads /tmp/xc_rep_to.txt (set mode).
# Usage: xc_changerep.py get | xc_changerep.py set
import json, os, sys, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
WORK = 'http://127.0.0.1:7500'
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'

VKEY = xc.wallet_key(); VADDR, VPUB = xc.derive(VKEY)

if mode == 'get':
    vi = xc.rpc({'action': 'account_info', 'account': VADDR, 'representative': 'true'})
    rep = vi.get('representative') if 'error' not in vi else None
    json.dump({'ok': True, 'account': VADDR, 'representative': rep,
               'self': rep == VADDR}, open('/tmp/xc_rep_result.json', 'w'))
else:
    to = open('/tmp/xc_rep_to.txt').read().strip()
    res = {'ok': False, 'representative': to, 'error': 'invalid'}
    try:
        newrep_pub = xc.nano_to_pub(to)                          # validates the nano_ address shape
        vi = xc.rpc({'action': 'account_info', 'account': VADDR})
        if 'error' in vi:
            res = {'ok': False, 'error': 'account not opened yet — receive some XNO first'}
        else:
            prev = vi['frontier']; bal = vi['balance']           # balance UNCHANGED — a change moves no value
            wk = json.loads(urllib.request.urlopen(WORK + '/work?hash=' + prev, timeout=30).read())['work']
            d = xc.sign(VKEY, prev, newrep_pub, bal, '0' * 64)   # rep = new rep, link = 0
            r = xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'change',
                        'block': {'type': 'state', 'account': d['account'], 'previous': prev,
                                  'representative': d['rep'], 'balance': bal, 'link': '0' * 64,
                                  'signature': d['sig'], 'work': wk}})
            res = {'ok': 'hash' in r, 'representative': d['rep'], 'hash': r.get('hash'),
                   'error': r.get('error')}
    except Exception as e:
        res = {'ok': False, 'representative': to, 'error': str(e)}
    json.dump(res, open('/tmp/xc_rep_result.json', 'w'))
