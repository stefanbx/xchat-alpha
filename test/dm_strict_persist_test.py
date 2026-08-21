#!/usr/bin/env python3
# Strict oldest-across-all global DM_MAX eviction + persistence round-trip. The global ceiling sheds the
# GLOBALLY oldest record (arrival order via _dm_order), NOT the largest bucket's oldest; on disk the
# mailbox stays a FLAT `dms` list so an OLDER relay can still read a store this build wrote, and a reboot
# re-buckets it with order + dedup index rebuilt intact.
import json, os, sys, time, subprocess, urllib.request, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY = os.path.join(REPO, 'relay', 'xc_relayd.py')
store = tempfile.mktemp(suffix='.json')

def boot(port, env_extra):
    # XC_ISOLATE/empty bootstrap: never reach the live relay mesh, even run standalone.
    env = dict(os.environ, BIND_HOST='127.0.0.1', XC_ISOLATE='1', XC_BOOTSTRAP='', **env_extra)
    p = subprocess.Popen([sys.executable, RELAY, str(port), store], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.3)
    return p

def post(base, to, mid, ts):
    body = json.dumps({'to': to, 'mid': mid, 'ts': ts, 'ct': 'x'}).encode()
    urllib.request.urlopen(urllib.request.Request(base + '/dm', body,
        {'Content-Type': 'application/json'}), timeout=4).read()

def read(base, acc):
    return json.loads(urllib.request.urlopen(base + '/dm?account=' + acc, timeout=4).read()).get('dms', [])

fail = 0
def check(name, cond):
    global fail
    print(("PASS" if cond else "FAIL"), name); fail += (0 if cond else 1)

# DM_MAX=4, per-acct/distinct high so ONLY the global strict-oldest path fires.
p = boot(7752, dict(XC_DM_MAX='4', XC_DM_PER_ACCT='100', XC_DM_ACCTS='100'))
B = 'http://127.0.0.1:7752'
try:
    # arrival order across accounts: A1, B1, A2, C1  (total 4, at cap)
    post(B, 'nano_A', 'A1', 1); post(B, 'nano_B', 'B1', 2)
    post(B, 'nano_A', 'A2', 3); post(B, 'nano_C', 'C1', 4)
    # one more -> evict GLOBAL oldest = A1 (belongs to A, not the biggest bucket)
    post(B, 'nano_B', 'B2', 5)
    a = {m['mid'] for m in read(B, 'nano_A')}
    check("strict-oldest: A1 (global oldest) evicted, A2 kept", a == {'A2'})
    check("strict-oldest: B untouched (B1,B2)", {m['mid'] for m in read(B, 'nano_B')} == {'B1', 'B2'})
    check("strict-oldest: C1 kept", {m['mid'] for m in read(B, 'nano_C')} == {'C1'})
    # next -> evict next global oldest = B1
    post(B, 'nano_A', 'A3', 6)
    check("strict-oldest: B1 (now oldest) evicted", {m['mid'] for m in read(B, 'nano_B')} == {'B2'})
    total = sum(len(read(B, x)) for x in ('nano_A', 'nano_B', 'nano_C'))
    check("global cap holds: total == DM_MAX (4)", total == 4)
    time.sleep(6)  # let autosave flush to disk
finally:
    p.terminate()
    try: p.wait(timeout=5)
    except Exception: p.kill()

# On-disk format: flat `dms` list (older relays can read it)
disk = json.load(open(store))
check("persist: on-disk `dms` is a flat list", isinstance(disk.get('dms'), list))
check("persist: no `dms_by_to` on disk", 'dms_by_to' not in disk)
check("persist: flat list holds exactly the 4 live records",
      {m['mid'] for m in disk.get('dms', [])} == {'A2', 'C1', 'B2', 'A3'})

# Reboot from the SAME store -> reload + re-bucket, contents intact
p2 = boot(7753, dict(XC_DM_MAX='4', XC_DM_PER_ACCT='100', XC_DM_ACCTS='100'))
B2 = 'http://127.0.0.1:7753'
try:
    survivors = {m['mid'] for x in ('nano_A', 'nano_B', 'nano_C') for m in read(B2, x)}
    check("reboot: all 4 survivors reloaded", survivors == {'A2', 'C1', 'B2', 'A3'})
    # dedup index rebuilt: re-posting a survivor mid is a no-op
    before = len(read(B2, 'nano_A'))
    post(B2, 'nano_A', 'A2', 3)
    check("reboot: dedup index rebuilt (dupe ignored)", len(read(B2, 'nano_A')) == before)
finally:
    p2.terminate()
    try: p2.wait(timeout=5)
    except Exception: p2.kill()
    os.remove(store)

print("\nRESULT:", "ALL PASS" if fail == 0 else f"{fail} FAILED")
sys.exit(1 if fail else 0)
