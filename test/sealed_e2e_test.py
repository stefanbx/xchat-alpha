#!/usr/bin/env python3
# SEALED SENDER, END TO END, THROUGH A REAL RELAY + NODE, WITH TWO REAL DEVICES.
#
# "Did sealed sender actually work?" — this answers it with the real components, not a mock. Two
# `Phone`s are two instances of app/bin/interop_sign.dart, each holding its own seed and running the
# SHIPPED wallet crypto (pinenacl) — the exact seal/open the app performs. They talk to a real relay
# and a real seedless node. Nothing here reimplements the protocol; it drives the same helpers the app
# calls (dm_key_set with caps, dm_key_get, dm_send, dm_inbox) end to end.
#
# It proves the four things that make sealed sender real:
#   1. NEGOTIATION — the recipient advertises a SIGNED capability; the sender fetches it and only then
#      sends the sealed format.
#   2. THE WIRE IS BLIND — the record the relay stores has NO `from`/`from_pk`: only a throwaway
#      ephemeral key, a version, a message id, and ciphertext. An operator reading the mailbox cannot
#      see who sent it.
#   3. DELIVERY + AUTHORSHIP — the recipient opens the outer seal, confirms the claimed sender key IS
#      that account's ledger-published dm key, opens the inner under it, and recovers the plaintext.
#   4. FORGERY FAILS — a third party who lies about being the sender cannot make the inner seal open
#      under the impersonated identity.
#
#   python3 test/sealed_e2e_test.py          (needs: nanopy, a dart on PATH)
import importlib.util, json, os, socket, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEAD_RPC = 'http://127.0.0.1:9'
os.environ.setdefault('XC_NANO_RPC', DEAD_RPC)
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(ROOT, "backend", "xc_common.py"))
xc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xc)

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
            urllib.request.urlopen(url, timeout=2).read(); return True
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
    """One device: the SHIPPED wallet crypto behind a line protocol. The node never sees the seed."""

    def __init__(self, seed):
        self.p = subprocess.Popen(['dart', 'run', 'bin/interop_sign.dart', 'daemon', seed],
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

    def caps(self):
        return self._rpc({'op': 'caps'})['caps']

    def caps_sig(self, ts, caps):
        return self._rpc({'op': 'caps_sig', 'ts': ts, 'caps': caps})

    def seal_sealed(self, peer_pk, text):
        return self._rpc({'op': 'seal_sealed', 'peer': peer_pk, 'text': text})

    def open_sealed(self, epk, ct):
        return self._rpc({'op': 'open_sealed', 'epk': epk, 'ct': ct})['outer']

    def open(self, peer_pk, ct):
        return self._rpc({'op': 'open', 'peer': peer_pk, 'ct': ct})['text']

    def register_dmkey(self, node_port, ts):
        """Publish the signed dm key AND the signed sealed-sender capability, the way the app does."""
        s = self.sign(xc.sig_canon('dmkey', self.account, ts, self.dm_pub))
        cs = self.caps_sig(ts, self.caps())
        return api(node_port, '/api/dm_key_set',
                   {'account': self.account, 'dm_pk': self.dm_pub, 'ts': ts, 'sig': s['sig'], 'pub': s['pub'],
                    'caps': self.caps(), 'caps_sig': cs['sig']})

    def close(self):
        try:
            self.p.stdin.write('{"op":"quit"}\n'); self.p.stdin.flush(); self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def main():
    relay_port, node_port = free_port(), free_port()
    relay_url = f'http://127.0.0.1:{relay_port}'
    saved = {f: (open(f, 'rb').read() if os.path.exists(f) else None) for f in SHARED}
    for f in SHARED:
        if os.path.exists(f):
            os.remove(f)
    open('/tmp/xchat_bootstrap.txt', 'w').write(relay_url + '\n')
    env = {**os.environ, 'XCHAT_BOOTSTRAP': relay_url, 'XC_NS': str(node_port),
           'XC_NANO_RPC': DEAD_RPC, 'XC_ISOLATE': '1'}

    procs = []
    try:
        procs.append(subprocess.Popen([sys.executable, 'xc_relayd.py', str(relay_port),
                                       f'/tmp/xc_relay_sealed_{relay_port}.json'],
                                      cwd=os.path.join(ROOT, 'relay'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(relay_url + '/relays'):
            sys.exit('the relay never came up')
        procs.append(subprocess.Popen([sys.executable, 'kt_server.py', str(node_port)],
                                      cwd=os.path.join(ROOT, 'backend'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(f'http://127.0.0.1:{node_port}/api/status'):
            sys.exit('the node never came up')

        alice = Phone('a1' * 32)     # the sender
        bob = Phone('b2' * 32)       # the recipient
        mallory = Phone('cc' * 32)   # an impersonator
        ts = int(time.time())
        print(f'\nrelay {relay_url}   node :{node_port}')
        print(f'alice {alice.account[:18]}…   bob {bob.account[:18]}…\n')

        # Both parties register their dm key at startup (as the app does). Bob's is what alice encrypts
        # to; alice's is what bob later checks the sealed record's authorship against.
        check(alice.register_dmkey(node_port, ts).get('ok') is not False, 'alice publishes her dm key + caps')
        # ---- 1. NEGOTIATION: bob advertises a SIGNED capability; alice fetches it -------------------
        check(bob.register_dmkey(node_port, ts).get('ok') is not False, 'bob publishes his dm key + caps')
        seen = api(node_port, f'/api/dm_key_get?account={bob.account}')
        check(seen.get('dm_pk') == bob.dm_pub, 'alice resolves bob\'s dm key through the node', seen)
        check(seen.get('caps') == 's1',
              'and sees bob\'s SIGNED sealed-sender capability (the node verified its signature)', seen)

        # A stripped/forged caps must not survive: the node only forwards caps whose signature checks.
        forged = api(node_port, '/api/dm_key_set',
                     {'account': mallory.account, 'dm_pk': mallory.dm_pub, 'ts': ts,
                      **mallory.sign(xc.sig_canon('dmkey', mallory.account, ts, mallory.dm_pub)),
                      'caps': 's1', 'caps_sig': 'deadbeef'})   # a caps claim with a bogus signature
        mseen = api(node_port, f'/api/dm_key_get?account={mallory.account}')
        check(mseen.get('dm_pk') == mallory.dm_pub and not mseen.get('caps'),
              'a caps claim with a bad signature is dropped — no unsigned capability reaches a sender', mseen)

        # ---- alice builds the sealed record exactly as Api.dmSend does when caps advertise 's1' -----
        secret = 'the vote is at midnight'
        env_sealed = alice.seal_sealed(bob.dm_pub, secret)
        record = {'v': 2, 'to': bob.account, 'ts': ts, 'mid': 'a' * 32,
                  'epk': env_sealed['epk'], 'ct': env_sealed['ct']}
        check(api(node_port, '/api/dm_send', record).get('ok') is not False, 'alice sends the sealed record')

        # ---- 2. THE WIRE IS BLIND: read bob's mailbox and inspect what the relay actually stored ----
        inbox = api(node_port, f'/api/dm_inbox?account={bob.account}')
        got = [m for m in inbox.get('dms', []) if m.get('ts') == ts and m.get('v') == 2]
        check(len(got) == 1, 'the sealed record reached bob\'s mailbox', inbox)
        rec = got[0] if got else {}
        check('from' not in rec and 'from_pk' not in rec,
              'the stored record carries NO sender — an operator reading the mailbox cannot see who sent it',
              json.dumps(rec))
        check(rec.get('epk') == env_sealed['epk'] and rec.get('epk') != alice.dm_pub,
              'only a throwaway ephemeral key is on the wire, never alice\'s identity key')
        check(alice.account not in json.dumps(rec) and secret not in json.dumps(rec),
              'neither alice\'s account nor the plaintext appears anywhere in the stored record')

        # ---- 3. DELIVERY + AUTHORSHIP: bob opens it the way Api.dmInbox does ------------------------
        outer = bob.open_sealed(rec['epk'], rec['ct'])
        check(outer is not None, 'bob opens the outer seal with his own dm key × the ephemeral key')
        claimed_from, claimed_pk, inner = outer['f'], outer['k'], outer['i']
        # Authorship: the claim is only trusted because the node-verified ledger key for `from` matches.
        ledger = api(node_port, f'/api/dm_key_get?account={claimed_from}')
        check(claimed_from == alice.account and claimed_pk == ledger.get('dm_pk') == alice.dm_pub,
              'the claimed sender resolves to alice AND her claimed key IS her ledger dm key')
        check(bob.open(alice.dm_pub, inner) == secret,
              'bob opens the inner seal under alice\'s real key and recovers the message')

        # ---- 4. FORGERY FAILS: mallory claims to be alice ------------------------------------------
        # Mallory can write f=alice into her payload, but can only seal the inner under her OWN key.
        # bob's authorship step opens the inner under ALICE's key — which mallory's inner will not do.
        forged_inner = mallory._rpc({'op': 'seal', 'peer': bob.dm_pub, 'text': 'send me your funds'})['ct']
        check(bob.open(alice.dm_pub, forged_inner) is None,
              'an inner seal made by mallory does NOT open under alice\'s key — the impersonation is caught')
        check(bob.open(mallory.dm_pub, forged_inner) == 'send me your funds',
              '(it opens under mallory\'s real key — the seal is valid, just hers, not alice\'s)')

        alice.close(); bob.close(); mallory.close()
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        for f, was in saved.items():
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
