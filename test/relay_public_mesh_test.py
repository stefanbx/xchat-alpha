#!/usr/bin/env python3
# Public mesh discovery + hybrid placement, end to end through real xc_relayd processes.
#
# A node opts into hub listing with --public (XC_MESH_PUBLIC=1). A hub then LISTS its routing token on
# /mesh_nodes, and any relay (or app) discovers it there with no secret and reaches it at <hub>/r/<token>.
# The hub also folds discovered public nodes into a MESH placement tier, so a NAT'd volunteer's box
# becomes a real capacity-tier relay. A node that did NOT opt in stays private and never appears.
#
# Topology: one stable HUB + a PUBLIC mesh node + a PRIVATE mesh node, both dialing the hub. We assert:
#   1. /mesh_nodes lists the PUBLIC node's token(s)                 ← opt-in listing works
#   2. /mesh_nodes does NOT list the PRIVATE node                   ← private-by-secret preserved
#   3. <hub>/r/<token>/relays reaches the public node (type=node)   ← token routes, no secret used
#   4. the hub discovers it → /cache shows mesh_relays >= 1         ← relay-side discovery + mesh tier
#   5. the hub reports tier 'stable'; the public node tier 'mesh'   ← the two placement tiers are self-describing
#
# No external services, no network: XC_ISOLATE=1 + a dead RPC keep it entirely on loopback.

import os
os.environ.setdefault('XC_ISOLATE', '1')
os.environ.setdefault('XC_NANO_RPC', 'http://127.0.0.1:1')

import json, socket, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_DIR = os.path.join(ROOT, 'relay')
sys.path.insert(0, os.path.join(ROOT, 'backend'))
sys.path.insert(0, RELAY_DIR)

STORES = []

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def get(url, timeout=8):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.getcode(), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception:
        return 0, b''

def j(url, timeout=8):
    _c, b = get(url, timeout)
    try:
        return json.loads(b.decode())
    except Exception:
        return {}

def wait_up(url, tries=60, delay=0.2):
    for _ in range(tries):
        c, _b = get(url, timeout=2)
        if c and c < 500:
            return True
        time.sleep(delay)
    return False

PASS = FAIL = 0
def check(cond, label, extra=None):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f'  ✓ {label}')
    else:
        FAIL += 1; print(f'  ✗ {label}' + (f'   |  {extra}' if extra is not None else ''))

def spawn(port, tag, bootstraps=(), env_extra=None):
    store = f'/tmp/xc_pub_{tag}_{port}.json'
    STORES.append(store)
    for suffix in ('', '.id'):
        try: os.remove(store + suffix)
        except OSError: pass
    env = {**os.environ, 'XC_ISOLATE': '1', 'XC_NANO_RPC': 'http://127.0.0.1:1',
           'XC_TUNNEL_PUBLIC_WAIT_S': '3', 'XC_TUNNEL_POLL_HOLD_S': '15', 'XC_MESH_DISCOVER_S': '2'}
    if env_extra:
        env.update(env_extra)
    argv = [sys.executable, 'xc_relayd.py', str(port), store, *bootstraps]
    return subprocess.Popen(argv, cwd=RELAY_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    ph, ppub, ppriv = free_port(), free_port(), free_port()
    HUB = f'http://127.0.0.1:{ph}'
    procs = {}
    try:
        print(f'\nhub :{ph}   public-node :{ppub}   private-node :{ppriv}\n')
        procs['H'] = spawn(ph, 'hub')
        if not wait_up(HUB + '/relays'):
            sys.exit('the hub never came up')

        # PUBLIC node: dials the hub explicitly, opts into listing.
        procs['PUB'] = spawn(ppub, 'pub', bootstraps=[HUB], env_extra={
            'XC_TUNNEL_ENTRIES': HUB, 'XC_TUNNEL_SECRET': 'pub-secret', 'XC_MESH_PUBLIC': '1'})
        # PRIVATE node: dials the hub, does NOT opt in.
        procs['PRIV'] = spawn(ppriv, 'priv', bootstraps=[HUB], env_extra={
            'XC_TUNNEL_ENTRIES': HUB, 'XC_TUNNEL_SECRET': 'priv-secret'})
        if not (wait_up(f'http://127.0.0.1:{ppub}/relays') and wait_up(f'http://127.0.0.1:{ppriv}/relays')):
            sys.exit('a node never came up')

        pub_acct = j(f'http://127.0.0.1:{ppub}/relays').get('account', '')
        priv_acct = j(f'http://127.0.0.1:{ppriv}/relays').get('account', '')

        # Wait for the public node's poll to register on the hub (/mesh_nodes non-empty).
        nodes = []
        for _ in range(60):
            nodes = j(HUB + '/mesh_nodes').get('nodes', [])
            if nodes:
                break
            time.sleep(0.25)

        check(len(nodes) >= 1, "the hub lists the PUBLIC node's token(s) on /mesh_nodes", nodes)

        # Reach the public node through the hub by its listed token — NO secret involved.
        reached = None
        for tok in nodes:
            r = j(f'{HUB}/r/{tok}/relays', timeout=12)
            if r.get('account'):
                reached = r
                break
        check(reached is not None and reached.get('account') == pub_acct and reached.get('type') == 'node',
              "a listed token routes through the hub to the public node (type=node)",
              None if reached else 'no token reached the node')

        # The PRIVATE node must not be reachable via any listed token (it never opted in).
        reached_accts = set()
        for tok in nodes:
            r = j(f'{HUB}/r/{tok}/relays', timeout=8)
            if r.get('account'):
                reached_accts.add(r['account'])
        check(priv_acct and priv_acct not in reached_accts,
              "the PRIVATE node is NOT listed / reachable via /mesh_nodes (stays private-by-secret)",
              f'priv={priv_acct[:16]}… listed={[a[:10] for a in reached_accts]}')

        # The hub's mesh_discover (every 2s here) should fold the public node into its MESH placement tier.
        cache = {}
        for _ in range(40):
            cache = j(HUB + '/cache')
            if cache.get('mesh_relays', 0) >= 1:
                break
            time.sleep(0.25)
        check(cache.get('mesh_relays', 0) >= 1,
              "the hub discovered the public node into its MESH placement tier (/cache mesh_relays >= 1)", cache)
        check(cache.get('tier') == 'stable',
              "the hub reports its own tier as 'stable'", cache.get('tier'))

        pub_cache = j(f'http://127.0.0.1:{ppub}/cache')
        check(pub_cache.get('tier') == 'mesh',
              "the public node reports its own tier as 'mesh'", pub_cache.get('tier'))

    finally:
        for p in procs.values():
            try: p.terminate()
            except Exception: pass
        time.sleep(0.3)
        for s in STORES:
            for suf in ('', '.id'):
                try: os.remove(s + suf)
                except OSError: pass

    print(f'\n  {PASS} passed, {FAIL} failed\n')
    sys.exit(1 if FAIL else 0)

if __name__ == '__main__':
    main()
