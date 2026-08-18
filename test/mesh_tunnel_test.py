#!/usr/bin/env python3
# Mesh reverse-tunnel e2e — no-SPOF failover AND the Layer-A anonymity property (the entry node never
# learns which ledger account it carries), end to end through real relay processes.
#
# Topology: two ENTRY relays (public stand-ins) + one HOME relay that dials OUT to both. The home relay
# is never bound anywhere the "public" reaches it directly; it is reachable ONLY through the entry nodes'
# /r/<token>/... reverse-proxy, where <token> is an EPHEMERAL per-(entry,epoch) pubkey derived from a
# shared rendezvous secret — NOT the relay's ledger account. We prove:
#   1. reachable through entry A by its TOKEN, and answered by the HOME relay itself (its port, not the entry's);
#   2. the same through entry B (reachable via several entries at once);
#   3. the ledger ACCOUNT is NOT a routing key at the entry — /r/<account>/... 504s (the entry can't map
#      account→relay: it only ever saw an opaque token)  ← the Layer-A anonymity property;
#   4. the token DIFFERS per entry and per epoch (colluding entries can't link a relay; no time aggregation);
#   5. a poll with a bad signature is refused (nobody can register a token whose key they lack);
#   6. a request for an unconnected token 504s promptly (fails over to the next entry, doesn't hang);
#   7. killing entry A leaves the relay reachable through entry B  ← no single point of failure.
#
# No external services, no network: XC_ISOLATE=1 + a dead RPC keep it entirely on loopback.

import os
os.environ.setdefault('XC_ISOLATE', '1')                       # keep the in-test xc_common import offline
os.environ.setdefault('XC_NANO_RPC', 'http://127.0.0.1:1')

import json, socket, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_DIR = os.path.join(ROOT, 'relay')
sys.path.insert(0, os.path.join(ROOT, 'backend'))
sys.path.insert(0, RELAY_DIR)
import xc_common as xc                                          # derive / url_norm / sig_canon
import xc_tunnel as tun                                        # token_for / reach_tokens

SECRET = 'test-rendezvous-secret-do-not-ship'                  # the home relay's shared secret (operator-set)
STORES = []

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def get(url, timeout=35):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.getcode(), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def wait_up(url, tries=60, delay=0.2):
    for _ in range(tries):
        try:
            code, _b = get(url, timeout=2)
            if code and code < 500:
                return True
        except Exception:
            pass
        time.sleep(delay)
    return False

PASS = FAIL = 0
def check(cond, label, extra=None):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f'  ✓ {label}')
    else:
        FAIL += 1; print(f'  ✗ {label}' + (f'   |  {extra}' if extra is not None else ''))

def spawn(port, tag, env_extra=None):
    store = f'/tmp/xc_mesh_{tag}_{port}.json'
    STORES.append(store)
    for suffix in ('', '.id'):
        try: os.remove(store + suffix)
        except OSError: pass
    env = {**os.environ, 'XC_ISOLATE': '1', 'XC_NANO_RPC': 'http://127.0.0.1:1',
           'XC_TUNNEL_PUBLIC_WAIT_S': '3', 'XC_TUNNEL_POLL_HOLD_S': '15'}
    if env_extra:
        env.update(env_extra)
    return subprocess.Popen([sys.executable, 'xc_relayd.py', str(port), store],
                            cwd=RELAY_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def reach_by_token(entry, subpath, tries=40, delay=0.25):
    """GET entry/r/<token>/<subpath>, rotating through the current token window and retrying until the
    tunnel is connected (200) or we give up. The client derives the token from the shared SECRET exactly
    as a real client would — the entry is never told an account."""
    tokens = tun.reach_tokens(xc, SECRET, xc.url_norm(entry))
    last = None
    for _ in range(tries):
        for tok in tokens:
            code, body = get(f'{entry}/r/{tok}{subpath}', timeout=6)
            last = (code, body)
            if code == 200:
                return code, body
        time.sleep(delay)
    return last


def main():
    pa, pb, ph = free_port(), free_port(), free_port()
    A, B = f'http://127.0.0.1:{pa}', f'http://127.0.0.1:{pb}'
    procs = {}
    try:
        print(f'\nentry A :{pa}   entry B :{pb}   home :{ph}\n')
        procs['A'] = spawn(pa, 'entryA')
        procs['B'] = spawn(pb, 'entryB')
        if not (wait_up(A + '/relays') and wait_up(B + '/relays')):
            sys.exit('an entry relay never came up')

        # ---- entry nodes ADVERTISE the 't1' capability so they can be discovered ----
        capsA = json.loads(get(A + '/relays')[1].decode()).get('caps', [])
        capsB = json.loads(get(B + '/relays')[1].decode()).get('caps', [])
        check('t1' in capsA and 't1' in capsB,
              "entry nodes advertise the 't1' (mesh-entry) capability on /relays", f'A={capsA} B={capsB}')

        # The home relay DISCOVERS entries on-chain — here seeded with A,B as ledger candidates, which it
        # probes for 't1' and dials. It is given a shared rendezvous SECRET; reachability is by token
        # derived from it, never announced on-chain.
        procs['H'] = spawn(ph, 'home', {'XC_TUNNEL_DISCOVER_FROM': f'{A},{B}', 'XC_TUNNEL_SECRET': SECRET})
        if not wait_up(f'http://127.0.0.1:{ph}/relays'):
            sys.exit('the home relay never came up')

        home = json.loads(get(f'http://127.0.0.1:{ph}/relays')[1].decode())
        acct = home['account']
        check(bool(acct), 'home relay has a ledger identity (used end-to-end, never as the route)', home)
        check('t1' not in home.get('caps', []),
              "the home relay (a tunnel CLIENT) does NOT advertise 't1' — it can't accept inbound", home.get('caps'))
        print(f'  home account {acct[:22]}…\n')

        # ---- 1 & 2: reachable through EACH entry BY TOKEN, and answered by the home relay itself ----
        for name, entry in (('A', A), ('B', B)):
            code, body = reach_by_token(entry, '/relays')
            try:
                j = json.loads(body.decode())
            except Exception:
                j = {}
            check(code == 200 and j.get('account') == acct and j.get('relay') == ph,
                  f'reachable through entry {name} by TOKEN, answered by the HOME relay (port {ph}), not the entry',
                  f'code={code} relay={j.get("relay")} acct={str(j.get("account"))[:16]}')

        # ---- 3: the ANONYMITY property — the ledger account is NOT a routing key at the entry ----
        # A client (or a curious entry operator) that knows the account but not the secret cannot address
        # the relay: /r/<account>/... has no registered route and 504s. Only the ephemeral token works,
        # so the entry never learns / never needs the account.
        t0 = time.time()
        code, _b = get(f'{A}/r/{acct}/relays', timeout=8)
        check(code == 504 and (time.time() - t0) < 7,
              'the ledger ACCOUNT is not a route — /r/<account> 504s (the entry only ever saw a token)',
              f'code={code}')

        # ---- 4: tokens differ per entry and per epoch ----
        e = tun.epoch_now()
        tokA = tun.token_for(xc, SECRET, xc.url_norm(A), e)[1]
        tokB = tun.token_for(xc, SECRET, xc.url_norm(B), e)[1]
        tokA_next = tun.token_for(xc, SECRET, xc.url_norm(A), e + 1)[1]
        check(tokA != tokB, 'token differs PER ENTRY — colluding entries can’t link a relay across them',
              f'{tokA[:12]} vs {tokB[:12]}')
        check(tokA != tokA_next and acct not in (tokA, tokB),
              'token ROTATES per epoch and is never the account — no long-term aggregation, no account leak',
              f'e={tokA[:12]} e+1={tokA_next[:12]}')

        # ---- 5: a poll with a bad signature is refused ----
        code, _b = get(f'{A}/_tunnel/poll?token={tokA}&ts={int(time.time())}&sig=deadbeef', timeout=6)
        check(code == 403, 'a poll with a bad signature is refused (403) — no registering a token you lack the key for',
              f'code={code}')

        # ---- 6: a request for an unconnected token fails over (504), does not hang ----
        bogus = tun.token_for(xc, 'someone-elses-secret', xc.url_norm(A), e)[1]
        t0 = time.time()
        code, _b = get(f'{A}/r/{bogus}/relays', timeout=8)
        check(code == 504 and (time.time() - t0) < 7,
              'a request for an unconnected token 504s promptly (client just tries the next entry)', f'code={code}')

        # ---- 7: NO SINGLE POINT OF FAILURE — kill entry A, stay reachable through entry B ----
        procs['A'].terminate()
        try: procs['A'].wait(timeout=5)
        except Exception: procs['A'].kill()
        time.sleep(0.5)
        code, body = reach_by_token(B, '/relays', tries=40, delay=0.25)
        try:
            j = json.loads(body.decode())
        except Exception:
            j = {}
        check(code == 200 and j.get('relay') == ph,
              'entry A killed → home relay STILL reachable through entry B (no single point of failure)',
              f'code={code} relay={j.get("relay")}')

        print()
        print(f'  {PASS} passed, {FAIL} failed')
        sys.exit(1 if FAIL else 0)
    finally:
        for p in procs.values():
            try: p.terminate()
            except Exception: pass
        for p in procs.values():
            try: p.wait(timeout=5)
            except Exception:
                try: p.kill()
                except Exception: pass
        for store in STORES:
            for suffix in ('', '.id'):
                try: os.remove(store + suffix)
                except OSError: pass


if __name__ == '__main__':
    main()
