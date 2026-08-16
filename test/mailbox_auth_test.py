#!/usr/bin/env python3
"""Reading a mailbox should cost a signature from the account that owns it.

/dm returns records whose BODIES are sealed but whose `to`, `from`, `from_pk` and `ts` are not. So
serving them to whoever asks publishes the account's entire social graph — who it talks to, when, how
often, in which direction — and until this change it was doing exactly that, to strangers, with no
key and no session. For most people the graph is more revealing than the text.

Verified against a REAL relay on a spare port, in isolation.

Two things this deliberately does NOT claim:

  - it does not hide `from`/`to` from the RELAY OPERATOR. That needs sealed sender, which is a wire
    change; see docs/PRIVACY-AND-DECENTRALIZATION.md. This closes the part where anyone at all could
    look.
  - strict mode is OFF by default, so on a default relay an unsigned read is still served. Clients
    up to 2.5.0 do not sign, and enforcing today would break DMs for every install in existence —
    shipping a privacy fix by removing the feature. The tests below cover BOTH modes so the flip is
    a config change and not a rewrite.

    python3 test/mailbox_auth_test.py
"""
import json, os, socket, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, 'backend'))
import xc_common as xc

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p


ALICE_SEED = 'a1' * 32
MALLORY_SEED = 'd4' * 32
ALICE, ALICE_PUB = xc.derive(ALICE_SEED)[0], xc.derive(ALICE_SEED)[1]
MALLORY, MALLORY_PUB = xc.derive(MALLORY_SEED)[0], xc.derive(MALLORY_SEED)[1]


def signed_qs(seed, acct, ts=None):
    ts = int(ts if ts is not None else time.time())
    d = dict(l.split(' ', 1) for l in xc._sign_lines(seed, xc.sig_canon('dminbox', acct, ts)))
    return '&ts=%d&sig=%s&pub=%s' % (ts, urllib.parse.quote(d['sig']), urllib.parse.quote(d['pub']))


class Relay:
    def __init__(self, strict):
        self.port = free_port()
        self.base = f'http://127.0.0.1:{self.port}'
        env = dict(os.environ, XC_ISOLATE='1', XCHAT_BOOTSTRAP='http://127.0.0.1:1',
                   XC_DM_STRICT='1' if strict else '0')
        self.state = f'/tmp/xc_mailbox_test_{self.port}.json'
        self.p = subprocess.Popen([sys.executable, 'xc_relayd.py', str(self.port), self.state],
                                  cwd=os.path.join(REPO, 'relay'), env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        end = time.time() + 40
        while time.time() < end:
            try:
                urllib.request.urlopen(self.base + '/heads', timeout=2).read(); return
            except Exception:
                time.sleep(0.3)
        raise RuntimeError('relay did not start: ' + (self.p.stdout.read() or b'').decode()[:800])

    def seed_dm(self):
        body = json.dumps({'to': ALICE, 'from': MALLORY, 'from_pk': 'aa' * 32,
                           'to_pk': 'bb' * 32, 'ct': 'SEALEDBODY', 'ts': int(time.time())}).encode()
        urllib.request.urlopen(urllib.request.Request(
            self.base + '/dm', body, {'Content-Type': 'application/json'}), timeout=10).read()

    def get(self, acct, qs=''):
        try:
            r = urllib.request.urlopen(f'{self.base}/dm?account={acct}{qs}', timeout=10)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b'{}')

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        for f in (self.state,):
            try:
                os.remove(f)
            except Exception:
                pass


print('--- default relay: unsigned reads still served, signed ones verified ---')
r = Relay(strict=False)
try:
    r.seed_dm()
    st, d = r.get(ALICE)
    check(st == 200 and len(d.get('dms', [])) == 1,
          'an unsigned read is still served by default (2.5.0 clients keep working)', f'{st} {d}')
    st, d = r.get(ALICE, signed_qs(ALICE_SEED, ALICE))
    check(st == 200 and len(d.get('dms', [])) == 1, 'a correctly signed read works', f'{st} {d}')
    # A signature that is present must be CORRECT even when strict is off, or "offer a signature"
    # becomes a way to look like you authenticated while not having done so.
    st, d = r.get(ALICE, signed_qs(MALLORY_SEED, ALICE))
    check(st == 403, "mallory cannot read alice's mailbox by signing with her own key", f'{st} {d}')
    st, d = r.get(ALICE, '&ts=%d&sig=%s&pub=%s' % (int(time.time()), 'ff' * 64, ALICE_PUB))
    check(st == 403, 'a forged signature is refused even in non-strict mode', f'{st} {d}')
finally:
    r.stop()

print('\n--- strict relay: the graph stops being public ---')
r = Relay(strict=True)
try:
    r.seed_dm()
    st, d = r.get(ALICE)
    check(st == 403, 'an unsigned read is REFUSED', f'{st} {d}')
    check(d.get('dms') == [], 'and leaks nothing in the error body', json.dumps(d))
    check('update your app' in (d.get('error') or ''),
          'the refusal says what to do about it', json.dumps(d))

    st, d = r.get(ALICE, signed_qs(ALICE_SEED, ALICE))
    check(st == 200 and len(d.get('dms', [])) == 1, 'alice can still read her own', f'{st} {d}')

    st, d = r.get(ALICE, signed_qs(MALLORY_SEED, MALLORY))
    check(st == 403, "mallory's own valid signature does not open alice's mailbox", f'{st} {d}')

    # The account and the key must agree, or anyone could present a real signature over someone
    # else's account string.
    st, d = r.get(ALICE, '&ts=%d&sig=%s&pub=%s' % (int(time.time()), 'ff' * 64, MALLORY_PUB))
    check(st == 403, 'a key that does not derive the account is refused', f'{st} {d}')

    print('\n--- a captured signature is not a permanent key ---')
    old = signed_qs(ALICE_SEED, ALICE, ts=time.time() - 4000)
    st, d = r.get(ALICE, old)
    check(st == 403, 'a signature from an hour ago is expired', f'{st} {d}')
    future = signed_qs(ALICE_SEED, ALICE, ts=time.time() + 4000)
    st, d = r.get(ALICE, future)
    check(st == 403, 'and one from the future cannot mint a long-lived token', f'{st} {d}')
    fresh = signed_qs(ALICE_SEED, ALICE, ts=time.time() - 30)
    st, _ = r.get(ALICE, fresh)
    check(st == 200, 'a recent one is fine — clocks are not perfect', str(st))

    print('\n--- malformed input is refused, not crashed on ---')
    for qs, label in [('&ts=notanumber&sig=x&pub=y', 'a non-numeric ts'),
                      ('&ts=1&sig=&pub=', 'empty sig and pub'),
                      ('&ts=1&sig=zz&pub=zz', 'garbage hex')]:
        st, _ = r.get(ALICE, qs)
        check(st == 403, f'{label} is refused', str(st))
    st, _ = r.get('', signed_qs(ALICE_SEED, ''))
    check(st == 403, 'an empty account is refused', str(st))
finally:
    r.stop()

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
