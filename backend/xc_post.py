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
import json, subprocess, os, sys, time, base64, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'legacy'


def get_content(cid):                  # content by CID: IPFS origin, else a relay CACHE (survives origin loss)
    try:
        return subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': xc.IPFS_PATH}, timeout=8)
    except Exception:
        pass
    for r in RELAYS:
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=4).read())
            if d.get('b64'):
                return base64.b64decode(d['b64'])
        except Exception:
            pass
    return None


def current_thread(acc, handle):
    # Resolve the author's LIVE thread from the highest valid head across relays and fetch its content by
    # CID (IPFS → relay /blob). The node's local /tmp thread is wiped on redeploy, so it can't be the source
    # of truth — the signed head + IPFS is. Falls back to the local candidate, then an empty thread.
    # Returns (thread, got_content, reached): got_content distinguishes "content genuinely lost" from a
    # transient fetch miss; reached distinguishes "relays down" so callers don't wipe a thread they can't see.
    best = None; reached = False
    for r in RELAYS:
        try:
            hs = json.loads(urllib.request.urlopen(r + '/heads', timeout=4).read()).get('heads', [])
            reached = True
            for h in hs:
                if h.get('author') == acc and (best is None or h.get('seq', 0) > best.get('seq', 0)):
                    best = h
        except Exception:
            pass
    if best:
        data = get_content(best['cid'])
        if data:
            try:
                t = json.loads(data)
                if isinstance(t.get('posts'), list):
                    return t, True, reached
            except Exception:
                pass
    LOCAL = f'/tmp/xc_thread_{acc}.json'
    if os.path.exists(LOCAL):
        try:
            return json.load(open(LOCAL)), True, reached
        except Exception:
            pass
    return {"handle": handle, "account": acc, "posts": []}, False, reached


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
    thread, _got, _reached = current_thread(acc, handle)  # LIVE thread from the signed head + IPFS, not the wiped /tmp
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

elif mode == 'delete':
    # The app signed "delete|account|post_id|ts" — verify it, rebuild the author's thread WITHOUT that
    # post, pin the new thread, and return the CID + seq for the app to sign the new head. Like posting,
    # nothing is committed until submit (with the head signature), and the node never touches a seed.
    rec = json.load(open('/tmp/xc_delete_rec.json'))
    acc = rec.get('account', ''); pid = rec.get('post_id', ''); ts = rec.get('ts')
    sig = rec.get('sig', ''); pub = rec.get('pub', ''); handle = rec.get('handle', 'you.xno')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, f"delete|{acc}|{pid}|{ts}", sig)):
        json.dump({"ok": False, "error": "bad delete signature"}, open('/tmp/xc_post_result.json', 'w')); sys.exit()
    thread, got_content, reached = current_thread(acc, handle)  # LIVE thread from the signed head + IPFS
    if not reached:                                    # relays unreachable — refuse, don't wipe a thread we can't see
        json.dump({"ok": False, "error": "relays unreachable — cannot rebuild thread"}, open('/tmp/xc_post_result.json', 'w')); sys.exit()
    before = len(thread.get('posts', []))
    thread['posts'] = [p for p in thread.get('posts', []) if p.get('id') != pid]   # drop the post
    if len(thread['posts']) == before and got_content and before > 0:
        # The thread is intact and the post genuinely isn't in it → real "not found". But if the content was
        # LOST (got_content False), delete is idempotent: republish the (empty/filtered) thread to supersede
        # the dead head so the orphaned post finally leaves every feed.
        json.dump({"ok": False, "error": "post not found in thread"}, open('/tmp/xc_post_result.json', 'w')); sys.exit()
    cand = f'/tmp/xc_thread_cand_{acc}.json'
    json.dump(thread, open(cand, 'w'))
    cid = xc.ipfs_add(cand)
    seq = next_seq(acc)
    now = int(time.time()); expires = now + xc.HEAD_TTL
    json.dump({"ok": True, "cid": cid, "seq": seq, "expires": expires, "post_id": pid,
               "head_msg": f"{acc}|{seq}|{cid}|{expires}"}, open('/tmp/xc_post_result.json', 'w'))

else:
    json.dump({"ok": False, "error": "unknown mode (use prepare|submit|delete)"}, open('/tmp/xc_post_result.json', 'w'))
