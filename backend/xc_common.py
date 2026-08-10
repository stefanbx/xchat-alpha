#!/usr/bin/env python3
# Shared helpers for the ӾChat per-user-thread backend (dev Nano network + IPFS).
import json, subprocess, urllib.request, base64, hashlib, os, time
# Nano RPC endpoint. Defaults to the local dev node; set XC_NANO_RPC to a public mainnet RPC
# (e.g. https://rpc.nano.to) to run relay discovery against the REAL XNO ledger.
R = os.environ.get('XC_NANO_RPC', 'http://127.0.0.1:17076')
GEN = '34F0A37AAD20F4A260F0A5B3CB3D7FB50673212263E58A380BC10474BB039CE4'
GPUB = 'b0311ea55708d6a53c75cdbf88300259c6d018522fe3d4d0a242e431f9e8b6d0'
NANO_ALPH = "13456789abcdefghijkmnopqrstuwxyz"

def rpc(o):
    return json.loads(urllib.request.urlopen(
        urllib.request.Request(R, json.dumps(o).encode(), {'Content-Type': 'application/json'}), timeout=30).read())

def ipfs_add(path):
    cid = subprocess.check_output(['ipfs', 'add', '-Q', '--cid-version=1', '--raw-leaves=false', path],
                                  env={**os.environ, 'IPFS_PATH': '/tmp/ipfsB'}).decode().strip()
    subprocess.check_output(['ipfs', 'add', '-Q', '--cid-version=1', '--raw-leaves=false', path],
                            env={**os.environ, 'IPFS_PATH': os.path.expanduser('~/.ipfs')})
    return cid

def sign(sk, prev, rep, bal, link):
    return dict(l.split(' ', 1) for l in subprocess.check_output(
        ['/tmp/ktblock', sk, prev, rep, bal, link]).decode().splitlines())

def derive(k):
    o = subprocess.check_output(['/tmp/derivekey', k]).decode().splitlines()
    return o[0], o[1]  # addr, pub

def keyof(seedbyte):
    return hashlib.blake2b(bytes([seedbyte] * 32) + bytes(4), digest_size=32).hexdigest()

def acct(seedbyte):
    return derive(keyof(seedbyte))[0]

def cid_hash(cid):  # CIDv1 dag-pb -> 32-byte multihash digest, hex (rides in a block's link)
    s = cid[1:].upper(); s += '=' * ((-len(s)) % 8)
    return base64.b32decode(s)[4:36].hex()

def digest_to_cid(hexdigest):  # inverse of cid_hash: 32-byte link digest -> CIDv1 dag-pb (fixed codec)
    return 'b' + base64.b32encode(bytes([1, 112, 18, 32]) + bytes.fromhex(hexdigest)).decode().lower().rstrip('=')

def nano_to_pub(addr):  # nano_ address -> 32-byte public key hex (a send's link)
    s = addr.split('_', 1)[1][:52]
    bits = ''.join(bin(NANO_ALPH.index(c))[2:].zfill(5) for c in s)[4:]
    return int(bits, 2).to_bytes(32, 'big').hex()

def _b32enc(bits):
    return ''.join(NANO_ALPH[int(bits[i:i + 5], 2)] for i in range(0, len(bits), 5))

def pub_to_addr(pubhex):  # 32-byte pubkey hex -> nano_ address (binds a head's key to its author)
    pub = bytes.fromhex(pubhex)
    pkbits = '0000' + ''.join(bin(b)[2:].zfill(8) for b in pub)          # 4-bit pad + 256 bits
    cs = hashlib.blake2b(pub, digest_size=5).digest()[::-1]              # 5-byte checksum, reversed
    csbits = ''.join(bin(b)[2:].zfill(8) for b in cs)
    return 'nano_' + _b32enc(pkbits) + _b32enc(csbits)

def gsend(dst_pub, amt):  # genesis -> dst_pub, returns the send hash
    gi = rpc({'action': 'account_info', 'account': derive(GEN)[0]}); nb = str(int(gi['balance']) - amt)
    d = sign(GEN, gi['frontier'], GPUB, nb, dst_pub); wk = rpc({'action': 'work_generate', 'hash': gi['frontier']})['work']
    rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
         'block': {'type': 'state', 'account': d['account'], 'previous': gi['frontier'], 'representative': d['rep'],
                   'balance': nb, 'link': dst_pub, 'signature': d['sig'], 'work': wk}})
    return rpc({'action': 'account_history', 'account': derive(GEN)[0], 'count': '1'})['history'][0]['hash']

def ensure_open(seedbyte, amt):  # fund + open an account if it doesn't exist yet
    key = keyof(seedbyte); addr, pub = derive(key)
    if 'error' in rpc({'action': 'account_info', 'account': addr}):
        sh = gsend(pub, amt); wk = rpc({'action': 'work_generate', 'hash': pub})['work']
        d = sign(key, '0' * 64, pub, str(amt), sh)
        rpc({'action': 'process', 'json_block': 'true', 'subtype': 'open',
             'block': {'type': 'state', 'account': d['account'], 'previous': '0' * 64, 'representative': d['rep'],
                       'balance': str(amt), 'link': sh, 'signature': d['sig'], 'work': wk}})
    return addr, pub

def announce(seedbyte, lhash):  # send 1 raw dust on the account's OWN chain; CID rides in link (author-signed)
    key = keyof(seedbyte); addr, pub = derive(key)
    ai = rpc({'action': 'account_info', 'account': addr}); prev = ai['frontier']; nb = str(int(ai['balance']) - 1)
    d = sign(key, prev, pub, nb, lhash); wk = rpc({'action': 'work_generate', 'hash': prev})['work']
    return rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
                'block': {'type': 'state', 'account': d['account'], 'previous': prev, 'representative': d['rep'],
                          'balance': nb, 'link': lhash, 'signature': d['sig'], 'work': wk}})

def read_thread(account):  # account frontier -> link (thread CID) -> IPFS -> parsed thread JSON
    ai = rpc({'action': 'account_info', 'account': account})
    if 'error' in ai:
        return None
    bi = rpc({'action': 'block_info', 'json_block': 'true', 'hash': ai['frontier']})
    link = bi['contents']['link']
    cid = 'b' + base64.b32encode(bytes([1, 112, 18, 32]) + bytes.fromhex(link)).decode().lower().rstrip('=')
    try:
        out = subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': '/tmp/ipfsB'}, timeout=20)
        return json.loads(out)
    except Exception:
        return None

# demo handle <-> seed map (each author owns a Nano account / keypair)
SEEDMAP = {'alice.xno': 0x40, 'bob.xno': 0x41, 'carol.xno': 0x42, 'dev.xno': 0x43,
           'promo.xno': 0x44, 'wire.xno': 0x45, 'you.xno': 0x07}
DIR_SEED = 0x0D  # the directory (follow list) account

# ---- SPOF-free relay discovery ----
# There is no single directory. Each relay is self-sovereign: it owns its own XNO account, commits
# its URL on ITS OWN chain (signed by itself — the account IS the pubkey), and "checks in" by sending
# 1-raw dust to a RENDEZVOUS account. Discovery = scan a rendezvous' receivable/history for the set of
# relay accounts, then read each relay's own chain for its URL. The rendezvous needs NO owner (we only
# read it), its check-ins are immutable, and it's PLURAL — clients union several, so no point can be
# seized or shut to censor discovery. Relays run the same scan to find each other.
RENDEZVOUS_SEEDS = [0x3A, 0x3B, 0x3C]  # several keyless meeting points; union them (redundancy = no SPOF)

def rendezvous_accts():
    return [acct(s) for s in RENDEZVOUS_SEEDS]

def relay_key(url):  # deterministic per-relay identity: the URL maps to a stable XNO keypair
    seed = hashlib.blake2b(url.rstrip('/').encode(), digest_size=32).digest()
    return hashlib.blake2b(seed + bytes(4), digest_size=32).hexdigest()

def _open_key(key, amt):  # fund+open an arbitrary-key account on the dev net if it doesn't exist
    addr, pub = derive(key)
    if 'error' in rpc({'action': 'account_info', 'account': addr}):
        sh = gsend(pub, amt); wk = rpc({'action': 'work_generate', 'hash': pub})['work']
        d = sign(key, '0' * 64, pub, str(amt), sh)
        rpc({'action': 'process', 'json_block': 'true', 'subtype': 'open',
             'block': {'type': 'state', 'account': d['account'], 'previous': '0' * 64, 'representative': d['rep'],
                       'balance': str(amt), 'link': sh, 'signature': d['sig'], 'work': wk}})
    return addr, pub

def _self_send(key, link_hex):  # append a send on the account's own chain with an arbitrary 32-byte link
    addr, pub = derive(key)
    ai = rpc({'action': 'account_info', 'account': addr}); prev = ai['frontier']; nb = str(int(ai['balance']) - 1)
    d = sign(key, prev, pub, nb, link_hex); wk = rpc({'action': 'work_generate', 'hash': prev})['work']
    rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
         'block': {'type': 'state', 'account': d['account'], 'previous': prev, 'representative': d['rep'],
                   'balance': nb, 'link': link_hex, 'signature': d['sig'], 'work': wk}})

def relay_self_announce(url):  # a relay announces ITSELF: commit its URL on its own chain + check in at each RV
    import tempfile
    url = url.rstrip('/'); key = relay_key(url)
    _open_key(key, 10_000_000)
    for rv in rendezvous_accts():                      # dust check-in so any rendezvous can enumerate us
        try:
            _self_send(key, nano_to_pub(rv))
        except Exception:
            pass
    fd, p = tempfile.mkstemp(suffix='.json')            # commit the URL LAST so the frontier link holds the CID
    os.write(fd, json.dumps({'url': url, 'v': 1}, separators=(',', ':'), sort_keys=True).encode()); os.close(fd)
    try:
        cid = ipfs_add(p)
    finally:
        os.unlink(p)
    _self_send(key, cid_hash(cid))
    return derive(key)[0], cid

def _relay_url(account):  # a relay account -> the URL it announced on its own chain (frontier, then history)
    ai = rpc({'action': 'account_info', 'account': account})
    if 'error' in ai:
        return None
    rv_links = {nano_to_pub(rv).upper() for rv in rendezvous_accts()}   # skip check-in blocks (link = a rendezvous)
    hashes = [ai['frontier']]                            # URL is announced LAST, so the frontier usually wins on try 1
    for x in (rpc({'action': 'account_history', 'account': account, 'count': '4'}).get('history', []) or []):
        if x.get('hash'):
            hashes.append(x['hash'])
    for h in dict.fromkeys(hashes):
        try:
            link = rpc({'action': 'block_info', 'json_block': 'true', 'hash': h})['contents']['link']
            if not link or link == '0' * 64 or link.upper() in rv_links:
                continue
            out = subprocess.check_output(['ipfs', 'cat', digest_to_cid(link)],
                                          env={**os.environ, 'IPFS_PATH': '/tmp/ipfsB'}, timeout=5)
            u = json.loads(out).get('url')
            if u:
                return u
        except Exception:
            continue
    return None

def _relay_accounts():  # scan every rendezvous (keyless) for the set of relay accounts that checked in
    accts = set()
    for rv in rendezvous_accts():
        try:
            b = rpc({'action': 'receivable', 'account': rv, 'count': '300',
                     'source': 'true', 'include_only_confirmed': 'false'}).get('blocks') or {}
            if isinstance(b, dict):
                for v in b.values():
                    if isinstance(v, dict) and v.get('source'):
                        accts.add(v['source'])
            for x in rpc({'action': 'account_history', 'account': rv, 'count': '300'}).get('history', []) or []:
                if x.get('type') == 'receive' and x.get('account'):
                    accts.add(x['account'])
        except Exception:
            pass
    return accts
# the engine passes XC_NS (its port) so two engines on one machine hold two different wallets.
# falls back to the legacy shared path when unset (single-engine dev).
_NS = os.environ.get('XC_NS', '')
WALLET_FILE = ('/tmp/xc_wallet_seed_' + _NS + '.txt') if _NS else '/tmp/xc_wallet_seed.txt'

# ---- the user's embedded Nano wallet (seed = the whole identity) ----
def wallet_seed_hex():
    try:
        s = open(WALLET_FILE).read().strip()
        if len(s) >= 64:
            return s[:64]
    except Exception:
        pass
    return '07' * 32                                   # default = demo seed 0x07

def wallet_key():                                       # private key hex from the wallet seed (index 0)
    seed = bytes.fromhex(wallet_seed_hex())
    return hashlib.blake2b(seed + bytes(4), digest_size=32).hexdigest()

def wallet_acct():
    return derive(wallet_key())[0]

def key_for_account(account):                           # private key hex for an account we control, else None
    if account == wallet_acct():
        return wallet_key()
    for sb in SEEDMAP.values():
        if acct(sb) == account:
            return keyof(sb)
    return None

# ---- relay discovery + head TTL ----
# several seed relays: discovery survives any single bootstrap being down (BFS from all)
# relay bootstrap set. Point the engine's helpers at a hosted relay (e.g. a Fly.io node) via
# EITHER /tmp/xchat_bootstrap.txt (one URL per line — used because the engine's posix_spawn does
# NOT pass env to helpers) OR the XCHAT_BOOTSTRAP env var. Falls back to the local relays.
_ONCHAIN_CACHE = '/tmp/xc_onchain_relays.json'
_KNOWN_RELAYS = '/tmp/xc_known_relays.json'  # the list the client keeps: reconnect straight here, re-scan in the background

def onchain_relays(ttl=120):  # SCAN the ledger for self-announced relays (no directory, no SPOF)
    try:                                            # short on-disk cache: one ledger scan per helper wave, not per spawn
        c = json.load(open(_ONCHAIN_CACHE))
        if time.time() - c['ts'] < ttl and c.get('relays'):
            return c['relays']
    except Exception:
        pass
    relays = []
    try:
        relays = sorted({u for a in _relay_accounts() if (u := _relay_url(a))})
    except Exception:
        relays = []
    if relays:
        for f in (_ONCHAIN_CACHE, _KNOWN_RELAYS):
            try:
                json.dump({'ts': time.time(), 'relays': relays}, open(f, 'w'))
            except Exception:
                pass
    return relays

def known_relays():  # the persisted list — used to reconnect directly before any fresh scan
    try:
        return json.load(open(_KNOWN_RELAYS)).get('relays', [])
    except Exception:
        return []

# Bootstrap priority: scan the XNO ledger for self-announced relays (censorship-resistant, no hardcoded
# relay URL, no directory owner) -> the persisted "known relays" list (resilient reconnect if a scan
# momentarily fails) -> an explicit override file / env -> the local dev relays.
def _bootstrap():
    oc = onchain_relays()
    if oc:
        return oc
    known = known_relays()
    if known:
        return known
    try:
        f = [l.strip() for l in open('/tmp/xchat_bootstrap.txt') if l.strip()]
        if f:
            return f
    except Exception:
        pass
    env = [u for u in os.environ.get('XCHAT_BOOTSTRAP', '').split(',') if u]
    return env or ['http://127.0.0.1:7401', 'http://127.0.0.1:7402', 'http://127.0.0.1:7403']
BOOTSTRAP = _bootstrap()
HEAD_TTL = 3600                          # a head is live for this long; must be republished

def acct_seed():                         # account address -> seed byte (for demo authors we can sign)
    return {acct(sb): sb for sb in SEEDMAP.values()}

def discover_relays(bootstrap=None):     # gossip BFS: follow /relays from a bootstrap to the full set
    seed = list(bootstrap or BOOTSTRAP)
    seen = set(seed); found = set()
    queue = list(seed)
    while queue:
        u = queue.pop()
        try:
            d = json.loads(urllib.request.urlopen(u + '/relays', timeout=3).read())
            found.add(u)
            for r in d.get('relays', []):
                if r not in seen:
                    seen.add(r); queue.append(r)
        except Exception:
            pass
    return sorted(found) if found else list(seed)
