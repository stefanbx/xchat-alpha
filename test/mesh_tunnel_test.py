#!/usr/bin/env python3
# Mesh reverse-tunnel e2e — the no-SPOF property, end to end through real relay processes.
#
# Topology: two ENTRY relays (public stand-ins) + one HOME relay that dials OUT to both. The home relay
# is never bound anywhere the "public" reaches it directly; it is reachable ONLY through the entry nodes'
# /r/<account>/... reverse-proxy. We then prove:
#   1. a public GET to entry A is answered by the HOME relay itself (its account + port, not the entry's);
#   2. the same works through entry B (the relay is reachable via several entries at once);
#   3. killing entry A leaves the relay reachable through entry B  ← the whole point: NO single point of failure;
#   4. a poll with a bad signature is refused (nobody can register as an account whose key they lack);
#   5. a request for an account with no connected relay 504s (fails over to the next entry, doesn't hang forever).
#
# No external services, no network: XC_ISOLATE=1 + a dead RPC keep it entirely on loopback.

import json, os, socket, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_DIR = os.path.join(ROOT, 'relay')
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

def tunnel_get(entry, account, subpath, tries=40, delay=0.25):
    """GET entry/r/<account>/<subpath>, retrying until the tunnel is connected (200) or we give up."""
    url = f'{entry}/r/{account}{subpath}'
    last = None
    for _ in range(tries):
        code, body = get(url, timeout=6)
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

        # The home relay dials OUT to both entries; it is reachable to the "public" ONLY through them.
        procs['H'] = spawn(ph, 'home', {'XC_TUNNEL_ENTRIES': f'{A},{B}'})
        if not wait_up(f'http://127.0.0.1:{ph}/relays'):
            sys.exit('the home relay never came up')

        home = json.loads(get(f'http://127.0.0.1:{ph}/relays')[1].decode())
        acct = home['account']
        check(bool(acct), 'home relay has a ledger identity to be reached by', home)
        print(f'  home account {acct[:22]}…\n')

        # ---- 1 & 2: reachable through EACH entry, and answered by the home relay itself ----
        for name, entry in (('A', A), ('B', B)):
            code, body = tunnel_get(entry, acct, '/relays')
            try:
                j = json.loads(body.decode())
            except Exception:
                j = {}
            check(code == 200 and j.get('account') == acct and j.get('relay') == ph,
                  f'reachable through entry {name}, and the answer came from the HOME relay (port {ph}), not the entry',
                  f'code={code} relay={j.get("relay")} acct={str(j.get("account"))[:16]}')

        # ---- 4: a poll with a bad signature is refused ----
        code, _b = get(f'{A}/_tunnel/poll?account={acct}&pub=00&ts={int(time.time())}&sig=deadbeef', timeout=6)
        check(code == 403, 'a poll with a bad signature is refused (403) — no hijacking an account you lack the key for',
              f'code={code}')

        # ---- 5: a request for an account with NO connected relay fails over (504), does not hang ----
        t0 = time.time()
        code, _b = get(f'{A}/r/nano_1elsewhere000000000000000000000000000000000000000000000000/relays', timeout=8)
        check(code == 504 and (time.time() - t0) < 7,
              'a request for an unconnected account 504s promptly (client just tries the next entry)', f'code={code}')

        # ---- 3: NO SINGLE POINT OF FAILURE — kill entry A, stay reachable through entry B ----
        procs['A'].terminate()
        try: procs['A'].wait(timeout=5)
        except Exception: procs['A'].kill()
        time.sleep(0.5)
        code, body = tunnel_get(B, acct, '/relays', tries=40, delay=0.25)
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
