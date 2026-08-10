#!/usr/bin/env python3
# ӾChat POLLS — one signed vote per account, tallied off-chain (like likes/comments). The poll
# itself rides in the post (kind=poll, poll.options), head-signed. A vote is a signed event
# {poll_id, account, option, ts, sig, pub}; the client verifies sig + key↔account and tallies.
# Usage: xc_poll.py vote   (reads /tmp/xc_poll_{id,option}.txt)
#        xc_poll.py get    (reads /tmp/xc_poll_id.txt -> per-option counts + my vote)
import json, os, sys, time, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'
acc = xc.wallet_acct()

def rd(p, d=''):
    return open(p).read().strip() if os.path.exists(p) else d

def canon(poll_id, account, option, ts):
    return f"{poll_id}|{account}|{option}|{ts}"

def verify(pub, msg, sig):
    try:
        return subprocess.check_output(['/tmp/xc_verify', pub, msg, sig]).decode().strip() == 'ok'
    except Exception:
        return False

if mode == 'vote':
    pid = rd('/tmp/xc_poll_id.txt')
    option = rd('/tmp/xc_poll_option.txt', '0')
    ts = int(time.time())
    d = dict(l.split(' ', 1) for l in subprocess.check_output(
        ['/tmp/xc_sign', xc.wallet_key(), canon(pid, acc, option, ts)]).decode().splitlines())
    rec = {'poll_id': pid, 'account': acc, 'option': int(option), 'ts': ts, 'sig': d['sig'], 'pub': d['pub']}
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/pollvote', json.dumps(rec).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            pushed += 1
        except Exception:
            pass
    json.dump({'ok': True, 'relays': pushed, 'option': int(option)}, open('/tmp/xc_poll_result.json', 'w'))
else:                                                  # get: merge + verify votes, tally per option
    pid = rd('/tmp/xc_poll_id.txt')
    latest = {}                                        # account -> (ts, option), keeping the newest valid vote
    for r in RELAYS:
        try:
            for v in json.loads(urllib.request.urlopen(r + '/pollvotes?poll=' + pid, timeout=4).read()).get('votes', []):
                a = v.get('account')
                msg = canon(v['poll_id'], a, v['option'], v['ts'])
                if xc.pub_to_addr(v['pub']) == a and verify(v['pub'], msg, v['sig']):
                    if a not in latest or v['ts'] > latest[a][0]:
                        latest[a] = (v['ts'], int(v['option']))
        except Exception:
            pass
    counts = {}
    for _, opt in latest.values():
        counts[opt] = counts.get(opt, 0) + 1
    my = latest.get(acc, (0, None))[1]
    json.dump({'ok': True, 'poll': pid, 'counts': counts, 'total': len(latest), 'my_option': my},
              open('/tmp/xc_poll_result.json', 'w'))
