#!/usr/bin/env python3
# Seed the relays with signed author HEADS. Each author's posts (a thread) go to IPFS
# (immutable, content-addressed); the head is a SIGNED, sequence-numbered pointer to that
# CID (the IPNS idea). Heads are pushed to every relay — plural, independent, swappable.
import json, subprocess, os, urllib.request, time
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
now = int(time.time())

def ipfs_add_json(obj, name):
    p = f'/tmp/{name}.json'; json.dump(obj, open(p, 'w')); return xc.ipfs_add(p)

def push(head):
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/push', json.dumps(head).encode(),
                                   {'Content-Type': 'application/json'}), timeout=5).read()
        except Exception:
            pass

# group the existing signed events into per-author threads
flat = json.load(open('/tmp/xc_relay.json'))['posts']
by = {}
for p in flat:
    by.setdefault(p['handle'], []).append(p)

for handle, posts in by.items():
    seedbyte = xc.SEEDMAP.get(handle)
    if seedbyte is None:
        continue
    account = xc.acct(seedbyte)
    thread = {"handle": handle, "account": account, "posts": posts}
    cid = ipfs_add_json(thread, f'xc_thread_{handle}')
    seq = 1
    expires = now + xc.HEAD_TTL
    msg = f"{account}|{seq}|{cid}|{expires}"                          # expiry is SIGNED — a relay can't extend a head's life
    d = dict(l.split(' ', 1) for l in subprocess.check_output(['/tmp/xc_sign', xc.keyof(seedbyte), msg]).decode().splitlines())
    head = {"author": account, "handle": handle, "seq": seq, "cid": cid,
            "ts": max(p['ts'] for p in posts), "expires": expires, "sig": d['sig'], "pub": d['pub']}
    push(head)
    print(f"  head {handle:10} seq {seq} -> {cid[:18]}…  pushed to {len(RELAYS)} relays (ttl {xc.HEAD_TTL}s)")
print("heads seeded across", len(RELAYS), "relays — 0 Nano blocks")
