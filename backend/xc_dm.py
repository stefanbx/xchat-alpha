#!/usr/bin/env python3
# ӾChat encrypted DIRECT MESSAGES — end-to-end, keyed to the Nano identity.
# Nano signs with ed25519-Blake2b, so instead of reusing that key we derive a SEPARATE
# X25519 keypair from the wallet SEED (blake2b(seed || "xchat-dm")) and publish its PUBLIC
# key in a SIGNED record (bound to the account by the wallet key). Messages are sealed with
# NaCl crypto_box(my_x25519_sk, peer_x25519_pk) — the relays only ever see ciphertext.
# Usage: xc_dm.py send    (reads /tmp/xc_dm_{to,text}.txt)
#        xc_dm.py inbox   (-> decrypted conversations for the wallet account)
import json, os, sys, time, base64, hashlib, subprocess, urllib.request
import importlib.util
from nacl.public import PrivateKey, PublicKey, Box
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'inbox'

def rd(p, d=''):
    return open(p).read().strip() if os.path.exists(p) else d

def dm_sk():                                            # X25519 secret from the wallet seed
    seed = xc.wallet_seed_hex()
    return PrivateKey(hashlib.blake2b(bytes.fromhex(seed) + b'xchat-dm', digest_size=32).digest())

def my_pk_hex(sk):
    return bytes(sk.public_key).hex()

def sign(msg):
    return dict(l.split(' ', 1) for l in xc._sign_lines(xc.wallet_key(), msg))

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

def post(path, obj):
    ok = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            ok += 1
        except Exception:
            pass
    return ok

# publish our own signed DM public-key record so others can encrypt to us (idempotent)
def register(acc, sk):
    ts = int(time.time())
    pkh = my_pk_hex(sk)
    d = sign(f"{acc}|{ts}|{pkh}")
    post('/dmkey', {'account': acc, 'dm_pk': pkh, 'ts': ts, 'sig': d['sig'], 'pub': d['pub']})

# fetch + verify a peer's DM public key (signed by their Nano key)
def peer_dm_pk(account):
    for r in RELAYS:
        try:
            rec = json.loads(urllib.request.urlopen(r + '/dmkey?account=' + account, timeout=4).read()).get('record')
            if not rec:
                continue
            msg = f"{rec['account']}|{rec['ts']}|{rec['dm_pk']}"
            if rec['account'] == account and xc.pub_to_addr(rec['pub']) == account and verify(rec['pub'], msg, rec['sig']):
                return rec['dm_pk']
        except Exception:
            pass
    return None

acc = xc.wallet_acct()
sk = dm_sk()
register(acc, sk)                                      # always keep our key discoverable

if mode == 'send':
    to = rd('/tmp/xc_dm_to.txt')
    text = rd('/tmp/xc_dm_text.txt')
    peer = peer_dm_pk(to)
    if not peer:
        json.dump({'ok': False, 'error': 'recipient has not enabled DMs yet'}, open('/tmp/xc_dm_result.json', 'w'))
        sys.exit(0)
    box = Box(sk, PublicKey(bytes.fromhex(peer)))
    ct = base64.b64encode(box.encrypt(text.encode())).decode()  # nonce + ciphertext
    ts = int(time.time())
    msg = {'to': to, 'from': acc, 'from_pk': my_pk_hex(sk), 'to_pk': peer, 'ct': ct, 'ts': ts}
    relays = post('/dm', msg)
    json.dump({'ok': True, 'relays': relays, 'ts': ts}, open('/tmp/xc_dm_result.json', 'w'))

else:                                                  # inbox: gather + decrypt everything we're a party to
    seen = set(); msgs = []
    for r in RELAYS:
        try:
            for m in json.loads(urllib.request.urlopen(r + '/dm?account=' + acc, timeout=4).read()).get('dms', []):
                k = (m.get('from'), m.get('ts'))
                if k in seen:
                    continue
                seen.add(k)
                msgs.append(m)
        except Exception:
            pass
    convos = {}                                        # peer account -> list of decrypted messages
    for m in msgs:
        outgoing = (m['from'] == acc)
        peer_acc = m['to'] if outgoing else m['from']
        peer_pk = m['to_pk'] if outgoing else m['from_pk']
        try:
            plain = Box(sk, PublicKey(bytes.fromhex(peer_pk))).decrypt(base64.b64decode(m['ct'])).decode()
        except Exception:
            plain = None                               # not for us / tampered
        if plain is None:
            continue
        convos.setdefault(peer_acc, []).append(
            {'from': m['from'], 'outgoing': outgoing, 'text': plain, 'ts': m['ts']})
    for lst in convos.values():
        lst.sort(key=lambda x: x['ts'])
    out = [{'peer': p, 'messages': lst, 'last_ts': lst[-1]['ts']} for p, lst in convos.items()]
    out.sort(key=lambda c: c['last_ts'], reverse=True)
    json.dump({'ok': True, 'account': acc, 'conversations': out}, open('/tmp/xc_dm_result.json', 'w'))
