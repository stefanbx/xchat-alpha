#!/usr/bin/env python3
"""The feed must never make a client wait on aggregation when a cache already exists.

The cold feed used to cost 3-8s. The aggregation (a full relay fan-out, a burst of ~0.66s reputation
RPCs, a cold IPFS content fetch) was written to /tmp, which every redeploy/reboot wipes — so the FIRST
request after each deploy found no cache and BLOCKED on rebuilding it from nothing. Worse, even once a
cache existed, the warm refresh ran the aggregation INLINE via a blocking subprocess.run, so one
unlucky request per window still ate the whole thing.

Two changes, tested here:
  1. The feed cache path is env-driven (XC_FEED_CACHE), so a deploy can put it on a PERSISTENT volume.
     A restart then finds the last aggregation still there instead of a cold void.
  2. When a cache exists, api_feed SERVES IT INSTANTLY and refreshes on a BACKGROUND THREAD. No request
     ever blocks on aggregation once there is anything to show. Only the genuine first-ever boot (no
     cache anywhere) still blocks once, so the very first feed is never empty.

This drives the REAL kt_server.api_feed with a stubbed (slow) aggregation and asserts on wall-clock:
the cold call waits for the build, every warm call returns in a blink while the rebuild runs behind it.

    python3 test/feed_cold_start_test.py
"""
import json, os, re, sys, tempfile, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, 'backend')

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


# ---- behavioural: drive the real api_feed with a slow stub aggregation --------------------------
CACHE = os.path.join(tempfile.mkdtemp(prefix='xc_feedcache_'), 'feed_agg.json')
os.environ['XC_FEED_CACHE'] = CACHE          # MUST be set before xc_common is imported (it reads it once)
os.environ.setdefault('XC_ISOLATE', '1')
sys.path.insert(0, BACKEND)
import kt_server as k                          # noqa: E402
import xc_common as xc                         # noqa: E402

check(xc.FEED_CACHE == CACHE, 'the feed cache path honours XC_FEED_CACHE (so it can live on a volume)',
      f'{xc.FEED_CACHE!r}')

SLOW = 1.5                                     # the stubbed aggregation takes this long to "rebuild"
_spawns = []


def _posts(tag):
    return {'posts': [{'id': tag, 'ts': 1786900000, 'author': 'nano_1a', 'body': tag}]}


def make_stub(tag):
    """A stand-in for spawn('xc_feed.py'): sleeps like a real aggregation, then writes the cache."""
    def _stub(script, *a, **kw):
        _spawns.append((script, time.time()))
        time.sleep(SLOW)
        tmp = CACHE + '.tmp'
        open(tmp, 'w').write(json.dumps(_posts(tag)))
        os.replace(tmp, CACHE)
    return _stub


def served_ids(query=None):
    out = json.loads(k.api_feed(query))
    return [p['id'] for p in out['content'].get('posts', [])]


# --- 1) COLD: no cache anywhere -> the one first request BLOCKS and builds it ---------------------
print('--- cold start: no cache anywhere ---')
if os.path.exists(CACHE):
    os.remove(CACHE)
k._feed_ts[0] = 0.0
k.spawn = make_stub('COLD')
t0 = time.time()
ids = served_ids()
dt = time.time() - t0
check(dt >= SLOW * 0.9, f'the first-ever feed BLOCKS to build the cache ({dt:.1f}s) — never serves empty',
      f'{dt:.2f}s')
check(ids == ['COLD'], 'and it returns the freshly built feed', str(ids))

# --- 2) WARM-STALE: a persisted cache exists, fresh process (freshness clock at 0, as after restart)
#         -> serve the persisted cache INSTANTLY, rebuild on a background thread -------------------
print('\n--- restart: persisted-but-stale cache present, in-memory clock reset ---')
open(CACHE, 'w').write(json.dumps(_posts('PERSISTED')))    # what survived the redeploy
k._feed_ts[0] = 0.0                                        # fresh process: nothing refreshed yet this run
_spawns.clear()
k.spawn = make_stub('REBUILT')
t0 = time.time()
ids = served_ids()
dt = time.time() - t0
check(dt < SLOW * 0.5, f'the request after a restart serves the persisted cache INSTANTLY ({dt:.2f}s)',
      f'{dt:.2f}s — must not block on the rebuild')
check(ids == ['PERSISTED'], 'and it serves the persisted feed, not an empty one, while it rebuilds',
      str(ids))
check(len(_spawns) == 1, 'exactly one background rebuild was kicked off', f'{len(_spawns)} spawns')

# the background rebuild lands a beat later and the lock frees
time.sleep(SLOW + 0.5)
check(served_ids() == ['REBUILT'], 'the background rebuild replaces the cache for the next poll',
      str(served_ids()))
check(k._feed_lock.acquire(blocking=False), 'the background refresh releases the feed lock when done')
k._feed_lock.release()

# --- 3) WARM-FRESH: cache exists and was just refreshed -> no rebuild at all, still instant -------
print('\n--- steady warm: cache fresh within TTL ---')
open(CACHE, 'w').write(json.dumps(_posts('FRESH')))
k._feed_ts[0] = time.time()                                # refreshed just now
_spawns.clear()
k.spawn = make_stub('SHOULD_NOT_RUN')
t0 = time.time()
ids = served_ids()
dt = time.time() - t0
check(dt < SLOW * 0.5 and ids == ['FRESH'], f'a fresh warm feed serves instantly ({dt:.2f}s)', str(ids))
check(len(_spawns) == 0, 'and does NOT re-aggregate inside the TTL window', f'{len(_spawns)} spawns')

# ---- source guards: everyone shares the one path, and deploys point it at persistent storage -----
print('\n--- source: all consumers use xc.FEED_CACHE; deploys persist the caches ---')
feed_src = open(os.path.join(BACKEND, 'xc_feed.py')).read()
labels_src = open(os.path.join(BACKEND, 'xc_labels.py')).read()
check('xc.FEED_CACHE' in feed_src and '/tmp/xc_feed_agg.json' not in feed_src,
      'xc_feed.py writes the aggregation to xc.FEED_CACHE (not a hardcoded /tmp path)')
check('xc.FEED_CACHE' in labels_src and '/tmp/xc_feed_agg.json' not in labels_src,
      'xc_labels.py reads the same xc.FEED_CACHE')

entry = open(os.path.join(REPO, 'deploy', 'entrypoint.sh')).read()
for var, where in [('XC_FEED_CACHE', 'the feed aggregation'),
                   ('XC_CONTENT_CACHE', 'post content'),
                   ('XC_REP_CACHE', 'reputation')]:
    check(re.search(rf'export {var}="\$STORE_DIR/', entry) is not None,
          f'the Fly node persists {where} cache on the /data volume ({var})')

run = open(os.path.join(REPO, 'relay', 'install-relay.sh')).read()
for var in ('XC_FEED_CACHE', 'XC_CONTENT_CACHE', 'XC_REP_CACHE'):
    check(re.search(rf'export {var}="\$\{{{var}:-\$XC_HOME/', run) is not None,
          f'an operator relay persists its {var} under XC_HOME (survives reboot)')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
