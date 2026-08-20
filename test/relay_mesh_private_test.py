#!/usr/bin/env python3
# Private-by-secret contract for a mesh 'node' relay, end to end through real xc_relayd processes.
#
# A mesh node (a tunnel CLIENT, behind NAT) is reachable ONLY through an entry by an ephemeral per-epoch
# token that holders of the out-of-band rendezvous secret derive (Layer A — the relay↔entry topology is
# deliberately kept off-chain). Its only routable public identity would be a LOOPBACK SELF, which a hub
# would learn, fail to probe, and correctly tombstone ~25 min later. So a node must NEVER push its url
# into the public relay set. This test proves exactly that, and that suppressing the push did NOT break
# a node's ability to still PULL the set (which it needs to discover entry candidates).
#
# Topology: one plain HUB (the bootstrap target) + a mesh NODE bootstrapped to it + a plain RELAY
# bootstrapped to it (the control). We assert:
#   1. the HUB's /relays does NOT list the node's url            ← the node never advertised itself
#   2. the HUB's /relays 'peers' has no record for the node acct ← nor a signed record for it
#   3. the HUB's /relays DOES list the control relay's url       ← the announce path works (not a no-op pass)
#   4. the NODE still learned the hub's url (it pulled)          ← discovery still works for a node
#   5. the NODE reports type 'node'; the hub reports type 'hub'  ← the two kinds are self-describing
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

SECRET = 'test-rendezvous-secret-do-not-ship'
STORES = []

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def get(url, timeout=5):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.getcode(), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception:
        return 0, b''

def relays_of(url):
    code, body = get(url + '/relays')
    try:
        return json.loads(body.decode())
    except Exception:
        return {}

def wait_up(url, tries=60, delay=0.2):
    for _ in range(tries):
        code, _b = get(url, timeout=2)
        if code and code < 500:
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
    store = f'/tmp/xc_priv_{tag}_{port}.json'
    STORES.append(store)
    for suffix in ('', '.id'):
        try: os.remove(store + suffix)
        except OSError: pass
    env = {**os.environ, 'XC_ISOLATE': '1', 'XC_NANO_RPC': 'http://127.0.0.1:1',
           'XC_TUNNEL_PUBLIC_WAIT_S': '3', 'XC_TUNNEL_POLL_HOLD_S': '15'}
    if env_extra:
        env.update(env_extra)
    argv = [sys.executable, 'xc_relayd.py', str(port), store, *bootstraps]
    return subprocess.Popen(argv, cwd=RELAY_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    ph, pn, pp = free_port(), free_port(), free_port()
    HUB = f'http://127.0.0.1:{ph}'
    NODE_URL = f'http://127.0.0.1:{pn}'
    CTRL_URL = f'http://127.0.0.1:{pp}'
    procs = {}
    try:
        print(f'\nhub :{ph}   node :{pn}   control :{pp}\n')
        # The hub: a plain relay, the bootstrap target. No tunnel env → a publicly-listed 'hub'.
        procs['H'] = spawn(ph, 'hub')
        if not wait_up(HUB + '/relays'):
            sys.exit('the hub never came up')

        # The mesh NODE: a tunnel client (discovers the hub as an entry candidate), bootstrapped to the hub.
        procs['N'] = spawn(pn, 'node', bootstraps=[HUB],
                           env_extra={'XC_TUNNEL_DISCOVER_FROM': HUB, 'XC_TUNNEL_SECRET': SECRET})
        # The CONTROL: a plain relay, bootstrapped to the same hub. It SHOULD announce and be listed.
        procs['P'] = spawn(pp, 'ctrl', bootstraps=[HUB])
        if not (wait_up(NODE_URL + '/relays') and wait_up(CTRL_URL + '/relays')):
            sys.exit('node or control never came up')

        node_acct = relays_of(NODE_URL).get('account', '')

        # Both node and control run bootstrap() ~0.4s after start; give the announces time to land, and
        # gate on the CONTROL appearing (that proves the announce path is live, so a missing node url is a
        # real suppression, not just "nothing announced yet").
        listed_ctrl = False
        for _ in range(40):
            hub_relays = relays_of(HUB).get('relays', [])
            if CTRL_URL in hub_relays:
                listed_ctrl = True
                break
            time.sleep(0.25)

        hub = relays_of(HUB)
        hub_relays = hub.get('relays', [])
        hub_peer_accts = [p.get('account') for p in hub.get('peers', [])]

        check(listed_ctrl and CTRL_URL in hub_relays,
              "control plain relay IS listed on the hub (the announce path works)", hub_relays)
        check(NODE_URL not in hub_relays,
              "the mesh node's url is NOT in the hub's relay set (never advertised)", hub_relays)
        check(node_acct and node_acct not in hub_peer_accts,
              "no SIGNED record for the node account on the hub either", f'node={node_acct[:20]}… peers={hub_peer_accts}')

        node = relays_of(NODE_URL)
        check(HUB in node.get('relays', []),
              "the node STILL learned the hub's url (it pulled the set to discover entries)", node.get('relays'))
        check(node.get('type') == 'node' and hub.get('type') == 'hub',
              "node reports type 'node', hub reports type 'hub'", f"node={node.get('type')} hub={hub.get('type')}")

        print(f'\n  {PASS} passed, {FAIL} failed\n')
        return 1 if FAIL else 0
    finally:
        for p in procs.values():
            try: p.terminate()
            except Exception: pass
        for p in procs.values():
            try: p.wait(timeout=5)
            except Exception:
                try: p.kill()
                except Exception: pass
        for s in STORES:
            for suffix in ('', '.id'):
                try: os.remove(s + suffix)
                except OSError: pass

if __name__ == '__main__':
    sys.exit(main())
