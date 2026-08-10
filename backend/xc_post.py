#!/usr/bin/env python3
# ӾChat write path — OFF-CHAIN, via mutable heads on plural relays. Append the signed
# post to the viewer's thread, publish the thread to IPFS (new CID), bump the viewer's
# head seq, sign it, and gossip the new head to every relay. Zero Nano blocks.
import json, subprocess, os, time, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
ACC = xc.wallet_acct(); HANDLE = 'you.xno'; THREAD = f'/tmp/xc_thread_{ACC}.json'

def sign_msg(msg):
    return dict(l.split(' ', 1) for l in xc._sign_lines(xc.wallet_key(), msg))

def rd(p, d=''):
    return open(p).read().strip() if os.path.exists(p) else d

text = rd('/tmp/xc_post_in.txt')
media = rd('/tmp/xc_post_media.txt')
quote = rd('/tmp/xc_post_quote.txt')       # quoted post id (quote-post), rendered inline by the client
reply_to = rd('/tmp/xc_post_reply.txt')    # parent post id (author thread chain)
title = rd('/tmp/xc_post_title.txt')       # long-form article title (a titled post renders as an article)
poll = rd('/tmp/xc_post_poll.txt')         # poll options joined by "|" (a poll post; text = the question)
mediakind = rd('/tmp/xc_post_mediakind.txt')  # 'photo' (image/GIF) or 'movie' (video) when media is set
poll_opts = [o.strip() for o in poll.split('|') if o.strip()] if poll else []
now = int(time.time())
media_kind = mediakind if mediakind in ('photo', 'movie') else 'movie'  # default legacy behaviour
kind = "poll" if poll_opts else ("article" if title else (media_kind if media else "post"))
p = {"id": "u" + str(now), "handle": HANDLE, "account": ACC, "kind": kind,
     "text": text, "ts": now, "likes": 0, "reposts": 0, "media": media or None}
if title:
    p['title'] = title
if poll_opts:
    p['poll'] = {'options': poll_opts}     # votes are signed off-chain events tallied by the client
if quote:
    p['quote'] = quote
if reply_to:
    p['reply_to'] = reply_to
d = sign_msg(f"{p['handle']}|{p['kind']}|{p['text']}|{p['ts']}")     # sign the post event
p['sig'] = d['sig']; p['pub'] = d['pub']
# these ride inside the thread content, whose CID is bound by the signed head — tamper-evident

thread = json.load(open(THREAD)) if os.path.exists(THREAD) else {"handle": HANDLE, "account": ACC, "posts": []}
thread['posts'].insert(0, p)
json.dump(thread, open(THREAD, 'w'))
cid = xc.ipfs_add(THREAD)                                            # new immutable content CID

# find the viewer's current head seq from any relay, then bump it
seq = 0
for r in RELAYS:
    try:
        for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=4).read()).get('heads', []):
            if h['author'] == ACC:
                seq = max(seq, h.get('seq', 0))
    except Exception:
        pass
seq += 1
expires = now + xc.HEAD_TTL
hd = sign_msg(f"{ACC}|{seq}|{cid}|{expires}")                        # sign the new mutable head (expiry included)
head = {"author": ACC, "handle": HANDLE, "seq": seq, "cid": cid, "ts": now, "expires": expires, "sig": hd['sig'], "pub": hd['pub']}
pushed = 0
for r in RELAYS:
    try:
        urllib.request.urlopen(urllib.request.Request(r + '/push', json.dumps(head).encode(),
                               {'Content-Type': 'application/json'}), timeout=5).read()
        pushed += 1
    except Exception:
        pass
json.dump({"ok": True, "post": p, "onchain_blocks": 0, "head_seq": seq, "relays_pushed": pushed,
           "note": "signed head gossiped to relays — zero Nano blocks"}, open('/tmp/xc_post_result.json', 'w'))
