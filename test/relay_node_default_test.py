#!/usr/bin/env python3
"""Every relay is a node by default — the change that lets the network survive losing any one host.

Clients need /api, and ONLY a node serves it. A relay-only install holds data that no app can read
directly, so an announced relay-only install is a dead end for a client trying to fail over. Blocking
the Fly node proved this: the app fell back to the ONE other endpoint that happened to serve /api. If
the announced pool were full of nodes, any one of them could catch that fallback.

So a first install now defaults to WITH_NODE=1. `--no-node` still opts out for a deliberately light,
storage-only relay, and an existing install keeps whatever it already chose (so --update never
silently flips a running relay).

Source-level guards: exercising a real install needs a full node bring-up (IPFS, venv, a public
tunnel), which is not something a unit test should stand up. The default, the opt-out, the inherit
rule, and the fact that a node install tunnels the NODE port are what regress, so those are pinned.

    python3 test/relay_node_default_test.py
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'install-relay.sh')).read()

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


print('--- a first install is a NODE by default ---')
check(re.search(r'WITH_NODE="\$\{XC_WITH_NODE:-1\}"', SRC) is not None,
      'the default is WITH_NODE=1 (every relay serves /api and is a failover target)')
# The old default was the bug: relay-only means announced-but-useless-to-a-client.
check('WITH_NODE="${XC_WITH_NODE:-0}"' not in SRC,
      'the relay-only default (:-0) is gone')

print('\n--- but the operator can still opt out, and an existing choice is kept ---')
check('--no-node)' in SRC and re.search(r'--no-node\)\s*WITH_NODE=0', SRC) is not None,
      '--no-node still gives a deliberately light, storage-only relay')
check('--with-node)' in SRC and re.search(r'--with-node\)\s*WITH_NODE=1', SRC) is not None,
      '--with-node is still explicit')
# Inherit from an existing run.sh so --update never flips a running relay under the operator.
check(re.search(r'_prev=\$\(sed[^\n]*WITH_NODE', SRC) is not None,
      'an existing install keeps its own WITH_NODE (update does not silently change it)')

print('\n--- a node install exposes the NODE, so what gets announced actually serves /api ---')
# The tunnel must forward the node port when WITH_NODE=1, or the announced URL would hit the relay
# (no /api) and the whole point is lost.
node_port_tunnelled = re.findall(r'TUNNEL_PORT="\$PORT"; \[ "\$WITH_NODE" = 1 \] && TUNNEL_PORT="\$NODE_PORT"', SRC)
check(len(node_port_tunnelled) >= 1,
      'the tunnel forwards the NODE port when WITH_NODE=1, so the announced address serves /api',
      f'{len(node_port_tunnelled)} sites')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
