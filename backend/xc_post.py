#!/usr/bin/env python3
# ӾChat write path — OFF-CHAIN, via mutable heads on plural relays. Zero Nano blocks.
#
# ON-DEVICE SIGNING (prepare/submit): the APP signs the post event AND the head. The node never
# holds the seed. Because a head can only be signed over a content CID that doesn't exist until the
# thread is assembled, posting is a two-step round-trip:
#   prepare  — the app sends its already-signed post event; the node verifies it, appends it to the
#              author's thread, pins the thread to IPFS (→ CID), computes the next head seq + expiry,
#              and returns {cid, seq, expires}. Nothing is published yet.
#   submit   — the app signs the head "account|seq|cid|expires" LOCALLY and sends it back; the node
#              verifies the head signature (pub↔account) and gossips the head to every relay. Because
#              the head signature binds the CID, the node cannot alter the content it just assembled
#              without invalidating a signature it cannot produce.
# Usage: xc_post.py prepare | xc_post.py submit
import json, subprocess, os, sys, time, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'legacy'


def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False


def next_seq(acc):
    seq = 0
    for r in RELAYS:
        try:
            for h in json.loads(urllib.request.urlopen(r + '/heads', timeout=4).read()).get('heads', []):
                if h['author'] == acc:
                    seq = max(seq, h.get('seq', 0))
        except Exception:
            pass
    return seq + 1


def push_head(head):
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/push', json.dumps(head).encode(),
                                   {'Content-Type': 'application/json'}), timeout=5).read()
            pushed += 1
        except Exception:
            pass
    return pushed


if mode == 'prepare':
    # The post event is ALREADY SIGNED BY THE APP. Verify it, assemble the thread, pin it, and return
    # the CID + seq for the app to sign the head over. No seed touched.
    rec = json.load(open('/tmp/xc_post_rec.json'))
    handle = rec.get('handle', 'you.xno'); acc = rec.get('account', ''); kind = rec.get('kind', 'post')
    text = rec.get('text', ''); ts = rec.get('ts'); sig = rec.get('sig', ''); pub = rec.get('pub', '')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, f"{handle}|{kind}|{text}|{ts}", sig)):
        json.dump({"ok": False, "error": "bad post signature"}, open('/tmp/xc_post_result.json', 'w')); sys.exit()
    p = {"id": rec.get('id') or ("u" + str(ts)), "handle": handle, "account": acc, "kind": kind,
         "text": text, "ts": ts, "likes": 0, "reposts": 0, "media": rec.get('media') or None,
         "sig": sig, "pub": pub}
    for k in ('title', 'quote', 'reply_to'):
        if rec.get(k):
            p[k] = rec[k]
    if rec.get('poll'):
        p['poll'] = {'options': rec['poll']}          # rec['poll'] is a list of option strings
    THREAD = f'/tmp/xc_thread_{acc}.json'
    thread = json.load(open(THREAD)) if os.path.exists(THREAD) else {"handle": handle, "account": acc, "posts": []}
    thread['posts'].insert(0, p)
    cand = f'/tmp/xc_thread_cand_{acc}.json'           # candidate — committed only on submit
    json.dump(thread, open(cand, 'w'))
    cid = xc.ipfs_add(cand)                            # immutable content CID (public op, no secret)
    seq = next_seq(acc)
    now = int(time.time()); expires = now + xc.HEAD_TTL
    json.dump({"ok": True, "cid": cid, "seq": seq, "expires": expires, "post_id": p['id'],
               "head_msg": f"{acc}|{seq}|{cid}|{expires}"}, open('/tmp/xc_post_result.json', 'w'))

elif mode == 'submit':
    # The head is ALREADY SIGNED BY THE APP (over the CID prepare returned). Verify + gossip. The
    # candidate thread is committed only if its CID still matches the signed head.
    head = json.load(open('/tmp/xc_head_rec.json'))
    acc = head.get('author', ''); seq = head.get('seq'); cid = head.get('cid', '')
    expires = head.get('expires'); sig = head.get('sig', ''); pub = head.get('pub', ''); handle = head.get('handle', 'you.xno')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, f"{acc}|{seq}|{cid}|{expires}", sig)):
        json.dump({"ok": False, "error": "bad head signature"}, open('/tmp/xc_post_result.json', 'w')); sys.exit()
    cand = f'/tmp/xc_thread_cand_{acc}.json'
    if os.path.exists(cand) and xc.ipfs_add(cand) == cid:   # the app signed exactly this content
        os.replace(cand, f'/tmp/xc_thread_{acc}.json')
    head_rec = {"author": acc, "handle": handle, "seq": seq, "cid": cid, "ts": int(time.time()),
                "expires": expires, "sig": sig, "pub": pub}
    pushed = push_head(head_rec)
    json.dump({"ok": True, "seq": seq, "relays_pushed": pushed, "onchain_blocks": 0,
               "note": "app-signed head gossiped to relays — zero Nano blocks"},
              open('/tmp/xc_post_result.json', 'w'))

else:
    json.dump({"ok": False, "error": "unknown mode (use prepare|submit)"}, open('/tmp/xc_post_result.json', 'w'))
