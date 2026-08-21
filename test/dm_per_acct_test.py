#!/usr/bin/env python3
# Per-recipient DM caps: legacy-flat migration, DM_PER_ACCT fairness, dedup, per-mailbox independence.
# The relay buckets DMs by RECIPIENT (dms_by_to) so a chatty mailbox evicts only its OWN oldest — one
# busy pair can no longer flush everyone else's unread out of a shared global ring. See _dm_store.
import json, os, sys, time, subprocess, urllib.request, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY = os.path.join(REPO, 'relay', 'xc_relayd.py')

store = tempfile.mktemp(suffix='.json')
# LEGACY flat `dms` list on disk (older build format) -> must migrate to per-recipient buckets on load.
legacy = {
    'heads': [],
    'dms': [
        {'to': 'nano_A', 'mid': 'legA1', 'ts': 1, 'ct': 'x'},
        {'to': 'nano_A', 'mid': 'legA2', 'ts': 2, 'ct': 'x'},
        {'to': 'nano_B', 'mid': 'legB1', 'ts': 1, 'ct': 'x'},
    ],
}
json.dump(legacy, open(store, 'w'))

PORT = 7748
# XC_ISOLATE/empty bootstrap: never touch the live relay mesh, even when run standalone (run_tests.py
# sets XC_ISOLATE too, but a bare `python3 test/dm_per_acct_test.py` must be safe on its own).
env = dict(os.environ, BIND_HOST='127.0.0.1', XC_ISOLATE='1', XC_BOOTSTRAP='',
           XC_DM_PER_ACCT='3', XC_DM_ACCTS='100', XC_DM_MAX='1000')
proc = subprocess.Popen([sys.executable, RELAY, str(PORT), store], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
BASE = f'http://127.0.0.1:{PORT}'
time.sleep(1.3)

def post_dm(to, mid, ts):
    body = json.dumps({'to': to, 'mid': mid, 'ts': ts, 'ct': 'x'}).encode()
    r = urllib.request.urlopen(urllib.request.Request(BASE + '/dm', body,
        {'Content-Type': 'application/json'}), timeout=4).read()
    return json.loads(r)

def read(acc):
    r = urllib.request.urlopen(BASE + '/dm?account=' + acc, timeout=4).read()
    return json.loads(r).get('dms', [])

fail = 0
def check(name, cond):
    global fail
    print(("PASS" if cond else "FAIL"), name)
    if not cond: fail += 1

try:
    # 1) migration: legacy flat list is readable per-recipient
    a, b = read('nano_A'), read('nano_B')
    check("migrate: A has 2 legacy msgs", len(a) == 2)
    check("migrate: B has 1 legacy msg",  len(b) == 1)
    check("migrate: bodies intact",       {m['mid'] for m in a} == {'legA1', 'legA2'})

    # 2) per-account fairness: flood A past DM_PER_ACCT=3; B must be untouched
    for i in range(6):
        post_dm('nano_A', f'A{i}', 100 + i)
    a, b = read('nano_A'), read('nano_B')
    check("per-acct: A capped at DM_PER_ACCT=3", len(a) == 3)
    check("per-acct: A kept the NEWEST 3",       {m['mid'] for m in a} == {'A3', 'A4', 'A5'})
    check("per-acct: B NOT evicted by A's flood", len(b) == 1)

    # 3) dedup unchanged: re-post an existing mid is a no-op
    before = len(read('nano_A'))
    post_dm('nano_A', 'A5', 105)
    check("dedup: duplicate mid ignored", len(read('nano_A')) == before)

    # 4) independence: B has its own cap budget
    for i in range(3):
        post_dm('nano_B', f'B{i}', 200 + i)
    check("independence: B holds its own 3 (cap)", len(read('nano_B')) == 3)
finally:
    proc.terminate()
    try: proc.wait(timeout=5)
    except Exception: proc.kill()
    os.remove(store)

print("\nRESULT:", "ALL PASS" if fail == 0 else f"{fail} FAILED")
sys.exit(1 if fail else 0)
