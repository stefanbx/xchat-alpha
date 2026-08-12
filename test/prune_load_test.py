#!/usr/bin/env python3
# Verify prune-on-load: a store that grew large under old (uncapped) code is trimmed to the caps when
# the relay loads it, and the smaller state is written back to disk.
import json, os, sys, time, subprocess, urllib.request, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY = os.path.join(REPO, 'relay', 'xc_relayd.py')

# A bloated store: 5 supporters, one post with 5 comments, one poll with 5 voters, engagement with 5 resharers.
store = tempfile.mktemp(suffix='.json')
bloated = {
    'heads': [],
    'supporters': {f'nano_sup{i}': i for i in range(5)},
    'comments': {'p1': [{'account': f'nano_c{i}', 'ts': i, 'text': 'x'} for i in range(5)]},
    'pollvotes': {'poll1': {f'nano_v{i}': {'account': f'nano_v{i}', 'ts': i} for i in range(5)}},
    'engage': {'p1': {'likes': 0, 'tips_raw': 0, 'reposts': 5,
                      'resharers': [f'nano_r{i}' for i in range(5)]}},
}
json.dump(bloated, open(store, 'w'))
before = len(json.dumps(bloated))

PORT = 7739
# caps small so the loaded state is over them
env = dict(os.environ, BIND_HOST='127.0.0.1',
           XC_SUPPORTERS_MAX='2', XC_COMMENTS_PER_POST='2',
           XC_POLL_VOTERS_MAX='2', XC_RESHARERS_MAX='2')
proc = subprocess.Popen([sys.executable, RELAY, str(PORT), store], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
BASE = f'http://127.0.0.1:{PORT}'
time.sleep(1.2)

def get(path):
    return json.loads(urllib.request.urlopen(BASE + path, timeout=5).read())

passed = failed = 0
def check(name, ok, detail=''):
    global passed, failed
    if ok: passed += 1; print(f'  PASS  {name}')
    else:  failed += 1; print(f'  FAIL  {name}  {detail}')

try:
    sup = get('/supporters')
    check('supporters pruned to cap on load', sup['count'] == 2, sup['count'])
    com = get('/comments?post=p1')
    check('comments-per-post pruned on load', len(com['comments']) == 2, len(com['comments']))
    pv = get('/pollvotes?poll=poll1')
    check('poll voters pruned on load', len(pv['votes']) == 2, len(pv['votes']))
    eng = get('/engagement')['engage'].get('p1', {})
    check('resharers pruned on load', len(eng.get('resharers', [])) == 2, eng.get('resharers'))

    # the pruned (smaller) state is written back within the 5s autosave
    time.sleep(6)
    after = len(open(store).read())
    check('store shrank on disk after prune+save', after < before, f'{before} -> {after}')
finally:
    proc.terminate()
    for p in (store, os.path.join(os.path.dirname(store), 'blobs.db')):
        try: os.remove(p)
        except Exception: pass

print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
