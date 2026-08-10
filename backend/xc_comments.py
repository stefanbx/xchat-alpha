#!/usr/bin/env python3
# Comments = SIGNED off-chain reply events, keyed by parent post_id and pushed to the relays.
# Like posts, they never touch the ledger; only a TIP on a comment settles on-chain (batched).
# Fetch verifies each signature (pub↔account) before showing it — relays only store.
# Usage: xc_comments.py post   (reads /tmp/xc_comment_{post,text,handle}.txt)
#        xc_comments.py get    (reads /tmp/xc_comment_post.txt -> that post's comments)
import json, os, sys, time, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'
acc = xc.wallet_acct()

def rd(p, d=''):
    try:
        return open(p).read().strip() or d
    except Exception:
        return d

def canon(post_id, account, ts, text, parent=''):
    return f"{post_id}|{account}|{ts}|{text}|{parent}"

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

# a stable id for a comment, so it can gather likes/tips like a post does
def comment_id(post_id, account, ts):
    return f"{post_id}#{account}#{ts}"

if mode == 'post':
    post_id = rd('/tmp/xc_comment_post.txt')
    text = rd('/tmp/xc_comment_text.txt')
    handle = rd('/tmp/xc_comment_handle.txt', 'you.xno')
    parent = rd('/tmp/xc_comment_parent.txt')          # parent comment cid (nested reply), else ''
    ts = int(time.time())
    d = dict(l.split(' ', 1) for l in xc._sign_lines(xc.wallet_key(), canon(post_id, acc, ts, text, parent)))
    rec = {"post_id": post_id, "account": acc, "handle": handle, "text": text, "parent": parent,
           "ts": ts, "sig": d['sig'], "pub": d['pub'], "cid": comment_id(post_id, acc, ts)}
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/comment', json.dumps(rec).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            pushed += 1
        except Exception:
            pass
    json.dump({"ok": True, "relays": pushed, "comment": rec}, open('/tmp/xc_comments_result.json', 'w'))
else:                                                        # get: merge + verify across relays
    post_id = rd('/tmp/xc_comment_post.txt')
    seen = {}                                               # (account, ts) -> verified comment
    for r in RELAYS:
        try:
            lst = json.loads(urllib.request.urlopen(r + '/comments?post=' + post_id, timeout=4).read()).get('comments', [])
            for c in lst:
                key = (c.get('account'), c.get('ts'))
                if key in seen:
                    continue
                msg = canon(c['post_id'], c['account'], c['ts'], c['text'], c.get('parent', ''))
                if xc.pub_to_addr(c['pub']) == c['account'] and verify(c['pub'], msg, c['sig']):
                    c['cid'] = c.get('cid') or comment_id(c['post_id'], c['account'], c['ts'])
                    seen[key] = c
        except Exception:
            pass
    out = sorted(seen.values(), key=lambda c: c['ts'])     # oldest-first thread order
    json.dump({"ok": True, "post": post_id, "comments": out}, open('/tmp/xc_comments_result.json', 'w'))
