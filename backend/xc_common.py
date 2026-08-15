#!/usr/bin/env python3
# Shared helpers for the ӾChat per-user-thread backend (dev Nano network + IPFS).
import json, subprocess, urllib.request, urllib.parse, urllib.error, base64, hashlib, os, time, ipaddress, socket
import http.client
from concurrent.futures import ThreadPoolExecutor
# Nano RPC endpoint(s). XC_NANO_RPC may be ONE url or a comma-separated list; defaults to the local
# dev node. When a PUBLIC mainnet RPC is configured, known-good public fallbacks are appended —
# because any single datacenter-hosted RPC (rpc.nano.to did, from Fly) can throttle or block a
# hosting provider's egress IP, and one point of failure for ledger reads makes EVERY balance
# silently read 0 (the handler can't tell "unreachable" from "unopened"). rpc() tries endpoints in
# turn, remembers the last that worked, and RAISES if none answer so callers report the truth.
_RPC_ENV = os.environ.get('XC_NANO_RPC', 'http://127.0.0.1:17076')
RPCS = [u.strip().rstrip('/') for u in _RPC_ENV.split(',') if u.strip()] or ['http://127.0.0.1:17076']
R = RPCS[0]                                                  # back-compat: some logs read R
_PUBLIC_FALLBACKS = ['https://rpc.nano.to', 'https://nanoslo.0x.no/proxy',
                     'https://rainstorm.city/api', 'https://node.somenano.com/proxy']
GEN = '34F0A37AAD20F4A260F0A5B3CB3D7FB50673212263E58A380BC10474BB039CE4'
GPUB = 'b0311ea55708d6a53c75cdbf88300259c6d018522fe3d4d0a242e431f9e8b6d0'
NANO_ALPH = "13456789abcdefghijkmnopqrstuwxyz"

def _rpc_endpoints():
    eps = list(RPCS)
    # only fall back to public nodes when the operator already chose a public (non-loopback) RPC —
    # a dev/local setup (and the e2e test's dead port) must stay isolated, never reach mainnet.
    if any(('127.0.0.1' not in u and 'localhost' not in u) for u in eps):
        for f in _PUBLIC_FALLBACKS:
            if f not in eps:
                eps.append(f)
    return eps

# genuine ledger answers that must be RETURNED as-is, not retried as if the endpoint were broken.
_NANO_ERRS = ('account not found', 'block not found', 'bad account', 'old block',
              'fork', 'gap', 'unreceivable', 'insufficient balance')
_rpc_good = [0]                                             # index of the last endpoint that answered

def _transport_err(r):
    # a rate-limit / forbidden / proxy error dict means "try the next endpoint"; a real Nano error
    # (e.g. account not found) is a valid answer and must pass through.
    if not isinstance(r, dict):
        return True
    e = str(r.get('error', '')).lower()
    if not e:
        return False
    return not any(k in e for k in _NANO_ERRS)

_session = [None]
def _post_json(url, obj, timeout=20):
    # Keep-alive HTTP: a fresh TCP+TLS handshake per RPC cost ~0.35s to a public node (measured: fresh
    # 0.5s/call vs pooled 0.15s/call). A shared requests.Session pools connections per host — in the
    # long-lived kt_server process it reuses them ACROSS requests (money-path account_state/receivables
    # can't be cached, so this is their main win); within a spawned helper it reuses across the parallel
    # RPC batch. Falls back to urllib if requests is somehow absent.
    hdr = {'Content-Type': 'application/json', 'User-Agent': 'xchat-node/0.1'}
    data = json.dumps(obj).encode()
    try:
        if _session[0] is None:
            import requests
            from requests.adapters import HTTPAdapter
            s = requests.Session()
            ad = HTTPAdapter(pool_connections=8, pool_maxsize=32, max_retries=0)
            s.mount('http://', ad); s.mount('https://', ad)
            _session[0] = s
        return _session[0].post(url, data=data, headers=hdr, timeout=timeout).json()
    except ImportError:
        return json.loads(urllib.request.urlopen(
            urllib.request.Request(url, data, hdr), timeout=timeout).read())

def rpc(o):
    # public mainnet RPCs (e.g. rpc.nano.to) reject the default python User-Agent with 403 — send one.
    eps = _rpc_endpoints()
    g = _rpc_good[0] if _rpc_good[0] < len(eps) else 0
    order = [g] + [i for i in range(len(eps)) if i != g]
    last = None
    for i in order:
        try:
            r = _post_json(eps[i], o, timeout=20)     # pooled/keep-alive connection
        except Exception as e:
            last = e
            continue
        if _transport_err(r):
            last = RuntimeError(f'{eps[i]} unusable: {str(r)[:100]}')
            continue
        _rpc_good[0] = i
        return r
    raise last if last is not None else RuntimeError('no Nano RPC endpoint reachable')

_rpc_cache = {}
_RPC_CACHE_MAX = 5000
def rpc_cached(o, ttl=8.0):
    # A short-TTL cache for SLOW-CHANGING, DISPLAY-only ledger reads (the balance shown in the UI, the
    # chain height). Each public-RPC round-trip costs ~0.66s, and these values are fine a few seconds
    # stale. NEVER use this for block-building reads: a stale frontier/balance would build a block the
    # ledger rejects — those must call rpc() directly. Keyed by the exact request; errors aren't cached
    # (so a freshly-opened/funded account appears without waiting out the TTL).
    key = json.dumps(o, sort_keys=True)
    now = time.time()
    c = _rpc_cache.get(key)
    if c and now - c[1] < ttl:
        return c[0]
    r = rpc(o)
    if not (isinstance(r, dict) and 'error' in r):
        if len(_rpc_cache) >= _RPC_CACHE_MAX:
            _rpc_cache.pop(next(iter(_rpc_cache)), None)
        _rpc_cache[key] = (r, now)
    return r

IPFS_PATH = os.environ.get('IPFS_PATH', '/tmp/ipfsB')

def ipfs_add(path):
    cid = subprocess.check_output(['ipfs', 'add', '-Q', '--cid-version=1', '--raw-leaves=false', path],
                                  env={**os.environ, 'IPFS_PATH': IPFS_PATH}).decode().strip()
    try:                                                   # best-effort mirror to a second repo (dev only)
        subprocess.check_output(['ipfs', 'add', '-Q', '--cid-version=1', '--raw-leaves=false', path],
                                env={**os.environ, 'IPFS_PATH': os.path.expanduser('~/.ipfs')})
    except Exception:
        pass
    return cid

def content_matches_cid(cid, data):
    # Content-addressing is only an INTEGRITY guarantee if the bytes are re-hashed against the CID. When
    # the node falls back to an untrusted relay's /blob cache (the local IPFS origin didn't have it), a
    # rogue relay can return arbitrary bytes for a legitimate CID — feed/profile/comment/media forgery —
    # unless we verify here. The local `ipfs cat` path self-verifies; this guards the RELAY path.
    #   sha256-<hex>  : recompute sha256 (exact, cheap).
    #   IPFS CID      : recompute with the SAME deterministic add options ipfs_add uses, --only-hash so
    #                   nothing is pinned and no daemon is needed. Identical bytes => identical CID.
    # Unverifiable (ipfs missing, tool error) returns False: treat as missing rather than render forged
    # content (per the content-addressing security model).
    if not data or not cid:
        return False
    try:
        if cid.startswith('sha256-'):
            return hashlib.sha256(data).hexdigest() == cid.split('sha256-', 1)[1]
        import tempfile
        tf = tempfile.NamedTemporaryFile(prefix='xc_cidchk_', delete=False)
        try:
            tf.write(data); tf.close()
            got = subprocess.check_output(
                ['ipfs', 'add', '-Q', '--only-hash', '--cid-version=1', '--raw-leaves=false', tf.name],
                env={**os.environ, 'IPFS_PATH': IPFS_PATH}, timeout=20).decode().strip()
        finally:
            try:
                os.remove(tf.name)
            except Exception:
                pass
        return got == cid
    except Exception:
        return False

# ---- Nano crypto (pure Python via nanopy; ed25519-blake2b). Replaces the former native
# helpers /tmp/{derivekey,ktblock,xc_sign,xc_verify} so the node runs on any OS, no build step.
import nanopy as _np
from nanopy import ext as _ext
import os as _os

def _addr(pubhex):
    return _np.Account(pk=pubhex).addr                         # 32-byte pubkey hex -> nano_ address

def _block_hash(account_pub, prev, rep_pub, bal, link):        # Nano state-block hash (blake2b)
    h = hashlib.blake2b(digest_size=32)
    h.update(bytes(31) + bytes([6]))                           # state-block preamble
    h.update(bytes.fromhex(account_pub)); h.update(bytes.fromhex(prev))
    h.update(bytes.fromhex(rep_pub)); h.update(int(bal).to_bytes(16, 'big')); h.update(bytes.fromhex(link))
    return h.digest()

def sign(sk, prev, rep, bal, link):                            # state-block sign (was /tmp/ktblock)
    skb = bytes.fromhex(sk); pub = _ext.publickey(skb).hex()
    bh = _block_hash(pub, prev, rep, bal, link)
    return {'account': _addr(pub), 'rep': _addr(rep),
            'sig': _ext.sign(skb, bh, _os.urandom(32)).hex(), 'hash': bh.hex(), 'pub': pub}

def derive(k):                                                 # private key hex -> (nano_ addr, pub hex)
    pub = _ext.publickey(bytes.fromhex(k)).hex()
    return _addr(pub), pub

def _msg_bytes(msg):
    return msg.encode() if isinstance(msg, str) else msg

def _sign_lines(key, msg):                                     # was /tmp/xc_sign: ed25519-blake2b over the message
    skb = bytes.fromhex(key)
    return ['sig ' + _ext.sign(skb, _msg_bytes(msg), _os.urandom(32)).hex(),
            'pub ' + _ext.publickey(skb).hex()]

def _verify_ok(pub, msg, sig):                                 # was /tmp/xc_verify
    try:
        return 'ok' if _ext.verify_signature(bytes.fromhex(sig), bytes.fromhex(pub), _msg_bytes(msg)) == 1 else 'bad'
    except Exception:
        return 'bad'

def verify_msg(pub, msg, sig):
    return _verify_ok(pub, msg, sig) == 'ok'

def sig_canon(msg_type, *fields):
    # Unambiguous signing preimage (issue #2). Two defenses against one signature being valid for a
    # different message than intended:
    #   1) DOMAIN + TYPE TAG ('xchat/sig/v2/<type>') — a signature over a 'post' can't be replayed as a
    #      'profile'/'follow'/etc.; each type has a disjoint preimage space.
    #   2) LENGTH-PREFIXED fields ('<utf8_bytelen>:<field>') — the old 'a|b|c' join was ambiguous
    #      because a field could itself contain '|' (free text, handles, bios), so distinct field
    #      tuples could produce identical bytes. Prefixing every field with its exact UTF-8 byte length
    #      makes the encoding injective: distinct tuples always yield distinct bytes.
    # Signed as UTF-8 bytes. The Dart app builds the IDENTICAL string in NanoWallet.sigCanon — keep the
    # two in lockstep (this is a hard wire-format break; old-format signatures no longer verify).
    out = 'xchat/sig/v2/' + msg_type
    for f in fields:
        s = f if isinstance(f, str) else str(f)
        out += '|' + str(len(s.encode('utf-8'))) + ':' + s
    return out

# ---- the four RELAY-VERIFIED signed types (issue #7) -------------------------------------------
# These were left on the legacy '|'-joined preimage when everything else moved to sig_canon, because
# they are verified by the separately-deployed relay as well as the node, so migrating them needs a
# coordinated deploy rather than one release. Defined ONCE here and imported by both sides — two
# copies of a signing preimage silently diverge, and the symptom is a valid signature being rejected.
#
# THE MIGRATION IS DELIBERATELY TWO-SIDED AND IN THIS ORDER:
#   1. verifiers accept v2 OR legacy  (this change — safe to deploy alone)
#   2. signers emit v2                (apps and tools; harmless once step 1 is everywhere)
#   3. legacy acceptance is dropped   (a later release, once old clients are gone)
# Doing it the other way round would break live traffic: every already-published release record is
# legacy-signed, so a verifier that demanded v2 today would reject the running app's own update
# record and take the self-update path down with it.

def report_canon(acc, pid, ts):
    return sig_canon('report', acc, pid, ts)

def reshare_canon(acc, pid, ts):
    return sig_canon('reshare', acc, pid, ts)

def release_canon(m):
    return sig_canon('release', m.get('publisher', ''), m.get('version', ''), m.get('cid', ''),
                     m.get('sha256', ''), m.get('size', ''), m.get('changelog', ''))

def attest_canon(a):
    return sig_canon('attest', a.get('version', ''), a.get('commit', ''), a.get('sha256', ''),
                     a.get('attestor', ''), a.get('type', ''))

# Legacy preimages, kept only so step 1 can still accept signatures made before step 2.
def report_canon_legacy(acc, pid, ts):
    return 'report|%s|%s|%s' % (acc, pid, ts)

def reshare_canon_legacy(acc, pid, ts):
    return 'reshare|%s|%s|%s' % (acc, pid, ts)

def release_canon_legacy(m):
    return '%s|%s|%s|%s|%s|%s' % (m.get('publisher', ''), m.get('version', ''), m.get('cid', ''),
                                  m.get('sha256', ''), m.get('size', ''), m.get('changelog', ''))

def attest_canon_legacy(a):
    return '%s|%s|%s|%s|%s' % (a.get('version', ''), a.get('commit', ''), a.get('sha256', ''),
                               a.get('attestor', ''), a.get('type', ''))

def verify_either(pub, sig, v2_msg, legacy_msg):
    # Accept the v2 preimage, or the legacy one during the transition. v2 is tried FIRST so that once
    # clients have moved the legacy path is dead weight rather than the common case.
    return verify_msg(pub, v2_msg, sig) or verify_msg(pub, legacy_msg, sig)


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

def verify_block(block):
    # Verify an app-signed Nano STATE block's signature LOCALLY, so the node can reject a forged block
    # BEFORE spending delegated PoW on it. Without this, an unauthenticated flood of shape-valid blocks
    # makes the node burn work_generate cycles on each before the ledger drops them (PoW amplification).
    # The account's own pubkey signs the block hash; a forger has no key, so this can't be faked.
    try:
        acc_pub = nano_to_pub(block['account'])
        rep_pub = nano_to_pub(block['representative'])
        bh = _block_hash(acc_pub, block['previous'], rep_pub, str(block['balance']), block['link'])
        return _ext.verify_signature(bytes.fromhex(block['signature']), bytes.fromhex(acc_pub), bh) == 1
    except Exception:
        return False

# --- Sybil-resistant moderation weight -----------------------------------------------------------
# A community report counts for its author's ON-CHAIN reputation, not one-account-one-vote, so a
# takedown needs reporters with real skin in the game, not a pile of empty throwaway keypairs.
REP_BAL_FULL = float(os.environ.get('XC_REP_BAL_FULL', '1'))    # XNO balance for full balance credit
REP_BLK_FULL = float(os.environ.get('XC_REP_BLK_FULL', '10'))   # chain blocks for full activity credit
REP_HALFLIFE = float(os.environ.get('XC_REP_HALFLIFE', str(30 * 86400)))   # rep halves per 30 idle days
REP_TTL      = float(os.environ.get('XC_REP_TTL', '300'))       # cache an account's reputation this long
REP_TELEPORT = float(os.environ.get('XC_REP_TELEPORT', '0.5'))  # EigenTrust anchor back to on-chain pre-trust
REP_ITERS    = int(os.environ.get('XC_REP_ITERS', '25'))        # trust-propagation iterations to convergence
_rep_cache = {}
# DISK-BACKED rep cache. Each account_rep miss is a ~0.66s mainnet RPC, and the feed re-aggregates every
# few seconds in a FRESH helper process — so an in-memory-only cache re-fetched every reporter's rep on
# every refresh. Persisting it (like the onchain-relay cache) lets spawns share it: within REP_TTL the
# background refresh does zero rep RPCs. Bounded naturally to accounts seen within REP_TTL.
_REP_CACHE_FILE = os.environ.get('XC_REP_CACHE', '/tmp/xc_rep_cache.json')
_rep_loaded = [False]
_rep_dirty = [False]

def _load_rep_cache():
    if _rep_loaded[0]:
        return
    _rep_loaded[0] = True
    try:
        d = json.load(open(_REP_CACHE_FILE))
        now = time.time()
        for a, v in d.items():
            if isinstance(v, (list, tuple)) and len(v) == 2 and now - v[1] < REP_TTL:
                _rep_cache.setdefault(a, (v[0], v[1]))          # keep only still-fresh entries
    except Exception:
        pass

def flush_rep_cache():
    # Atomically persist the fresh entries. Called once after a batch of account_rep lookups (e.g. at the
    # end of aggregate_reports) so a burst of parallel misses costs one write, not one per account.
    if not _rep_dirty[0]:
        return
    now = time.time()
    fresh = {a: [v[0], v[1]] for a, v in _rep_cache.items() if now - v[1] < REP_TTL}
    try:
        tmp = _REP_CACHE_FILE + '.tmp'
        json.dump(fresh, open(tmp, 'w'))
        os.replace(tmp, _REP_CACHE_FILE)
        _rep_dirty[0] = False
    except Exception:
        pass

def account_rep(account):
    # Reputation in [0,1]. An UNOPENED account (a fresh throwaway) weighs 0. An opened account gets a
    # small floor plus credit for balance and chain height, then DECAYS by on-chain inactivity: an
    # account dormant on the ledger (its last block is old) loses weight on a half-life, so stale
    # standing fades. All read from the ledger — trustless. Cached in RAM + on disk (shared across spawns).
    _load_rep_cache()
    now = time.time()
    c = _rep_cache.get(account)
    if c and now - c[1] < REP_TTL:
        return c[0]
    rep = 0.0
    try:
        info = rpc({'action': 'account_info', 'account': account})
        if info and 'balance' in info and 'error' not in info:
            bal = int(info.get('balance', '0')) / 1e30
            blocks = int(info.get('block_count', '0'))
            base = min(1.0, 0.2 + 0.4 * min(1.0, bal / REP_BAL_FULL) + 0.4 * min(1.0, blocks / REP_BLK_FULL))
            mod = float(info.get('modified_timestamp', 0) or 0)                 # last on-chain activity
            decay = 0.5 ** (max(0.0, now - mod) / REP_HALFLIFE) if mod > 0 else 1.0
            rep = base * decay
    except Exception:
        rep = 0.0
    _rep_cache[account] = (rep, now)
    _rep_dirty[0] = True
    return rep

def aggregate_reports(relays):
    # Read /reports from every relay, VERIFY each signature + key<->author binding, dedupe by account,
    # then weight reporters by ITERATIVE TRUST PROPAGATION seeded by their on-chain reputation (below).
    # Returns post_id -> {'weight' (sum of its reporters' propagated trust), 'count', 'cid'}.
    per = {}                                                # pid -> {'accts': set(acc), 'cid': cid}
    reporters = {}                                          # acc -> set(pid) they reported
    def _fetch(r):                                          # /reports from one relay (network I/O)
        try:
            return json.loads(urllib.request.urlopen(r + '/reports', timeout=4).read()).get('reports', {})
        except Exception:
            return None
    fetched = []
    if relays:                                              # PARALLEL fan-out (was a serial per-relay loop)
        with ThreadPoolExecutor(max_workers=min(16, len(relays))) as ex:
            fetched = list(ex.map(_fetch, relays))
    for d in fetched:
        if d is None:
            continue
        for pid, recs in (d or {}).items():
            for acc, rec in (recs or {}).items():
                pub, sig, ts = rec.get('pub', ''), rec.get('sig', ''), rec.get('ts', 0)
                if pub_to_addr(pub) != acc or not verify_either(
                        pub, sig, report_canon(acc, pid, ts), report_canon_legacy(acc, pid, ts)):
                    continue
                e = per.setdefault(pid, {'accts': set(), 'cid': ''})
                e['accts'].add(acc)                         # dedupe by account across relays
                if rec.get('cid'):
                    e['cid'] = rec.get('cid')
                reporters.setdefault(acc, set()).add(pid)
    # ITERATIVE TRUST PROPAGATION (pre-trust-anchored EigenTrust). pre-trust p = on-chain reputation
    # (the Sybil-resistant seed); agreement C[i][j] = how much of i's reporting overlaps j (they flag
    # the same posts). Iterate  t = (1-a)*C^T*t + a*p  to a fixed point: trust flows to reporters the
    # trusted agree with, so a modest account corroborated by high-trust accounts is BOOSTED above its
    # own pre-trust. Because C is row-stochastic and the teleport re-anchors to p, total trust converges
    # to the total pre-trust -- a Sybil swarm (pre-trust 0) can only REDISTRIBUTE real trust by mimicking
    # trusted reporters, never manufacture it.
    accts = list(reporters)
    # pre-trust = on-chain reputation. account_rep is a mainnet RPC (~0.66s) on a cache miss, so a fresh
    # spawn paid one PER reporter SERIALLY — the dominant feed-aggregation cost. Fetch them in parallel.
    if accts:
        with ThreadPoolExecutor(max_workers=min(16, len(accts))) as ex:
            p = dict(zip(accts, ex.map(account_rep, accts)))
        flush_rep_cache()                            # persist the batch so the next spawn reuses it (no re-RPC)
    else:
        p = {}
    if sum(p.values()) <= 0:                                # no real reputation anywhere -> no takedowns
        return {pid: {'weight': 0.0, 'count': len(e['accts']), 'cid': e['cid']} for pid, e in per.items()}

    raw = {a: {} for a in accts}                            # co-report counts: raw[i][j] = posts i and j both flagged
    for e in per.values():
        rs = list(e['accts'])
        for i in rs:
            ri = raw[i]
            for j in rs:
                if i != j:
                    ri[j] = ri.get(j, 0) + 1
    C = {}                                                  # row-normalised agreement (stochastic where non-empty)
    for i in accts:
        s = sum(raw[i].values())
        C[i] = {j: c / s for j, c in raw[i].items()} if s > 0 else {}

    a = REP_TELEPORT
    t = dict(p)                                             # iterate to the fixed point
    for _ in range(REP_ITERS):
        tn = {acc: a * p[acc] for acc in accts}             # a*p teleport (re-anchor to pre-trust)
        for i in accts:
            ti = t[i]
            if ti:
                w = (1.0 - a) * ti
                for j, cij in C[i].items():
                    tn[j] += w * cij                        # trust flows from i to those it agrees with
        t = tn

    return {pid: {'weight': round(sum(t.get(acc, 0.0) for acc in e['accts']), 4),
                  'count': len(e['accts']), 'cid': e['cid']}
            for pid, e in per.items()}

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
        out = subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': IPFS_PATH}, timeout=20)
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

def url_norm(url):  # canonical relay URL: no scheme, no trailing slash (the scheme is re-added on read)
    return url.strip().rstrip('/').split('://', 1)[-1]

def url_to_link(url):  # a relay URL packed into a 32-byte block link as ASCII (mainnet, no IPFS)
    b = url_norm(url).encode('ascii')
    if len(b) > 32:
        raise ValueError(f'relay URL is {len(b)} bytes; the on-chain link holds at most 32 (use a short host)')
    return (b + bytes(32 - len(b))).hex()

def _ip_is_internal(ip):
    # An address the node must never be steered at: loopback/private/link-local (incl. cloud metadata
    # 169.254.169.254), reserved, multicast, unspecified. Also block IPv4-mapped IPv6 (::ffff:127.0.0.1)
    # by unwrapping it first — otherwise ::ffff:10.0.0.1 sails past the v6 checks to an internal v4 host.
    try:
        if getattr(ip, 'ipv4_mapped', None):
            ip = ip.ipv4_mapped
    except Exception:
        pass
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_reserved or ip.is_multicast or ip.is_unspecified)

def resolve_safe(u):
    # Resolve a URL to a SINGLE validated IP and hand it back with the host, so the caller can connect
    # to that exact address (see safe_urlopen). Returns None if anything about it is unsafe.
    try:
        p = urllib.parse.urlparse(u)
        host = p.hostname or ''
        if p.scheme not in ('http', 'https') or not host:
            return None
        if host == 'localhost' or host.endswith('.local') or host.endswith('.internal'):
            return None
        port = p.port or (443 if p.scheme == 'https' else 80)
        try:
            ip = ipaddress.ip_address(host)
            return None if _ip_is_internal(ip) else (host, str(ip), port, p.scheme)
        except ValueError:
            pass
        addrs = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
        if not addrs:
            return None
        chosen = None
        for _f, _t, _p, _c, sockaddr in addrs:
            ip = ipaddress.ip_address(sockaddr[0])
            if _ip_is_internal(ip):
                return None                 # ANY internal answer disqualifies the name entirely
            if chosen is None:
                chosen = str(ip)
        return (host, chosen, port, p.scheme) if chosen else None
    except Exception:
        return None


class _PinnedHTTPConnection(http.client.HTTPConnection):
    # Connects to a PRE-VALIDATED ip while still presenting the original hostname.
    def __init__(self, host, ip, **kw):
        super().__init__(host, **kw)
        self._pinned_ip = ip

    def connect(self):
        self.sock = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        if getattr(self, '_tunnel_host', None):
            self._tunnel()


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, ip, **kw):
        super().__init__(host, **kw)
        self._pinned_ip = ip

    def connect(self):
        sock = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        if getattr(self, '_tunnel_host', None):
            self.sock = sock
            self._tunnel()
            sock = self.sock
        # server_hostname keeps SNI and certificate validation bound to the NAME, not the pinned ip —
        # so pinning the address does not weaken TLS.
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


# ---- pinned connections, installed globally (issue #8) -----------------------------------------
# is_safe_relay_url resolves a name and validates every address, but that is CHECK time: the fetch a
# moment later resolves again, and a hostile resolver can answer public for the check and internal for
# the fetch. Rather than rewrite ~55 call sites (each an opportunity to miss one or get a timeout
# wrong), the validated address is remembered here and the connection layer uses it. Every existing
# urlopen keeps working unchanged and simply lands on the address that was actually vetted.
_PIN_TTL = float(os.environ.get('XC_PIN_TTL', '300'))
_pins = {}                                   # host -> (ip, expiry)


def _pin_remember(host, ip):
    _pins[host] = (ip, time.time() + _PIN_TTL)


def _pin_for(host):
    got = _pins.get(host)
    if not got:
        return None
    ip, exp = got
    if time.time() > exp:
        _pins.pop(host, None)
        return None
    return ip


def _pin_drop(host):
    # A pin that will not connect must not wedge a host permanently — an anycast address can go away,
    # and a relay can legitimately move. Forget it and let the next attempt re-resolve and re-validate.
    _pins.pop(host, None)


def _pinned_connection(base):
    class _Pinned(base):
        def connect(self):
            ip = _pin_for(self.host)
            if not ip:
                return super().connect()          # never validated: behave exactly as before
            try:
                sock = socket.create_connection((ip, self.port), self.timeout)
            except OSError:
                _pin_drop(self.host)
                return super().connect()
            if getattr(self, '_tunnel_host', None):
                self.sock = sock
                self._tunnel()
                sock = self.sock
            ctx = getattr(self, '_context', None)
            # SNI and certificate validation stay bound to the NAME, so pinning cannot weaken TLS.
            self.sock = ctx.wrap_socket(sock, server_hostname=self.host) if ctx else sock
    return _Pinned


class _PinnedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_pinned_connection(http.client.HTTPConnection), req)


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_pinned_connection(http.client.HTTPSConnection), req,
                            context=self._context)


urllib.request.install_opener(urllib.request.build_opener(_PinnedHTTPHandler, _PinnedHTTPSHandler))


def safe_urlopen(url, data=None, timeout=20, headers=None):
    # CLOSES THE REBINDING TOCTOU (issue #8). is_safe_relay_url resolves and validates, but that is
    # check-time only: a hostile resolver can answer with a public address for the check and an internal
    # one for the fetch a moment later, and the fetch is what actually reaches the target. Here the
    # address validated is the address connected to — resolution happens ONCE and the result is pinned
    # for the connection, so there is no window to flip.
    #
    # Use for any URL learned from an untrusted source (on-chain announcements, peer gossip). Raises on
    # an unsafe or unresolvable target, like a refused connection.
    got = resolve_safe(url)
    if not got:
        raise ValueError('unsafe or unresolvable url: %s' % url)
    host, ip, port, scheme = got
    p = urllib.parse.urlparse(url)
    path = p.path or '/'
    if p.query:
        path += '?' + p.query
    hdr = {'Host': host, 'User-Agent': 'xchat-node/0.1', **(headers or {})}
    if data is not None and 'Content-Type' not in hdr:
        hdr['Content-Type'] = 'application/json'
    cls = _PinnedHTTPSConnection if scheme == 'https' else _PinnedHTTPConnection
    conn = cls(host, ip, port=port, timeout=timeout)
    try:
        conn.request('POST' if data is not None else 'GET', path, body=data, headers=hdr)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status >= 400:
            raise urllib.error.HTTPError(url, resp.status, resp.reason, resp.headers, None)
        return body
    finally:
        conn.close()


def is_safe_relay_url(u):
    # SSRF guard for relay URLs learned from UNTRUSTED sources (on-chain announcements + peer gossip).
    # Those become GET/POST targets for the node's helpers, so a hostile announcer could point discovery
    # at an internal address (cloud metadata 169.254.169.254, 127.0.0.1:<admin>, a LAN box). Require
    # http(s) and reject loopback/private/link-local/reserved targets.
    # (The node's OWN co-located relay is loopback, but it enters via the explicit bootstrap, not here.)
    try:
        p = urllib.parse.urlparse(u)
        host = p.hostname or ''
        if p.scheme not in ('http', 'https') or not host:
            return False
        if host == 'localhost' or host.endswith('.local') or host.endswith('.internal'):
            return False
        try:
            return not _ip_is_internal(ipaddress.ip_address(host))
        except ValueError:
            pass                             # not an IP literal — a DNS name; resolve and validate below
        # DNS name: an IP-literal blocklist alone is bypassed by a hostname whose A/AAAA record points
        # at an internal address (classic DNS-rebinding SSRF). Resolve EVERY record and reject if ANY is
        # internal — a name that resolves to a public address now can't smuggle in a loopback answer.
        try:
            addrs = socket.getaddrinfo(host, p.port or (443 if p.scheme == 'https' else 80),
                                       proto=socket.IPPROTO_TCP)
        except socket.gaierror:
            return False                     # unresolvable — treat as unsafe
        if not addrs:
            return False
        for _fam, _type, _proto, _canon, sockaddr in addrs:
            if _ip_is_internal(ipaddress.ip_address(sockaddr[0])):
                return False
        _pin_remember(host, addrs[0][4][0])   # the fetch will use THIS address, not a fresh lookup
        return True
    except Exception:
        return False

def link_to_url(link_hex):  # inverse: a link that is printable ASCII + looks like a host -> https URL, else None
    try:
        b = bytes.fromhex(link_hex).rstrip(b'\x00')
        s = b.decode('ascii')
        if s and '.' in s and all(32 < c < 127 for c in b):
            url = 'https://' + s
            return url if is_safe_relay_url(url) else None   # reject on-chain-announced internal targets
    except Exception:
        pass
    return None

def relay_announce_operator(url, opkey):
    # MAINNET announce: an OPERATOR's already-funded account vouches for a relay URL. No dev genesis,
    # no IPFS — the URL rides in the block link as ASCII, human-verifiable in any block explorer. The
    # account must already be opened (funded). Dust check-ins let a keyless rendezvous enumerate it;
    # the URL is committed LAST so the frontier link is the URL (one read resolves it).
    url = url_norm(url)
    link = url_to_link(url)                             # validate length up-front, before any send
    addr, _ = derive(opkey)
    if 'error' in rpc({'action': 'account_info', 'account': addr}):
        raise RuntimeError(f'operator account {addr} is not opened/funded — send it a little XNO first')
    for rv in rendezvous_accts():                       # check in at each rendezvous
        try:
            _self_send(opkey, nano_to_pub(rv))
        except Exception:
            pass
    _self_send(opkey, link)                             # commit the URL last (frontier link = URL)
    return addr, url


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
            u = link_to_url(link)                        # mainnet: URL packed as ASCII in the link
            if u:
                return u
            out = subprocess.check_output(['ipfs', 'cat', digest_to_cid(link)],   # legacy: URL via IPFS CID
                                          env={**os.environ, 'IPFS_PATH': IPFS_PATH}, timeout=5)
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
    # SEEDLESS NODE: there is no wallet seed on the node anymore. Kept only so any dead legacy code
    # imports without error; it returns nothing, so the node has no key material at rest.
    try:
        s = open(WALLET_FILE).read().strip()
        if len(s) >= 64:
            return s[:64]
    except Exception:
        pass
    return ''                                          # no baked-in seed

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
        if time.time() - c['ts'] < ttl and 'relays' in c:   # honor an EMPTY result too — see below
            return c['relays']
    except Exception:
        pass
    relays = []
    try:
        relays = sorted({u for a in _relay_accounts() if (u := _relay_url(a))})
    except Exception:
        relays = []
    # ALWAYS cache the scan result, INCLUDING an empty one. On a node where no relay has announced
    # on-chain (the mainnet default until the operator does a funded announce) the scan returns [], and
    # the old check (`c.get('relays')` truthy) treated that as "no cache" — so EVERY helper spawn re-ran
    # the slow mainnet ledger scan. Under the app's launch burst that meant many concurrent scans, which
    # pegged the node and hung it. Caching [] fixes it. Only a NON-empty set is mirrored into the
    # persisted known-relays list (never wipe that list with an empty scan).
    try:
        json.dump({'ts': time.time(), 'relays': relays}, open(_ONCHAIN_CACHE, 'w'))
    except Exception:
        pass
    if relays:
        try:
            json.dump({'ts': time.time(), 'relays': relays}, open(_KNOWN_RELAYS, 'w'))
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
    # UNION of every source, ledger first — a node keeps its own co-located relay AND adds the ones
    # it discovers on-chain, instead of a discovery replacing (and starving) the local set.
    s = list(onchain_relays()) + list(known_relays())
    try:
        s += [l.strip() for l in open('/tmp/xchat_bootstrap.txt') if l.strip()]
    except Exception:
        pass
    s += [u for u in os.environ.get('XCHAT_BOOTSTRAP', '').split(',') if u]
    s = [u.rstrip('/') for u in dict.fromkeys(s) if u]
    return s or ['http://127.0.0.1:7401', 'http://127.0.0.1:7402', 'http://127.0.0.1:7403']
BOOTSTRAP = _bootstrap()
HEAD_TTL = int(os.environ.get('XC_HEAD_TTL', '2592000'))  # 30-day backstop; the relay keeps a head until
                                         # MEMORY pressure evicts it by value (tips - reports), not on a clock

def acct_seed():                         # account address -> seed byte (for demo authors we can sign)
    return {acct(sb): sb for sb in SEEDMAP.values()}

# The node's OWN public URL (the embedded relay's advertised identity). The node reaches that same relay
# via loopback (127.0.0.1:7401), so its public URL in a relay set is a HAIRPIN: a helper fetching from it
# calls the node through the edge and back. On a single-instance node under load every worker can end up
# waiting on its own hairpin request while no worker is free to serve it — a self-deadlock that hung the
# node repeatedly (feed/release_check timing out). Drop the hairpin; loopback covers it.
_SELF_PUBLIC = os.environ.get('RELAY_PUBLIC_URL', '').rstrip('/')

def discover_relays(bootstrap=None):     # gossip BFS: follow /relays from a bootstrap to the full set
    # Parallel by LEVEL: fetch /relays from the whole current frontier at once, then descend. This runs
    # on every helper spawn, and a serial BFS paid one round-trip PER relay (~N × RTT); a wave-parallel
    # BFS pays one round-trip per HOP (the graph converges in 1-2 hops), so it's the slowest single call.
    seed = list(bootstrap or BOOTSTRAP)
    seen = set(seed); found = set(); frontier = list(seed)
    def _q(u):
        try:
            return u, json.loads(urllib.request.urlopen(u + '/relays', timeout=3).read()).get('relays', [])
        except Exception:
            return u, None
    while frontier:
        nxt = []
        with ThreadPoolExecutor(max_workers=min(16, len(frontier))) as ex:
            for u, relays in ex.map(_q, frontier):
                if relays is None:
                    continue
                found.add(u)
                for r in relays:
                    if r not in seen and is_safe_relay_url(r):   # SSRF: don't chase gossiped internal targets
                        seen.add(r); nxt.append(r)
        frontier = nxt
    result = sorted(found) if found else list(seed)
    # Replace the hairpin with loopback only when we actually have a loopback twin (i.e. we ARE the node
    # hosting this relay); a no-op on the standalone relay, which has no co-located loopback relay.
    if _SELF_PUBLIC and any('127.0.0.1' in u or 'localhost' in u for u in result):
        filtered = [u for u in result if u.rstrip('/') != _SELF_PUBLIC]
        if filtered:
            result = filtered
    return result
