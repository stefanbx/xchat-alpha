#!/usr/bin/env python3
# Engagement across relays: likes + tip totals per post. Likes/tips are pushed to every
# relay; reads aggregate (max per post, since relays converge). Usage:
#   xc_engage.py like <post_id> <delta> | tip <post_id> <raw> | get
import json, os, sys, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'

def post(path, obj):
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
        except Exception:
            pass

def rd(p):
    try:
        return open(p).read().strip()
    except Exception:
        return ''

if mode == 'notify':                                          # push a like/comment/tip notification to the author
    import time
    payload = {'to': rd('/tmp/xc_np_to.txt'), 'from': rd('/tmp/xc_np_from.txt'),
               'kind': rd('/tmp/xc_np_kind.txt'), 'text': rd('/tmp/xc_np_text.txt'), 'ts': int(time.time())}
    post('/notify_push', payload)
    json.dump({"ok": True}, open('/tmp/xc_engage_result.json', 'w'))
elif mode == 'like':
    post('/like', {'post_id': sys.argv[2], 'delta': int(sys.argv[3])})
    json.dump({"ok": True}, open('/tmp/xc_engage_result.json', 'w'))
elif mode == 'repost':
    acct = ''
    try:
        acct = open('/tmp/xc_reshare_acct.txt').read().strip()
    except Exception:
        pass
    post('/repost', {'post_id': sys.argv[2], 'delta': int(sys.argv[3]), 'account': acct})
    json.dump({"ok": True}, open('/tmp/xc_engage_result.json', 'w'))
elif mode == 'tip':
    post('/tipstat', {'post_id': sys.argv[2], 'raw': int(sys.argv[3])})
    json.dump({"ok": True}, open('/tmp/xc_engage_result.json', 'w'))
elif mode == 'view':
    post('/view', {'post_id': sys.argv[2], 'delta': int(sys.argv[3])})
    json.dump({"ok": True}, open('/tmp/xc_engage_result.json', 'w'))
else:
    agg = {}
    for r in RELAYS:
        try:
            e = json.loads(urllib.request.urlopen(r + '/engagement', timeout=4).read()).get('engage', {})
            for pid, v in e.items():
                a = agg.setdefault(pid, {'likes': 0, 'tips_raw': 0, 'reposts': 0, 'views': 0, 'resharers': []})
                a['likes'] = max(a['likes'], v.get('likes', 0))
                a['tips_raw'] = max(a['tips_raw'], v.get('tips_raw', 0))
                a['reposts'] = max(a['reposts'], v.get('reposts', 0))
                a['views'] = max(a['views'], v.get('views', 0))
                for who in (v.get('resharers') or []):        # union, earliest-first preserved
                    if who not in a['resharers']:
                        a['resharers'].append(who)
        except Exception:
            pass
    for pid, a in agg.items():
        a['tips_xno'] = a['tips_raw'] / 1e30   # float (raw would overflow the client's 64-bit int)
    json.dump({"ok": True, "engage": agg}, open('/tmp/xc_engage_result.json', 'w'))
