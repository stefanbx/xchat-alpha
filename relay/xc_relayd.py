#!/usr/bin/env python3
# A ӾChat RELAY. Holds signed author HEADS ({author, handle, seq, cid, expires, sig, pub}),
# gossips relay membership (bootstrap + /relays), and expires stale heads (TTL). Independent
# and swappable — run several; clients DISCOVER the set from a bootstrap, no hardcoding.
# Usage: xc_relayd.py <port> <store.json> [bootstrap_url ...]
import json, sys, os, time, threading, sqlite3, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import importlib.util
xc = None                                       # xc_common: relay account + pay-to-pin ledger reads
_here = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_here, "xc_common.py"),          # staged next to the relay (deploy)
           os.path.join(_here, "..", "backend", "xc_common.py")):  # repo layout
    if os.path.exists(_p):
        try:
            _spec = importlib.util.spec_from_file_location("xc_common", _p)
            xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)
            break
        except Exception:
            xc = None

PORT = int(sys.argv[1]); STORE = sys.argv[2]
BIND = os.environ.get('BIND_HOST', '127.0.0.1')      # '0.0.0.0' when hosted (Fly.io)
# public URL other nodes reach this relay at; defaults to loopback for local runs
SELF = os.environ.get('RELAY_PUBLIC_URL', f'http://127.0.0.1:{PORT}')
# this relay's Nano account (for tip-split rewards). Env-first so a hosted relay (Fly.io / Linux)
# needs no Mac-native key tool; falls back to deriving it locally.
RELAY_ACCT = os.environ.get('RELAY_ACCT') or ''
if not RELAY_ACCT and xc is not None:
    try:
        RELAY_ACCT = xc.acct(0x50 + (PORT - 7401))
    except Exception:
        RELAY_ACCT = ''
engage = {}                                    # post_id -> {"likes": n, "tips_raw": int}
# The pinned app-update publisher (public by nature). A joining relay backfills this publisher's
# signed release records so it can serve updates immediately — the relay verifies nothing (clients do).
PUBLISHER_ACCT = os.environ.get('XC_PUBLISHER_ACCOUNT',
    'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8')
BOOTSTRAPS = sys.argv[3:]
heads = {}
notifs = {}
supporters = {}
follows = {}                         # account -> signed follow-list record (portable follow graph)
comments = {}                        # post_id -> list of signed comment events (off-chain replies)
releases = {}                        # publisher account -> signed release record (self-update head)
profiles = {}                        # account -> signed profile record (display name, bio, avatar/banner CIDs)
dmkeys = {}                          # account -> signed X25519 DM public key record (E2E encryption)
dms = []                             # list of encrypted direct messages (ciphertext only; relay can't read)
pollvotes = {}                       # poll_id -> {account: signed vote record} (one vote per account)
reports = {}                         # post_id -> {account: signed report} (community moderation signal)
known = {SELF}                       # relays this relay knows about

def head_score(author, h):
    # A head's eviction rank, computed TRUSTLESSLY by the relay from the ledger — no supporter hint.
    # It's the author's on-chain reputation (account_rep: balance + chain activity, cached): a Sybil
    # throwaway is 0, and because received TIPS are on-chain XNO that raise the creator's balance, a
    # popular creator's reputation rises on its own. Recency breaks ties. So under memory pressure the
    # least-established (spam) heads are dropped first, and a Sybil head-flood can't evict real posts.
    rep = xc.account_rep(author) if xc is not None else 0.0
    return (rep, h.get('ts', 0))

# --- anti-spam / DoS hardening ------------------------------------------------
# A relay verifies nothing and stores signed bytes; clients verify on read, so forged spam is inert
# junk — it can never appear in a feed or impersonate. These bounds stop an UNAUTHENTICATED flood
# from growing one relay's RAM/CPU without limit. (The plural network already routes around a bad
# relay; this keeps each individual relay standing.)
HEAD_TTL    = int(os.environ.get('XC_HEAD_TTL', '2592000'))   # 30-day backstop; MEMORY (MAX_HEADS) is the
                                                              # real limit, and value-eviction is the cleanup
HEAD_SKEW   = 900                                             # clock-skew slack on the max expiry
MAX_HEADS   = int(os.environ.get('XC_MAX_HEADS', '50000'))    # hard cap on live authors (backstop)
NOTIF_MAX   = int(os.environ.get('XC_NOTIF_MAX', '200'))      # per-recipient notification cap
NOTIF_ACCTS = int(os.environ.get('XC_NOTIF_ACCTS', '20000'))  # cap on distinct notified accounts
DM_MAX      = int(os.environ.get('XC_DM_MAX', '20000'))       # global ciphertext mailbox cap
# Per-IP WRITE throttle. Note a shared node proxies many users under ONE IP, so this must be well
# above legit aggregate node traffic — it's a coarse CPU throttle against a naive single-source
# flood, NOT the memory guarantee. Memory is bounded regardless of rate by the caps + prune above.
RATE_MAX    = int(os.environ.get('XC_RATE_MAX', '600'))       # writes per window per client IP (~60/s)
RATE_WINDOW = int(os.environ.get('XC_RATE_WINDOW', '10'))     # rate-limit window (s)
RATE_ACCTS  = int(os.environ.get('XC_RATE_ACCTS', '100000'))  # cap on tracked IP buckets (backstop)
# Body + per-record ceilings. Records are tiny (a signed pointer/JSON); only content blobs are large,
# so the POST body is capped small for everything EXCEPT /blob. Without this a single multi-GB body is
# read whole into RAM (one thread per connection) → OOM. Every keyed table also gets a distinct-key cap
# so an unauthenticated flood of random keys can't grow RAM/disk without bound (the value-eviction on
# heads/blobs already did this; these extend it to the rest of the state).
MAX_BODY    = int(os.environ.get('XC_MAX_BODY', str(512 * 1024)))          # non-blob POST body cap
MAX_BLOB    = int(os.environ.get('XC_MAX_BLOB', str(32 * 1024 * 1024)))    # per-blob b64 cap (APK-sized)
FOLLOWS_MAX     = int(os.environ.get('XC_FOLLOWS_MAX', '50000'))     # distinct accounts with a follow record
FOLLOW_LIST_MAX = int(os.environ.get('XC_FOLLOW_LIST_MAX', '5000'))  # follows inside one record
PROFILES_MAX    = int(os.environ.get('XC_PROFILES_MAX', '50000'))
DMKEYS_MAX      = int(os.environ.get('XC_DMKEYS_MAX', '50000'))
SUPPORTERS_MAX  = int(os.environ.get('XC_SUPPORTERS_MAX', '50000'))
POLLS_MAX       = int(os.environ.get('XC_POLLS_MAX', '50000'))       # distinct polls with votes
POLL_VOTERS_MAX = int(os.environ.get('XC_POLL_VOTERS_MAX', '50000')) # voters stored per poll
COMMENT_POSTS_MAX = int(os.environ.get('XC_COMMENT_POSTS_MAX', '50000'))  # distinct posts with comments
COMMENTS_PER_POST = int(os.environ.get('XC_COMMENTS_PER_POST', '1000'))
ENGAGE_MAX      = int(os.environ.get('XC_ENGAGE_MAX', '200000'))     # distinct post_ids with engagement
RESHARERS_MAX   = int(os.environ.get('XC_RESHARERS_MAX', '1000'))    # resharers stored per post
KNOWN_MAX       = int(os.environ.get('XC_KNOWN_MAX', '10000'))       # distinct relay URLs gossiped
FIELD_MAX       = int(os.environ.get('XC_FIELD_MAX', '8192'))        # bytes per free-text record field
RELEASE_PUBS_MAX = int(os.environ.get('XC_RELEASE_PUBS_MAX', '8'))   # distinct release publishers stored

def _cap_dict(d, maxn):
    # Distinct-key backstop: evict oldest-inserted keys until within maxn. Python dicts are
    # insertion-ordered, so next(iter(d)) is the oldest key; updating an existing key keeps its slot.
    while len(d) > maxn:
        d.pop(next(iter(d)), None)

def engage_for(pid):
    e = engage.setdefault(pid, {'likes': 0, 'tips_raw': 0, 'reposts': 0})
    _cap_dict(engage, ENGAGE_MAX)                # bound distinct post_ids (was unbounded → OOM)
    return e

_heads_lock = threading.Lock()                                # guards heads across prune + /push
_dm_seen = set()                                              # (from, ts) O(1) dedup for the mailbox

_dirty = False                                                # state changed since the last flush
def mark_dirty():
    global _dirty
    _dirty = True

_rate = {}                                                    # client-ip -> [window_start, count]
_rate_lock = threading.Lock()
def rate_ok(ip):                                              # fixed-window per-IP write throttle
    now = time.time()
    with _rate_lock:
        w = _rate.get(ip)
        if not w or now - w[0] >= RATE_WINDOW:
            if ip not in _rate and len(_rate) >= RATE_ACCTS:
                _rate.pop(next(iter(_rate)), None)   # backstop: bound the number of tracked buckets
            _rate[ip] = [now, 1]; return True
        if w[1] >= RATE_MAX:
            return False
        w[1] += 1; return True

# --- content cache: a relay is a CACHE, not an archive, and blobs live on DISK ---
# Media blobs are held in an embedded SQLite table (not RAM, not the JSON store), so the relay's
# memory stays small and the cache can be as large as the disk, and writes are INCREMENTAL (one row
# per put/evict) instead of re-serialising the whole state every few seconds. A byte cap + eviction
# still apply: keep everything until full, then drop the LEAST-VALUABLE unpinned blobs first —
# untipped before tipped, least-recently-used within a level. Pay-to-pin protects a CID until paid.
BLOB_CAP = int(float(os.environ.get('XC_BLOB_CAP_MB', '512')) * 1024 * 1024)   # disk cache ceiling
PIN_DAYS_PER_XNO = float(os.environ.get('XC_PIN_DAYS_PER_XNO', '30000'))       # 0.001 XNO ≈ 30 days pinned
_PIN_S_PER_RAW = PIN_DAYS_PER_XNO * 86400.0 / 1e30
pinned = {}                          # cid -> pin-expiry epoch (paid); survives eviction until then
pins_paid = {}                       # payment block hash -> cid (consumed once; audit + no double-claim)
blob_meta = {}                       # cid -> {'size','last','tips','reports'} — small RAM eviction index

# Moderation as a NEGATIVE value signal. A signed community report cancels some of a post's tip-value,
# so ONE score — tips minus reports — ranks EVERYTHING: eviction (low score drops first), sync-the-best
# (high score replicates first; reported content isn't propagated), and a hard takedown once distinct
# reporters cross the threshold (the media is deleted; the post drops from the feed for everyone).
REPORT_WEIGHT   = float(os.environ.get('XC_REPORT_WEIGHT', '0.05'))   # XNO-equiv value one rep-unit cancels
TAKEDOWN_WEIGHT = float(os.environ.get('XC_TAKEDOWN_WEIGHT', '2'))    # reputation-weighted reporters -> drop
REPORT_POSTS    = int(os.environ.get('XC_REPORT_POSTS', '50000'))     # cap distinct reported posts
REPORT_PER_POST = int(os.environ.get('XC_REPORT_PER_POST', '1000'))   # cap reporters stored per post
_blob_reporters = {}                 # cid -> {account: reputation} (dedupe + weight; rebuilt on load)

def blob_score(m):                   # the universal value: tips earned minus the reputation-weighted penalty
    return float(m.get('tips', 0.0)) - float(m.get('reports', 0.0)) * REPORT_WEIGHT

_DB = os.path.join(os.path.dirname(os.path.abspath(STORE)) or '.', 'blobs.db')
_db = sqlite3.connect(_DB, check_same_thread=False)
_db.execute('PRAGMA journal_mode=WAL')
_db.execute('CREATE TABLE IF NOT EXISTS blob (cid TEXT PRIMARY KEY, b64 TEXT NOT NULL, '
            'size INTEGER, last REAL, tips REAL)')
_db.commit()
_blob_lock = threading.Lock()        # serialises all SQLite access (fine at relay throughput)

def _blob_total():
    return sum(m['size'] for m in blob_meta.values())

def blob_get(cid):                   # serve content from disk
    with _blob_lock:
        r = _db.execute('SELECT b64 FROM blob WHERE cid=?', (cid,)).fetchone()
    return r[0] if r else None

def blob_has(cid):
    return cid in blob_meta

def blob_put(cid, b64, tips=0.0):
    # Reject an oversized blob BEFORE it is written. Two bugs this closes: (1) no per-blob ceiling let a
    # single huge upload fill the disk; (2) a blob larger than BLOB_CAP, stored first and evicted after,
    # sorted itself last (fresh + untipped) and so evicted EVERY other blob to get under cap while
    # surviving — one POST wiped the whole cache. With a per-blob cap << BLOB_CAP that can't happen.
    if not cid or not b64 or len(b64) > MAX_BLOB:
        return False
    with _blob_lock:
        now = time.time()
        t = max(float(tips or 0), float((blob_meta.get(cid) or {}).get('tips', 0)))   # value ratchets up
        _db.execute('INSERT OR REPLACE INTO blob (cid,b64,size,last,tips) VALUES (?,?,?,?,?)',
                    (cid, b64, len(b64 or ''), now, t))
        blob_meta[cid] = {'size': len(b64 or ''), 'last': now, 'tips': t,
                          'reports': sum(_blob_reporters.get(cid, {}).values())}   # carry existing report weight
        _evict_locked()
        _db.commit()
        return True

def blob_report(cid, account, rep):
    # a signed, reputation-WEIGHTED community report referencing this media: a NEGATIVE term in
    # blob_score, and a hard PRIORITY TAKEDOWN (delete now, ignore the cap) once the weighted sum of
    # distinct reporters crosses TAKEDOWN_WEIGHT — unless the content is paid-pinned. Weighting by
    # account_rep is what stops a pile of empty throwaway accounts from forcing a takedown.
    if not cid or rep <= 0:
        return
    with _blob_lock:
        s = _blob_reporters.setdefault(cid, {}); s[account] = rep     # dedupe by account, keep its weight
        w = sum(s.values())
        m = blob_meta.get(cid)
        if m:
            m['reports'] = w
        if m and w >= TAKEDOWN_WEIGHT and pinned.get(cid, 0) <= time.time():
            _db.execute('DELETE FROM blob WHERE cid=?', (cid,)); _db.commit()
            blob_meta.pop(cid, None)

def blob_touch(cid):                 # a read counts as use; RAM-only (avoids a write per read)
    m = blob_meta.get(cid)
    if m:
        m['last'] = time.time()

def _evict_locked():                 # called with _blob_lock held; drops least-valuable unpinned first
    total = _blob_total()
    if total <= BLOB_CAP:
        return
    now = time.time()
    victims = sorted((blob_score(m), m['last'], c)          # lowest score first (reported + untipped)
                     for c, m in blob_meta.items() if pinned.get(c, 0) <= now)
    for _score, _last, c in victims:
        if total <= BLOB_CAP:
            break
        total -= blob_meta[c]['size']
        _db.execute('DELETE FROM blob WHERE cid=?', (c,))
        blob_meta.pop(c, None)

def blob_load_meta():                # startup: rebuild the small RAM index from the SQLite table
    with _blob_lock:
        for cid, size, last, tips in _db.execute('SELECT cid,size,last,tips FROM blob'):
            blob_meta[cid] = {'size': size, 'last': last, 'tips': tips or 0.0, 'reports': 0.0}

def ensure_release_blob(cid):
    # A signed release (an app update) is CRITICAL INFRA — every relay must hold it, independent of tips
    # or the value-ranked sync budget. So: PIN it (never evict), and if we don't already have the bytes,
    # pull them from a peer relay that does. Runs in a background thread (a 20 MB pull mustn't block a
    # request). This is what makes an update propagate to the whole relay set on its own.
    if not cid:
        return
    pinned[cid] = time.time() + 3650 * 86400          # ~never; releases are few (capped per publisher) and small
    if blob_has(cid):
        return
    for r in list(known):
        if r == SELF or '127.0.0.1' in r or 'localhost' in r:
            continue                                   # a peer, not ourselves/loopback (we're here BECAUSE we lack it)
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=90).read())
            if d.get('b64'):
                blob_put(cid, d['b64'])
                return
        except Exception:
            pass

def sync_release_blobs():
    # on startup (and after gossip), make sure we hold every known release's bytes — catches a relay that
    # was down when a release was published.
    time.sleep(1.0)
    for _pub, recs in list(releases.items()):
        for rec in recs:
            ensure_release_blob(rec.get('cid'))

def _release_canon(m):
    return '%s|%s|%s|%s|%s|%s' % (m.get('publisher', ''), m.get('version', ''), m.get('cid', ''),
                                  m.get('sha256', ''), m.get('size', ''), m.get('changelog', ''))

def accept_release(m):
    # Ingest a signed release record — VERIFYING it, unlike other relay writes. Releases are app
    # updates, so a forged flood here isn't inert junk: the old code stored any record and capped the
    # list at 24, which let an attacker push ≥24 forged records under the pinned publisher's key and
    # EVICT the genuine one, freezing updates network-wide (a suppression attack). Now the relay checks
    # the publisher-pinned signature at the door and drops anything that doesn't validate, so forged
    # records never enter, the list stays genuine, and the per-cid pin + background pull can't be
    # amplified by junk. Returns True if newly stored.
    if xc is None:
        return False
    pub_acc = m.get('publisher', '')
    pub, sig = m.get('pub', ''), m.get('sig', '')
    if pub_acc != PUBLISHER_ACCT:                      # only the pinned publisher's channel is stored
        return False
    try:
        if xc.pub_to_addr(pub) != PUBLISHER_ACCT or not xc.verify_msg(pub, _release_canon(m), sig):
            return False
    except Exception:
        return False
    lst = releases.setdefault(pub_acc, [])
    if any(x.get('sig') == sig for x in lst):
        return False
    lst.append(m)
    releases[pub_acc] = lst[-24:]
    _cap_dict(releases, RELEASE_PUBS_MAX)
    if m.get('cid'):
        threading.Thread(target=ensure_release_blob, args=(m['cid'],), daemon=True).start()
    mark_dirty()
    return True

def backfill():
    # SYNC ON JOIN. bootstrap() learns the peer list but pulls no content, so a freshly launched
    # relay used to come up blank and only accumulate what was pushed to it AFTER joining — it never
    # mirrored the existing feed. Here a joining relay PULLS the current state from its peers so it
    # catches up to the network. Heads (the feed) and signed release records (app updates) are the
    # load-bearing state and both have bulk GETs; the relay verifies neither (clients/node do — same
    # trust model as /push), so a peer can only fail to serve, never forge what we store.
    time.sleep(1.5)                                   # let bootstrap() populate `known` first
    peers = [r for r in list(known)
             if r != SELF and '127.0.0.1' not in r and 'localhost' not in r]
    # --- heads: newest-wins merge, identical rule to /push ---
    for r in peers:
        try:
            d = json.loads(urllib.request.urlopen(r + '/heads', timeout=8).read())
        except Exception:
            continue
        with _heads_lock:
            for h in d.get('heads', []):
                a = h.get('author')
                if not a:
                    continue
                cur = heads.get(a)
                if cur is None and len(heads) >= MAX_HEADS:
                    heads.pop(min(heads, key=lambda x: head_score(x, heads[x])), None)
                    cur = None
                if cur is None or h.get('seq', 0) > cur.get('seq', 0) \
                        or h.get('expires', 0) > cur.get('expires', 0):
                    heads[a] = h
    # --- releases: dedup by sig, then pull + pin each release's bytes so we can serve updates ---
    for r in peers:
        try:
            d = json.loads(urllib.request.urlopen(r + '/releases?pub=' + PUBLISHER_ACCT, timeout=8).read())
        except Exception:
            continue
        for m in d.get('records', []):
            accept_release(m)                         # verify (publisher-pinned sig) + store + pull bytes
    mark_dirty()                                      # persist the caught-up state

def grant_pin(cid, payhash):
    # PAY-TO-PIN: verify payhash is a confirmed Nano send TO this relay's account, then protect cid
    # from eviction for a span proportional to the amount. A public ledger read — no key needed, the
    # relay never moves funds; the PINNER paid. Each payment is consumed once (no double-claim).
    if xc is None or not RELAY_ACCT or not cid or not payhash or payhash in pins_paid:
        return 0
    try:
        bi = xc.rpc({'action': 'block_info', 'json_block': 'true', 'hash': payhash})
        c = bi.get('contents', {})
        to_us = (c.get('link_as_account') == RELAY_ACCT
                 or c.get('link', '').upper() == xc.nano_to_pub(RELAY_ACCT).upper())
        amt = int(bi.get('amount', '0'))
    except Exception:
        return 0
    if not to_us or amt <= 0:
        return 0
    pins_paid[payhash] = cid
    exp = max(pinned.get(cid, 0.0), time.time()) + amt * _PIN_S_PER_RAW
    pinned[cid] = exp
    mark_dirty()                         # persisted by the autosave within ≤5s (no per-write flush)
    return exp

# --- persistence: the WHOLE relay state survives a restart, not just heads ---
# (in-memory before this meant comments, uploaded media, likes, poll votes vanished on restart)
_STATE_KEYS = ('engage', 'notifs', 'supporters', 'follows', 'comments',   # blobs now live in SQLite
               'releases', 'profiles', 'dmkeys', 'dms', 'pollvotes', 'reports', 'pinned', 'pins_paid')

def _prune_loaded():
    # PRUNE-ON-LOAD. The per-table caps in the write handlers only bound NEW writes; state loaded from
    # disk is not capped on the way in, so a store that grew large under older (uncapped) code would
    # re-inflate RAM on every restart (this is what tipped the 512 MB node into an OOM on redeploy).
    # Applying the same ceilings here means the in-memory footprint is bounded by the caps regardless
    # of how big the file on disk got, and the next save() writes the smaller state back. (heads is left
    # to prune()/head_score, which trims it by on-chain value rather than insertion order.)
    _cap_dict(notifs, NOTIF_ACCTS)
    for a, lst in list(notifs.items()):
        if isinstance(lst, list) and len(lst) > NOTIF_MAX:
            notifs[a] = lst[-NOTIF_MAX:]
    _cap_dict(supporters, SUPPORTERS_MAX)
    _cap_dict(follows, FOLLOWS_MAX)
    for a, rec in list(follows.items()):
        fl = (rec or {}).get('follows')
        if isinstance(fl, list) and len(fl) > FOLLOW_LIST_MAX:
            rec['follows'] = fl[:FOLLOW_LIST_MAX]
    _cap_dict(profiles, PROFILES_MAX)
    _cap_dict(dmkeys, DMKEYS_MAX)
    _cap_dict(comments, COMMENT_POSTS_MAX)
    for pid, lst in list(comments.items()):
        if isinstance(lst, list) and len(lst) > COMMENTS_PER_POST:
            comments[pid] = lst[-COMMENTS_PER_POST:]
    _cap_dict(pollvotes, POLLS_MAX)
    for pid, votes in list(pollvotes.items()):
        if isinstance(votes, dict):
            _cap_dict(votes, POLL_VOTERS_MAX)
    _cap_dict(engage, ENGAGE_MAX)
    for pid, e in list(engage.items()):
        rs = (e or {}).get('resharers')
        if isinstance(rs, list) and len(rs) > RESHARERS_MAX:
            e['resharers'] = rs[:RESHARERS_MAX]
    _cap_dict(reports, REPORT_POSTS)
    for pid, recs in list(reports.items()):
        if isinstance(recs, dict):
            _cap_dict(recs, REPORT_PER_POST)
    _cap_dict(releases, RELEASE_PUBS_MAX)
    for pub, lst in list(releases.items()):
        if isinstance(lst, list) and len(lst) > 24:
            releases[pub] = lst[-24:]
    if len(dms) > DM_MAX:
        del dms[:-DM_MAX]

def load_state():
    global heads
    if not os.path.exists(STORE):
        return
    try:
        d = json.load(open(STORE))
        if isinstance(d, list):                      # legacy format: a bare list of heads
            heads = {h['author']: h for h in d}
            return
        heads = {h['author']: h for h in d.get('heads', [])}
        for k in _STATE_KEYS:
            v = d.get(k)
            g = globals()[k]                          # freshly-empty dict/list at import time
            if isinstance(g, dict) and isinstance(v, dict):
                g.update(v)
            elif isinstance(g, list) and isinstance(v, list):
                g.extend(v)
        for cid, b64 in (d.get('blobs') or {}).items():   # one-time migration: legacy in-JSON blobs -> SQLite
            if b64:
                blob_put(cid, b64)
        _prune_loaded()                              # bound the loaded state to the same caps as live writes
        mark_dirty()                                 # so the pruned (smaller) state is written back on next save
    except Exception:
        pass

def save():
    # atomic write of the full state (heads + everything else)
    state = {'heads': list(heads.values())}
    for k in _STATE_KEYS:
        state[k] = globals()[k]
    tmp = STORE + '.tmp'
    try:
        json.dump(state, open(tmp, 'w'))
        os.replace(tmp, STORE)
    except Exception:
        pass

load_state()
blob_load_meta()
for _m in dms:                                       # rebuild the DM dedup index from the loaded mailbox
    _dm_seen.add((_m.get('from'), _m.get('ts')))
for _pid, _recs in reports.items():                  # rebuild per-cid reporter weights -> blob penalty
    for _acc, _rec in (_recs or {}).items():
        _c = (_rec or {}).get('cid'); _rp = float((_rec or {}).get('rep', 0) or 0)
        if _c and _rp > 0:
            _blob_reporters.setdefault(_c, {})[_acc] = _rp
for _c, _s in _blob_reporters.items():
    if _c in blob_meta:
        blob_meta[_c]['reports'] = sum(_s.values())

def prune():
    # Actively DROP expired heads (not just hide them on read), so a Sybil flood can't grow `heads`
    # forever; enforce a hard author cap as a backstop; and forget idle rate-limit buckets. Returns
    # True if anything changed (so the autosave flushes).
    now = time.time()
    changed = False
    with _heads_lock:
        dead = [a for a, h in heads.items() if h.get('expires', 9e18) < now]
        for a in dead:
            heads.pop(a, None)
        if len(heads) > MAX_HEADS:                   # over the memory cap: keep the MOST VALUABLE heads
            keep = dict(sorted(heads.items(), key=lambda kv: head_score(kv[0], kv[1]),
                               reverse=True)[:MAX_HEADS])
            heads.clear(); heads.update(keep)
            changed = True
    changed = changed or bool(dead)
    with _rate_lock:
        for ip in [ip for ip, w in _rate.items() if now - w[0] >= RATE_WINDOW]:
            _rate.pop(ip, None)
    return changed

def _autosave():                                     # flush every few seconds so a restart loses ≤5s
    global _dirty
    while True:
        time.sleep(5)
        changed = prune()                            # expire heads / trim buckets each tick
        if _dirty or changed:                        # only rewrite state when something changed
            save(); _dirty = False
threading.Thread(target=_autosave, daemon=True).start()

def qs(path):
    return {k: v[0] for k, v in parse_qs(urlparse(path).query).items()}

def post_json(url, obj):
    try:
        urllib.request.urlopen(urllib.request.Request(url, json.dumps(obj).encode(),
                               {'Content-Type': 'application/json'}), timeout=3).read()
    except Exception:
        pass

def bootstrap():
    time.sleep(0.4)
    for bp in BOOTSTRAPS:
        known.add(bp)
        post_json(bp + '/relay_announce', {'url': SELF})   # tell the bootstrap we exist
        try:
            d = json.loads(urllib.request.urlopen(bp + '/relays', timeout=3).read())
            for u in d.get('relays', []):
                known.add(u)
        except Exception:
            pass

def live_heads():
    now = time.time()
    with _heads_lock:                                                     # snapshot; prune may be popping
        return [h for h in list(heads.values()) if h.get('expires', 9e18) >= now]   # drop expired pointers

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/heads'):
            self._send(200, json.dumps({'relay': PORT, 'heads': live_heads()}))
        elif self.path.startswith('/relays'):
            self._send(200, json.dumps({'relay': PORT, 'relays': sorted(known)}))
        elif self.path.startswith('/notify'):
            h = qs(self.path).get('handle', '')
            self._send(200, json.dumps({'relay': PORT, 'notifs': notifs.get(h, [])}))
        elif self.path.startswith('/supporters'):
            self._send(200, json.dumps({'relay': PORT, 'count': len(supporters),
                                        'accounts': list(supporters.keys())}))
        elif self.path.startswith('/blob'):
            cid = qs(self.path).get('cid', '')
            blob_touch(cid)                                             # a read is use → LRU keeps it longer
            self._send(200, json.dumps({'cid': cid, 'b64': blob_get(cid)}))   # serve cached content from disk
        elif self.path.startswith('/cache'):                           # cache health: size vs cap, pins
            now = time.time()
            self._send(200, json.dumps({'relay': PORT, 'blobs': len(blob_meta), 'bytes': _blob_total(),
                                        'cap': BLOB_CAP, 'pinned': sum(1 for e in pinned.values() if e > now)}))
        elif self.path.startswith('/haveblob'):
            cid = qs(self.path).get('cid', '')
            self._send(200, json.dumps({'cid': cid, 'have': blob_has(cid),
                                        'pinned_until': int(pinned.get(cid, 0)),
                                        'tips': (blob_meta.get(cid) or {}).get('tips', 0.0)}))
        elif self.path.startswith('/followers'):
            # count how many stored follow-records include this account (for a profile's follower tally)
            acc = qs(self.path).get('account', '')
            n = sum(1 for rec in follows.values() if acc in (rec.get('follows') or []))
            self._send(200, json.dumps({'account': acc, 'followers': n}))
        elif self.path.startswith('/reports'):
            # community moderation signal: post_id -> {account: signed report}. The relay stores and
            # serves; the NODE verifies signatures + counts distinct reporters (relay verifies nothing).
            self._send(200, json.dumps({'reports': reports}))
        elif self.path.startswith('/follows'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': follows.get(acc)}))
        elif self.path.startswith('/profile'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': profiles.get(acc)}))
        elif self.path.startswith('/dmkey'):
            acc = qs(self.path).get('account', '')
            self._send(200, json.dumps({'account': acc, 'record': dmkeys.get(acc)}))
        elif self.path.startswith('/pollvotes'):
            pid = qs(self.path).get('poll', '')
            self._send(200, json.dumps({'poll': pid, 'votes': list(pollvotes.get(pid, {}).values())}))
        elif self.path.startswith('/dm'):
            # every encrypted message this account is a party to (ciphertext only — relay can't read)
            acc = qs(self.path).get('account', '')
            mine = [m for m in dms if m.get('to') == acc or m.get('from') == acc]
            self._send(200, json.dumps({'account': acc, 'dms': mine}))
        elif self.path.startswith('/comments'):
            pid = qs(self.path).get('post', '')
            self._send(200, json.dumps({'post': pid, 'comments': comments.get(pid, [])}))
        elif self.path.startswith('/releases'):
            pub = qs(self.path).get('pub', '')
            self._send(200, json.dumps({'pub': pub, 'records': releases.get(pub, [])}))
        elif self.path.startswith('/engagement'):
            self._send(200, json.dumps({'relay': PORT, 'engage': engage}))
        elif self.path.startswith('/relayacct'):
            self._send(200, json.dumps({'port': PORT, 'account': RELAY_ACCT}))
        else:
            self._send(404, '{"error":"not found"}')
    def do_POST(self):
        # Real client IP for the throttle. A forwarded IP is trustworthy ONLY from Fly's edge or our own
        # loopback node proxy (kt_server on the same host); otherwise a remote client spoofs
        # X-Forwarded-For to dodge the throttle AND to bloat the _rate table with fake IPs. So trust the
        # header only in those cases; else fall back to the socket peer.
        peer = self.client_address[0]
        fly = self.headers.get('Fly-Client-IP')
        xff = self.headers.get('X-Forwarded-For', '').split(',')[0].strip()
        if fly:
            ip = fly
        elif xff and peer in ('127.0.0.1', '::1'):   # forwarded by our own loopback node proxy
            ip = xff
        else:
            ip = peer
        if not rate_ok(ip):                          # per-IP write throttle — first line against a flood
            self._send(429, '{"ok":false,"error":"rate limited"}'); return
        # Bound the request body. Records are tiny; only /blob carries large (content-addressed) bytes.
        limit = MAX_BLOB if self.path.startswith('/blob') else MAX_BODY
        try:
            n = int(self.headers.get('Content-Length', 0) or 0)
        except ValueError:
            self._send(400, '{"ok":false,"error":"bad content-length"}'); return
        if n < 0 or n > limit:
            self._send(413, '{"ok":false,"error":"body too large"}'); return
        raw = self.rfile.read(n) if n else b'{}'
        mark_dirty()                                 # any accepted write flushes within ≤5s (see _autosave)
        if self.path.startswith('/push'):
            try:
                h = json.loads(raw)
                now = time.time()
                # Clamp ONLY a head claiming a too-far-future expiry (anti-eternal-head). Crucially,
                # leave an in-bounds head's `expires` BYTE-IDENTICAL: the author signed over
                # "account|seq|cid|expires", so rewriting it (even int->float) would break that
                # signature and make clients reject the head. A clamped (bogus) head's signature won't
                # verify either — which is the point: it's stored bounded, gets pruned, and never renders.
                maxexp = now + HEAD_TTL + HEAD_SKEW
                if float(h.get('expires', 0)) > maxexp:
                    h['expires'] = int(maxexp)
                with _heads_lock:
                    cur = heads.get(h['author'])
                    if cur is None and len(heads) >= MAX_HEADS:
                        # at the memory cap: make room by dropping the LEAST-VALUABLE head. Its value
                        # (tips - reports) is <= a new post's floor, so a tipped post is never displaced
                        # by a newcomer; only untipped/spam churns — memory, not a clock, is the limit.
                        victim = min(heads, key=lambda a: head_score(a, heads[a]))
                        heads.pop(victim, None)
                    if cur is None or h.get('seq', 0) > cur.get('seq', 0) or h['expires'] > cur.get('expires', 0):
                        heads[h['author']] = h                                   # newer seq OR fresher TTL
                        resp = '{"ok":true,"accepted":true}'
                    else:
                        resp = '{"ok":true,"accepted":false,"reason":"stale"}'
                self._send(200, resp)
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/relay_announce'):
            try:
                u = json.loads(raw).get('url', '')
                if u and u != SELF and len(u) <= FIELD_MAX and len(known) < KNOWN_MAX:
                    known.add(u)
                self._send(200, json.dumps({'ok': True, 'relays': sorted(known)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/notify_push'):
            try:
                m = json.loads(raw); to = m['to']
                if to in notifs or len(notifs) < NOTIF_ACCTS:            # cap distinct recipients
                    lst = notifs.setdefault(to, [])
                    lst.append({'from': m.get('from', ''), 'text': m.get('text', ''),
                                'ts': m.get('ts', 0), 'kind': m.get('kind', 'mention')})
                    del lst[:-NOTIF_MAX]                                 # keep only the most recent N
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/supporter'):
            try:
                m = json.loads(raw); acc = m['account']
                if m.get('on'):
                    supporters[acc] = m.get('ts', 0)
                    _cap_dict(supporters, SUPPORTERS_MAX)
                else:
                    supporters.pop(acc, None)
                self._send(200, json.dumps({'ok': True, 'count': len(supporters)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/blob'):
            # a supporter caches content here (content-addressed — cid names the bytes); byte-capped + LRU
            try:
                m = json.loads(raw); cid = m['cid']; new = not blob_has(cid)
                if not blob_put(cid, m['b64'], tips=m.get('tips', 0)):   # oversized/empty rejected pre-store
                    self._send(413, json.dumps({'ok': False, 'error': 'blob too large', 'max': MAX_BLOB})); return
                self._send(200, json.dumps({'ok': True, 'stored': new, 'cache_bytes': _blob_total()}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/pin'):
            # PAY-TO-PIN: {cid, payhash} — protect cid from eviction, paid for by a Nano send to this relay
            try:
                m = json.loads(raw or '{}')
                cid = m.get('cid') or qs(self.path).get('cid', '')
                payhash = m.get('payhash') or qs(self.path).get('payhash', '')
                exp = grant_pin(cid, payhash)
                if exp:
                    self._send(200, json.dumps({'ok': True, 'cid': cid, 'pinned_until': int(exp),
                                                'days': round((exp - time.time()) / 86400, 2)}))
                else:
                    self._send(402, json.dumps({'ok': False, 'pay_to': RELAY_ACCT,
                                                'rate_days_per_xno': PIN_DAYS_PER_XNO,
                                                'error': 'no unconsumed confirmed payment to this relay for that cid'}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/follows'):
            # signed follow-list record, keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = follows.get(acc)
                if isinstance(m.get('follows'), list) and len(m['follows']) > FOLLOW_LIST_MAX:
                    self._send(413, '{"ok":false,"error":"follow list too large"}'); return
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    follows[acc] = m
                    _cap_dict(follows, FOLLOWS_MAX)
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/profile'):
            # signed profile record (display name, bio, avatar/banner CIDs), keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = profiles.get(acc)
                if any(len(str(m.get(k, ''))) > FIELD_MAX for k in ('display', 'bio', 'avatar', 'banner')):
                    self._send(413, '{"ok":false,"error":"profile field too large"}'); return
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    profiles[acc] = m
                    _cap_dict(profiles, PROFILES_MAX)
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/dmkey'):
            # signed X25519 DM public-key record, keyed by account, highest ts wins
            try:
                m = json.loads(raw); acc = m['account']; cur = dmkeys.get(acc)
                if cur is None or m.get('ts', 0) > cur.get('ts', 0):
                    dmkeys[acc] = m
                    _cap_dict(dmkeys, DMKEYS_MAX)
                self._send(200, '{"ok":true}')
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/pollvote'):
            # one signed vote per account per poll; latest ts wins (lets a voter change their choice)
            try:
                m = json.loads(raw); pid = m['poll_id']; acc = m['account']
                votes = pollvotes.setdefault(pid, {})
                _cap_dict(pollvotes, POLLS_MAX)
                if acc in votes or len(votes) < POLL_VOTERS_MAX:
                    if acc not in votes or m.get('ts', 0) >= votes[acc].get('ts', 0):
                        votes[acc] = m
                self._send(200, json.dumps({'ok': True, 'total': len(votes)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/dm'):
            # store an encrypted DM (O(1) dedup by (from, ts)). The relay only holds ciphertext, and
            # the mailbox is a bounded ring — oldest ciphertext drops once it's past DM_MAX.
            try:
                m = json.loads(raw); key = (m.get('from'), m.get('ts'))
                if key not in _dm_seen:
                    _dm_seen.add(key); dms.append(m)
                    if len(dms) > DM_MAX:                                # bounded: evict oldest
                        for x in dms[:-DM_MAX]:
                            _dm_seen.discard((x.get('from'), x.get('ts')))
                        del dms[:-DM_MAX]
                self._send(200, json.dumps({'ok': True, 'stored': len(dms)}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path.startswith('/release'):
            # Signed release records (app updates). Unlike other writes, the relay VERIFIES here: the
            # record must carry the PINNED publisher's signature (see accept_release). This drops forged
            # records at the door, so an attacker can no longer flood ≥24 fakes to evict the genuine
            # update (a network-wide freeze) or amplify the background blob-pull with junk.
            try:
                m = json.loads(raw)
                stored = accept_release(m)
                pub = m.get('publisher', '')
                self._send(200, json.dumps({'ok': True, 'accepted': stored,
                                            'stored': len(releases.get(pub, []))}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/report'):
            # a signed community report {post_id, account, ts, sig, pub, cid?}. Moderation has real
            # consequences (a takedown), so unlike other writes the relay VERIFIES the signature +
            # key↔author binding here — otherwise a spoofer could attribute weight to a high-reputation
            # account that never reported. One per account per post; weighted by the reporter's on-chain
            # reputation (snapshot stored so a restart needs no re-RPC).
            try:
                m = json.loads(raw); pid = m['post_id']; acc = m['account']
                pub, sig, ts = m.get('pub', ''), m.get('sig', ''), m.get('ts', 0)
                if xc is None or xc.pub_to_addr(pub) != acc \
                        or not xc.verify_msg(pub, 'report|%s|%s|%s' % (acc, pid, ts), sig):
                    self._send(400, json.dumps({'ok': False, 'error': 'bad report signature'})); return
                recs = reports.setdefault(pid, {})
                fresh = acc not in recs and (pid in reports or len(reports) <= REPORT_POSTS) and len(recs) < REPORT_PER_POST
                if fresh:
                    rep = xc.account_rep(acc)                   # Sybil-resistant weight (0 for a throwaway)
                    recs[acc] = {'ts': ts, 'sig': sig, 'pub': pub, 'cid': m.get('cid', ''), 'rep': rep}
                    blob_report(m.get('cid', ''), acc, rep)     # penalise + maybe take down the media
                self._send(200, json.dumps({'ok': True, 'reports': len(recs)}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/comment'):
            # a signed off-chain reply. Stored under its parent post; dedup by (account, ts).
            # Verification (sig + pub↔account) happens client-side on fetch, like /follows.
            try:
                m = json.loads(raw); pid = m['post_id']
                if len(str(m.get('text', ''))) > FIELD_MAX:
                    self._send(413, '{"ok":false,"error":"comment too large"}'); return
                lst = comments.setdefault(pid, [])
                _cap_dict(comments, COMMENT_POSTS_MAX)
                key = (m.get('account'), m.get('ts'))
                if len(lst) < COMMENTS_PER_POST and not any((c.get('account'), c.get('ts')) == key for c in lst):
                    lst.append(m)
                self._send(200, json.dumps({'ok': True, 'count': len(lst)}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/like'):
            try:
                m = json.loads(raw); e = engage_for(m['post_id'])
                e['likes'] = max(0, e.get('likes', 0) + int(m.get('delta', 1)))
                self._send(200, json.dumps({'ok': True, 'likes': e['likes']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/repost'):
            # A reshare is MONEY-BEARING: the earliest resharer of a post earns a slice (the reposter
            # split) of every tip to it. So the relay VERIFIES a SIGNED reshare event here — otherwise an
            # attacker POSTs an unsigned reshare naming their own account, pre-registers as "first
            # resharer" of a popular post, and skims real XNO from every tipper. canon: reshare|account|post_id|ts.
            try:
                m = json.loads(raw); pid = m['post_id']; acc = m.get('account')
                ts, pub, sig = m.get('ts', 0), m.get('pub', ''), m.get('sig', '')
                if not (acc and xc is not None and xc.pub_to_addr(pub) == acc
                        and xc.verify_msg(pub, 'reshare|%s|%s|%s' % (acc, pid, ts), sig)):
                    self._send(400, json.dumps({'ok': False, 'error': 'bad reshare signature'})); return
                e = engage_for(pid); delta = int(m.get('delta', 1))
                e['reposts'] = max(0, e.get('reposts', 0) + delta)
                rs = e.setdefault('resharers', [])            # earliest-first, so tips can reward the spreader
                if delta > 0 and acc not in rs and len(rs) < RESHARERS_MAX:
                    rs.append(acc)
                elif delta < 0 and acc in rs:
                    rs.remove(acc)
                self._send(200, json.dumps({'ok': True, 'reposts': e['reposts'], 'resharers': rs}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/tipstat'):
            try:
                m = json.loads(raw); e = engage_for(m['post_id'])
                e['tips_raw'] += int(m.get('raw', 0))
                self._send(200, json.dumps({'ok': True, 'tips_raw': e['tips_raw']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        elif self.path.startswith('/view'):
            # impression counter for a post or comment cid (client dedups one view per session)
            try:
                m = json.loads(raw); e = engage_for(m['post_id'])
                e['views'] = e.get('views', 0) + int(m.get('delta', 1))
                self._send(200, json.dumps({'ok': True, 'views': e['views']}))
            except Exception as ex:
                self._send(400, json.dumps({'ok': False, 'error': str(ex)}))
        else:
            self._send(404, '{"error":"not found"}')

if BOOTSTRAPS:
    threading.Thread(target=bootstrap, daemon=True).start()
    threading.Thread(target=backfill, daemon=True).start()         # pull peers' heads + releases so a joining relay mirrors the net
threading.Thread(target=sync_release_blobs, daemon=True).start()   # catch up on any release bytes we're missing
ThreadingHTTPServer((BIND, PORT), H).serve_forever()
