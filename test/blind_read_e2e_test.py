#!/usr/bin/env python3
# BLIND MAILBOX READ, END TO END, THROUGH A REAL RELAY + NODE — the fix for IP<->account correlation.
#
# Sealed sender hid the SENDER from the relay. It did nothing for the reader: to read its mailbox a
# client must name the account that owns it, so whoever serves the read learns "this IP reads that
# account's DMs". With the node in front of the relays, the NODE holds that pair (client IP + account)
# and can re-attach a sender to a sealed message by correlation. This closes it with a one-hop onion:
# the client seals the read request to a chosen RELAY's key and hands the blob to its node, which
# blind-forwards it. The node sees the IP but not the account; the relay sees the account but only the
# node's IP. No single operator holds both.
#
# Nothing here is mocked. `bob` is app/bin/interop_sign.dart running the SHIPPED wallet crypto
# (pinenacl) — the exact seal/open the app performs. The relay and node are the real processes.
#
# It proves the five things that make the fix real:
#   1. AUTHENTICATED KEY — the relay advertises an X25519 read key SIGNED by its ledger identity, and
#      the client verifies it against the account it knows for that relay. A MITM node cannot swap it.
#   2. THE NODE IS BLIND — the blob the node forwards, and the reply it returns, contain no account and
#      no plaintext: the mailbox owner is inside a seal the node cannot open.
#   3. DELIVERY — the relay opens the sealed request, serves the mailbox, and the client recovers its
#      messages from the sealed reply.
#   4. OWNERSHIP STILL GATES — a blind read whose ownership proof is bad is refused, exactly as the
#      cleartext read refuses it. Blinding the account does not blind the relay to a forged proof.
#   5. NO OPEN PROXY — the node forwards only to relays it knows, never an arbitrary client-named URL.
#
#   python3 test/blind_read_e2e_test.py          (needs: nanopy, pynacl, a dart on PATH)
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

    def register_dmkey(self, node_port, ts):
        s = self.sign(xc.sig_canon('dmkey', self.account, ts, self.dm_pub))
        return api(node_port, '/api/dm_key_set',
                   {'account': self.account, 'dm_pk': self.dm_pub, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']})

    def verify_readkey(self, rec, ledger_account):
        return self._rpc({'op': 'relaykey_verify', 'rec': rec, 'account': ledger_account})['read_pk']

    def mailbox_seal(self, read_pk, request):
        return self._rpc({'op': 'mailbox_seal', 'read_pk': read_pk, 'request': request})

    def mailbox_open(self, reply_ct):
        return self._rpc({'op': 'mailbox_open', 'reply_ct': reply_ct})['reply']

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
                                       f'/tmp/xc_relay_blind_{relay_port}.json'],
                                      cwd=os.path.join(ROOT, 'relay'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(relay_url + '/relays'):
            sys.exit('the relay never came up')
        procs.append(subprocess.Popen([sys.executable, 'kt_server.py', str(node_port)],
                                      cwd=os.path.join(ROOT, 'backend'), env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not wait_up(f'http://127.0.0.1:{node_port}/api/status'):
            sys.exit('the node never came up')

        alice = Phone('a1' * 32)     # the sender, so bob's mailbox has something in it
        bob = Phone('b2' * 32)       # the reader — the one whose IP<->account link we are breaking
        ts = int(time.time())
        print(f'\nrelay {relay_url}   node :{node_port}')
        print(f'alice {alice.account[:18]}…   bob {bob.account[:18]}…\n')

        alice.register_dmkey(node_port, ts)
        bob.register_dmkey(node_port, ts)

        # ---- 1. AUTHENTICATED KEY: fetch the relay's signed read key THROUGH the node ---------------
        # In production the client learns the relay's account off the ledger (LedgerDiscovery). Here the
        # record self-reports it; the point of the check is that the signature BINDS read_pk to that
        # account, so a node cannot substitute a key without also forging a relay-account signature.
        rk = api(node_port, f'/api/relay_readkey?relay={relay_url}')
        check(rk.get('read_pk') and rk.get('caps') == 'r1',
              'the relay advertises a signed read key (caps r1)', rk)
        ledger_acct = rk.get('account', '')
        verified = bob.verify_readkey(rk, ledger_acct)
        check(verified == rk.get('read_pk'),
              'bob verifies the read key against the relay\'s ledger account (on-device signature check)')

        # MITM: a node that swaps in its OWN read key (keeping the relay account + signature) is caught,
        # because the signature no longer covers this key.
        swapped = {**rk, 'read_pk': ('00' if rk['read_pk'][:2] != '00' else '11') + rk['read_pk'][2:]}
        check(bob.verify_readkey(swapped, ledger_acct) is None,
              'a read key swapped by the node fails verification — no unwrappable key reaches the client')
        check(bob.verify_readkey(rk, 'nano_' + '1' * 60) is None,
              'a read key checked against the WRONG relay account is rejected')

        # alice puts a message in bob's mailbox (ordinary send; the blind read is about READING it)
        secret = 'meet at the safehouse'
        env_sealed = alice._rpc({'op': 'seal_sealed', 'peer': bob.dm_pub, 'text': secret})
        api(node_port, '/api/dm_send', {'v': 2, 'to': bob.account, 'ts': ts, 'mid': 'b' * 32,
                                        'epk': env_sealed['epk'], 'ct': env_sealed['ct']})

        # ---- 2 + 3. THE NODE IS BLIND, and the read still delivers ----------------------------------
        proof = bob.sign(xc.sig_canon('dminbox', bob.account, ts))
        request = {'account': bob.account, 'ts': ts, 'sig': proof['sig'], 'pub': proof['pub'], 'since': 0}
        sealed = bob.mailbox_seal(verified, request)
        blob = {'relay': relay_url, 'epk': sealed['epk'], 'ct': sealed['ct']}
        # What the node receives to forward. bob's account is INSIDE ct, which the node cannot open.
        check(bob.account not in json.dumps(blob) and 'nano_' not in sealed['ct'],
              'the read request the node forwards names no account — it is sealed to the relay')

        resp = api(node_port, '/api/dm_blind_read', blob)
        check(resp.get('v') == 1 and resp.get('ct'),
              'the node returns the relay\'s sealed reply', resp)
        check(bob.account not in json.dumps(resp) and secret not in json.dumps(resp),
              'the reply the node returns exposes neither bob\'s account nor any message plaintext')

        reply = bob.mailbox_open(resp['ct'])
        check(isinstance(reply, dict) and reply.get('account') == bob.account,
              'bob opens the sealed reply and it is his mailbox')
        got = [m for m in (reply.get('dms') or []) if m.get('ts') == ts and m.get('epk') == env_sealed['epk']]
        check(len(got) == 1, 'the blind read delivered the message alice sent', reply)

        # ---- 4. OWNERSHIP STILL GATES: a bad proof is refused even when the account is blinded -------
        bad = {'account': bob.account, 'ts': ts, 'sig': 'deadbeef', 'pub': proof['pub'], 'since': 0}
        bad_sealed = bob.mailbox_seal(verified, bad)
        bad_resp = api(node_port, '/api/dm_blind_read',
                       {'relay': relay_url, 'epk': bad_sealed['epk'], 'ct': bad_sealed['ct']})
        bad_reply = bob.mailbox_open(bad_resp.get('ct', '')) if bad_resp.get('ct') else {'error': 'no reply'}
        check(isinstance(bad_reply, dict) and bad_reply.get('error') and not bad_reply.get('dms'),
              'a blind read with a bad ownership proof is refused — the relay still checks the signature',
              bad_reply)

        # ---- 5. NO OPEN PROXY: the node forwards only to relays it knows ----------------------------
        evil = api(node_port, '/api/dm_blind_read',
                   {'relay': 'http://169.254.169.254', 'epk': sealed['epk'], 'ct': sealed['ct']})
        check(evil.get('error') == 'unknown relay',
              'the node refuses to forward a blind read to a relay it does not know (no SSRF/open proxy)')

        alice.close(); bob.close()
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
