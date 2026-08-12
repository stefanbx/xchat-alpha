#!/usr/bin/env python3
# Smoke test for the security hardening: signed reshares, release verification (suppression fix),
# body/blob size caps, and local block verification. Starts a real relay and exercises the new checks.
import json, os, sys, time, subprocess, urllib.request, importlib.util, tempfile, base64, hashlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, 'backend')
RELAY = os.path.join(REPO, 'relay', 'xc_relayd.py')

spec = importlib.util.spec_from_file_location('xc', os.path.join(BACKEND, 'xc_common.py'))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

# a test identity we control (publisher + a normal user)
PUB_KEY = xc.keyof(0x71); PUB_ACCT = xc.derive(PUB_KEY)[0]
USR_KEY = xc.keyof(0x72); USR_ACCT = xc.derive(USR_KEY)[0]

def sign_msg(key, msg):
    lines = xc._sign_lines(key, msg)  # ['sig <hex>', 'pub <hex>']
    d = {l.split(' ')[0]: l.split(' ')[1] for l in lines}
    return d['sig'], d['pub']

PORT = 7731
store = tempfile.mktemp(suffix='.json')
env = dict(os.environ, BIND_HOST='127.0.0.1', XC_PUBLISHER_ACCOUNT=PUB_ACCT,
           XC_MAX_BLOB=str(1024 * 1024))  # 1 MB blob cap for the test
proc = subprocess.Popen([sys.executable, RELAY, str(PORT), store], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
BASE = f'http://127.0.0.1:{PORT}'
time.sleep(1.2)

passed, failed = 0, 0
def check(name, ok, detail=''):
    global passed, failed
    if ok: passed += 1; print(f'  PASS  {name}')
    else:  failed += 1; print(f'  FAIL  {name}  {detail}')

def post(path, obj, raw=None, headers=None):
    data = raw if raw is not None else json.dumps(obj).encode()
    h = {'Content-Type': 'application/json'}; h.update(headers or {})
    req = urllib.request.Request(BASE + path, data, h, method='POST')
    try:
        r = urllib.request.urlopen(req, timeout=5)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception as e:
        return 0, str(e)

def get(path):
    try:
        return json.loads(urllib.request.urlopen(BASE + path, timeout=5).read())
    except Exception as e:
        return {'_err': str(e)}

try:
    # 1. SIGNED RESHARE — valid is accepted and recorded; forged is rejected
    pid = 'p_test_1'; ts = int(time.time())
    sig, pub = sign_msg(USR_KEY, f'reshare|{USR_ACCT}|{pid}|{ts}')
    st, r = post('/repost', {'post_id': pid, 'delta': 1, 'account': USR_ACCT, 'ts': ts, 'sig': sig, 'pub': pub})
    check('valid signed reshare accepted', st == 200 and r and USR_ACCT in r.get('resharers', []), f'{st} {r}')

    st, r = post('/repost', {'post_id': pid, 'delta': 1, 'account': USR_ACCT, 'ts': ts + 1,
                             'sig': 'ab' * 64, 'pub': pub})  # bad signature
    check('forged reshare rejected (400)', st == 400, f'{st}')

    # attacker names their own account with NO valid sig for a popular post → must not be credited
    atk = xc.derive(xc.keyof(0x73))[0]
    st, r = post('/repost', {'post_id': pid, 'delta': 1, 'account': atk, 'ts': ts})  # no sig
    e = get('/engagement').get('engage', {}).get(pid, {})
    check('unsigned reshare not credited (tip-siphon blocked)', atk not in e.get('resharers', []), e)

    # 2. RELEASE VERIFICATION — valid pinned-publisher record accepted; forged rejected (suppression fix)
    rec = {'publisher': PUB_ACCT, 'version': '9.9.9', 'cid': '', 'sha256': '', 'size': 0, 'changelog': 'x'}
    canon = f"{rec['publisher']}|{rec['version']}|{rec['cid']}|{rec['sha256']}|{rec['size']}|{rec['changelog']}"
    rsig, rpub = sign_msg(PUB_KEY, canon)
    rec['sig'] = rsig; rec['pub'] = rpub
    st, r = post('/release', rec)
    check('valid release accepted', st == 200 and r.get('accepted') is True, f'{st} {r}')

    forged = dict(rec, sig='cd' * 64)  # right publisher account, wrong signature
    st, r = post('/release', forged)
    recs = get('/releases?pub=' + PUB_ACCT).get('records', [])
    check('forged release rejected (not stored)', r and r.get('accepted') is False and len(recs) == 1, f'{st} {r} stored={len(recs)}')

    # a DIFFERENT publisher's record must not be stored under our pinned channel
    st, r = post('/release', dict(rec, publisher=USR_ACCT))
    check('non-pinned publisher release rejected', r and r.get('accepted') is False, f'{st} {r}')

    # 3. BODY + BLOB SIZE CAPS
    big = b'{"account":"nano_ob","ts":0,"follows":[],"x":"' + b'A' * (600 * 1024) + b'"}'  # > 512 KB cap
    st, r = post('/follows', None, raw=big)
    # rejected by the body cap before the body is read → clean 413 or a connection reset; either way
    # it must NOT be stored (the cap fires before the record is parsed).
    stored = get('/follows?account=nano_ob').get('record')
    check('oversized non-blob body rejected + not stored', st in (413, 0) and not stored, f'st={st} stored={stored}')

    oversized_b64 = base64.b64encode(b'Z' * (1024 * 1024 + 10)).decode()  # > 1 MB test blob cap
    st, r = post('/blob', {'cid': 'sha256-deadbeef', 'b64': oversized_b64})
    # rejected by the body cap BEFORE the body is read into RAM (the point of the DoS fix), so the
    # client sees a clean 413 or a connection reset — either way it must NOT be stored.
    stored = get('/haveblob?cid=sha256-deadbeef').get('have')
    check('oversized blob rejected + not stored', st in (413, 0) and not stored, f'st={st} stored={stored}')

    small = base64.b64encode(b'hello').decode()
    st, r = post('/blob', {'cid': 'sha256-x', 'b64': small})
    check('normal blob accepted', st == 200 and r.get('ok'), f'{st} {r}')

    # 4. NORMAL WRITES still work under the new caps (follows/profile/comment/poll)
    fts = int(time.time())
    fsig, fpub = sign_msg(USR_KEY, xc_follow := f'{USR_ACCT}|{fts}|')
    st, r = post('/follows', {'account': USR_ACCT, 'ts': fts, 'follows': [], 'sig': fsig, 'pub': fpub})
    check('normal follows write ok', st == 200 and get('/follows?account=' + USR_ACCT).get('record'), f'{st} {r}')

    # 5. LOCAL BLOCK VERIFICATION (verify_block): a correctly signed state block passes, tampered fails
    b = xc.sign(USR_KEY, '0' * 64, xc.nano_to_pub(USR_ACCT), '0', '00' * 32)  # a self-signed state block
    block = {'type': 'state', 'account': USR_ACCT, 'previous': '0' * 64,
             'representative': USR_ACCT, 'balance': '0', 'link': '00' * 32, 'signature': b['sig']}
    check('verify_block accepts a valid block', xc.verify_block(block) is True)
    bad = dict(block, balance='1000000')  # tamper a signed field
    check('verify_block rejects a tampered block', xc.verify_block(bad) is False)

finally:
    proc.terminate()
    try: os.remove(store)
    except Exception: pass
    try: os.remove(os.path.join(os.path.dirname(store), 'blobs.db'))
    except Exception: pass

print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
