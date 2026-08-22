#!/usr/bin/env python3
# Engagement across relays: likes / reposts / tips / views per post. Writes are pushed to every relay;
# reads aggregate (max per post, since relays converge). Exposed as importable functions so the node
# calls them IN-PROCESS (no subprocess spawn, no /tmp round-trip, and it reuses the node's warm caches);
# a thin CLI wrapper stays for backward compatibility / standalone use.
import json, os, sys, urllib.request
import importlib.util
from concurrent.futures import ThreadPoolExecutor
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)


def _relays():
    return xc.discover_relays()                      # cached (onchain 120s + parallel BFS); cheap per call

def post(path, obj, relays=None):
    for r in (relays or _relays()):
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
        except Exception:
            pass

# ---- writes (fire-and-forget to every relay) --------------------------------------------------------
def like(post_id, delta):
    post('/like', {'post_id': post_id, 'delta': int(delta)})
    return {"ok": True}

def react(post_id, emoji, delta):
    # Per-emoji reaction counters, in the same DISPLAY-counter class as likes (unsigned, anyone can bump).
    post('/react', {'post_id': post_id, 'emoji': str(emoji), 'delta': int(delta)})
    return {"ok": True}

def repost(rec):
    # rec is the app-SIGNED reshare record {post_id, delta, account, ts, sig, pub}; the relay verifies the
    # signature before crediting a resharer (a reshare earns a tip split), so the node only forwards it.
    ok = bool(rec.get('sig') and rec.get('pub') and rec.get('account'))
    if ok:
        post('/repost', rec)
    return {"ok": ok}

def tip(post_id, raw, payhash='', cid=''):
    body = {'post_id': post_id, 'raw': int(raw)}
    if payhash and cid:                    # verified credit: the relay checks the send on-chain
        body.update({'payhash': payhash, 'cid': cid})
    post('/tipstat', body)
    return {"ok": True}

def view(post_id, delta):
    post('/view', {'post_id': post_id, 'delta': int(delta)})
    return {"ok": True}

def notify(payload):
    post('/notify_push', payload)
    return {"ok": True}

# ---- read (aggregate engagement across relays) ------------------------------------------------------
def get():
    relays = _relays()
    def _fetch(r):
        try:
            return json.loads(urllib.request.urlopen(r + '/engagement', timeout=4).read()).get('engage', {})
        except Exception:
            return None
    agg = {}
    if relays:                                        # PARALLEL fan-out (engagement is polled/hot)
        with ThreadPoolExecutor(max_workers=min(16, len(relays))) as ex:
            results = list(ex.map(_fetch, relays))
    else:
        results = []
    for e in results:
        if not e:
            continue
        for pid, v in e.items():
            a = agg.setdefault(pid, {'likes': 0, 'tips_raw': 0, 'reposts': 0, 'views': 0, 'resharers': [], 'reactions': {}})
            a['likes'] = max(a['likes'], v.get('likes', 0))
            a['tips_raw'] = max(a['tips_raw'], v.get('tips_raw', 0))
            a['reposts'] = max(a['reposts'], v.get('reposts', 0))
            a['views'] = max(a['views'], v.get('views', 0))
            for emo, cnt in (v.get('reactions') or {}).items():
                a['reactions'][emo] = max(a['reactions'].get(emo, 0), int(cnt))
            for who in (v.get('resharers') or []):     # union, earliest-first preserved
                if who not in a['resharers']:
                    a['resharers'].append(who)
    for pid, a in agg.items():
        a['tips_xno'] = a['tips_raw'] / 1e30           # float (raw would overflow the client's 64-bit int)
    return {"ok": True, "engage": agg}


def _rd(p):
    try:
        return open(p).read().strip()
    except Exception:
        return ''

if __name__ == '__main__':                             # CLI compat (standalone / tests). Node calls the funcs.
    mode = sys.argv[1] if len(sys.argv) > 1 else 'get'
    if mode == 'notify':
        import time
        res = notify({'to': _rd('/tmp/xc_np_to.txt'), 'from': _rd('/tmp/xc_np_from.txt'),
                      'kind': _rd('/tmp/xc_np_kind.txt'), 'text': _rd('/tmp/xc_np_text.txt'), 'ts': int(time.time())})
    elif mode == 'like':
        res = like(sys.argv[2], sys.argv[3])
    elif mode == 'repost':
        try:
            rec = json.load(open('/tmp/xc_reshare_rec.json'))
        except Exception:
            rec = {}
        res = repost(rec)
    elif mode == 'tip':
        res = tip(sys.argv[2], sys.argv[3])
    elif mode == 'view':
        res = view(sys.argv[2], sys.argv[3])
    else:
        res = get()
    json.dump(res, open('/tmp/xc_engage_result.json', 'w'))
