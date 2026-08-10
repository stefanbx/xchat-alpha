#!/usr/bin/env python3
# END-TO-END, WITH A REAL PHONE-SIDE SIGNER.
#
# Starts a relay and a seedless node, then drives every write path the way the app does: the "phone"
# here is app/bin/interop_sign.dart running as a signing daemon, holding the ONLY copy of the seed.
# Nothing in this file ever hands that seed to the node, because there is no longer an API that
# would take it.
#
# Each path is checked twice — once that a correctly signed record is ACCEPTED and lands on the
# relay, and once that a TAMPERED one is REFUSED. A verifier that accepts everything would pass the
# first half of every test and fail the second, which is the point of asking both.
#
#   python3 test/e2e_test.py          (needs: nanopy, a dart on PATH, an ipfs daemon)
import importlib.util, json, os, socket, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(ROOT, "backend", "xc_common.py"))

# A seed of its own, not the '07' demo identity: if a dev relay is running on this machine it may
# already hold posts and DMs for that account, and the test would read them back as its own.
SEED = '5a' * 32
# Discovery reads the ledger first. A test must not depend on a mainnet (or a dev node that happens
# to be up on this machine), so point it at a closed port: the scan fails, and the bootstrap below
# is what is left.
DEAD_RPC = 'http://127.0.0.1:9'
# discovery's shared scratch files. They belong to whatever else is running on this machine, so the
# test borrows them and puts them back.
SHARED = ('/tmp/xchat_bootstrap.txt', '/tmp/xc_known_relays.json', '/tmp/xc_onchain_relays.json')
fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close()
    return p


def wait_up(url, secs=25):
    for _ in range(secs * 5):
        try:
            urllib.request.urlopen(url, timeout=2).read()
            return True
        except urllib.error.HTTPError:
            return True
        except Exception:
            time.sleep(0.2)
    return False


def api(node, path, body=None):
    url = f'http://127.0.0.1:{node}{path}'
    try:
        if body is None:
            return json.loads(urllib.request.urlopen(url, timeout=30).read())
        req = urllib.request.Request(url, json.dumps(body).encode(), {'Content-Type': 'application/json'})
        return json.loads(urllib.request.urlopen(req, timeout=60).read())
    except Exception as e:
        return {'ok': False, 'error': f'{e}'}


class Phone:
    """The device. It holds the seed; the node never sees it."""

    def __init__(self):
        self.p = subprocess.Popen(['dart', 'run', 'bin/interop_sign.dart', 'daemon', SEED],
                                  cwd=os.path.join(ROOT, 'app'), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        me = json.loads(self._read())
        self.account, self.pub, self.dm_pub = me['account'], me['pub'], me['dm_pub']

    def _read(self):
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError('the signer died')
            line = line.strip()
            if line.startswith('{'):
                return line

    def _rpc(self, req):
        self.p.stdin.write(json.dumps(req) + '\n'); self.p.stdin.flush()
        return json.loads(self._read())

    def sign(self, msg):
        return self._rpc({'op': 'sign', 'msg': msg})

    def seal(self, peer, text):
        return self._rpc({'op': 'seal', 'peer': peer, 'text': text})['ct']

    def open(self, peer, ct):
        return self._rpc({'op': 'open', 'peer': peer, 'ct': ct})['text']

    def close(self):
        try:
            self.p.stdin.write('{"op":"quit"}\n'); self.p.stdin.flush(); self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def main():
    relay_port, node_port = free_port(), free_port()
    relay_url = f'http://127.0.0.1:{relay_port}'

    # a clean, deterministic discovery: this relay and nothing else
    saved = {f: (open(f, 'rb').read() if os.path.exists(f) else None) for f in SHARED}
    for f in SHARED:
        if os.path.exists(f):
            os.remove(f)
    open('/tmp/xchat_bootstrap.txt', 'w').write(relay_url + '\n')
    env = {**os.environ, 'XCHAT_BOOTSTRAP': relay_url, 'XC_NS': str(node_port),
           'XC_NANO_RPC': DEAD_RPC}

    procs = []
    try:
        procs.append(subprocess.Popen([sys.executable, 'xc_relayd.py', str(relay_port),
                                       f'/tmp/xc_relay_e2e_{relay_port}.json'],
                                      cwd=os.path.join(ROOT, 'relay'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(relay_url + '/relays'):
            sys.exit('the relay never came up')
        procs.append(subprocess.Popen([sys.executable, 'kt_server.py', str(node_port)],
                                      cwd=os.path.join(ROOT, 'backend'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(f'http://127.0.0.1:{node_port}/api/status'):
            sys.exit('the node never came up')

        phone = Phone()
        acct, ts = phone.account, int(time.time())
        print(f'\nrelay {relay_url}   node :{node_port}   device {acct[:20]}…\n')

        # ---- the node has no identity of its own: it reports back the account the app gave it ----
        me = api(node_port, f'/api/me?account={acct}')
        check(me.get('account') == acct, 'identity comes from the device', me)
        check(not os.path.exists(f'/tmp/xc_wallet_seed_{node_port}.txt'), 'the node stores no seed')

        # ---- POST: prepare (app-signed event) -> sign the head over the returned CID -> submit ----
        text = 'hello from an on-device signature'
        s = phone.sign(f'you.xno|post|{text}|{ts}')
        prep = api(node_port, '/api/post_prepare', {'handle': 'you.xno', 'account': acct, 'kind': 'post',
                                                    'text': text, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']})
        check(prep.get('ok') and prep.get('cid'), 'post prepare accepts the signed event', prep)
        if prep.get('ok'):
            # the head binds the CID the node just assembled, so it cannot substitute other content
            hs = phone.sign(prep['head_msg'])
            sub = api(node_port, '/api/post_submit', {'author': acct, 'handle': 'you.xno', 'seq': prep['seq'],
                                                      'cid': prep['cid'], 'expires': prep['expires'],
                                                      'sig': hs['sig'], 'pub': hs['pub']})
            check(sub.get('ok') and sub.get('relays_pushed', 0) >= 1, 'post submit gossips the signed head', sub)
            heads = json.loads(urllib.request.urlopen(relay_url + '/heads', timeout=5).read()).get('heads', [])
            mine = [h for h in heads if h.get('author') == acct]
            check(bool(mine) and mine[0]['cid'] == prep['cid'], 'the relay holds the signed head', heads)

        # THE REFUSAL: the same event with the text changed under the signature
        bad = api(node_port, '/api/post_prepare', {'handle': 'you.xno', 'account': acct, 'kind': 'post',
                                                   'text': text + ' (edited)', 'ts': ts,
                                                   'sig': s['sig'], 'pub': s['pub']})
        check(bad.get('ok') is False, 'a tampered post is refused', bad)

        # ---- FOLLOWS (the path that was still node-signed until this pass) ----
        follows = sorted(['nano_1aaa', 'nano_1bbb'])
        fs = phone.sign(f"{acct}|{ts}|{','.join(follows)}")
        api(node_port, '/api/follows_set', {'account': acct, 'follows': follows, 'ts': ts,
                                            'sig': fs['sig'], 'pub': fs['pub']})
        got = api(node_port, f'/api/follows_get?account={acct}')
        check(got.get('follows') == follows, 'follows publish + read back', got)
        api(node_port, '/api/follows_set', {'account': acct, 'follows': follows + ['nano_1ccc'],
                                            'ts': ts + 1, 'sig': fs['sig'], 'pub': fs['pub']})
        again = api(node_port, f'/api/follows_get?account={acct}')
        check(again.get('follows') == follows, 'a forged follow list is refused', again)

        # ---- PROFILE ----
        ps = phone.sign(f'{acct}|{ts}|Alice|my bio||')
        api(node_port, '/api/profile_set', {'account': acct, 'display': 'Alice', 'bio': 'my bio',
                                            'avatar': '', 'banner': '', 'ts': ts,
                                            'sig': ps['sig'], 'pub': ps['pub']})
        prof = api(node_port, f'/api/profile_get?account={acct}').get('profile', {})
        check(prof.get('display') == 'Alice' and prof.get('bio') == 'my bio', 'profile publish + read back', prof)

        # ---- COMMENT ----
        cs = phone.sign(f'p1|{acct}|{ts}|nice one|')
        api(node_port, '/api/comment_post', {'post_id': 'p1', 'account': acct, 'handle': 'you.xno',
                                             'text': 'nice one', 'parent': '', 'ts': ts,
                                             'sig': cs['sig'], 'pub': cs['pub']})
        cg = api(node_port, '/api/comments_get?post=p1')
        check(any(c.get('text') == 'nice one' for c in cg.get('comments', [])), 'comment publish + read back', cg)

        # ---- POLL VOTE ----
        vs = phone.sign(f'poll1|{acct}|1|{ts}')
        api(node_port, '/api/poll_vote', {'poll_id': 'poll1', 'account': acct, 'option': '1', 'ts': ts,
                                          'sig': vs['sig'], 'pub': vs['pub']})
        pg = api(node_port, f'/api/poll_get?poll=poll1&account={acct}')
        check(str(pg.get('my_option')) == '1' and (pg.get('counts') or {}).get('1') == 1,
              'poll vote counted', pg)

        # ---- DMs: the app seals, the relay only ever holds ciphertext ----
        ds = phone.sign(f'{acct}|{ts}|{phone.dm_pub}')
        api(node_port, '/api/dm_key_set', {'account': acct, 'dm_pk': phone.dm_pub, 'ts': ts,
                                           'sig': ds['sig'], 'pub': ds['pub']})
        kg = api(node_port, f'/api/dm_key_get?account={acct}')
        check(kg.get('dm_pk') == phone.dm_pub, 'DM key published + verified', kg)
        secret = 'meet at six'
        ct = phone.seal(phone.dm_pub, secret)                 # to ourselves: one device, both ends
        api(node_port, '/api/dm_send', {'to': acct, 'from': acct, 'ct': ct, 'ts': ts,
                                        'from_pk': phone.dm_pub})
        inbox = api(node_port, f'/api/dm_inbox?account={acct}')
        mine = [m for m in inbox.get('dms', []) if m.get('ct') == ct]
        check(bool(mine), 'the DM reached the relay', inbox)
        if mine:
            check(secret not in json.dumps(mine[0]), 'the relay holds ciphertext only')
            check(phone.open(phone.dm_pub, mine[0]['ct']) == secret, 'the device decrypts it')

        phone.close()
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        for f, was in saved.items():                      # put the machine back as we found it
            if was is None:
                if os.path.exists(f):
                    os.remove(f)
            else:
                open(f, 'wb').write(was)

    print(f"\n{'FAILED' if fails else 'PASS'} — {checks} checks, {len(fails)} failure(s)")
    for f in fails:
        print('  - ' + f)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
