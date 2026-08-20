#!/usr/bin/env python3
"""--hub: a true one-shot PUBLIC hub for a VPS — bind straight to the internet, no external service.

A hub is a publicly-reachable relay (an entry node, cap 't1') that fronts NAT'd relays. On a box with a
public IP the node already listens on 0.0.0.0, so a hub needs no tunnel, no proxy, and no external CA or
service — it just serves the direct address and announces it. This pins that contract at the source
level (a real install stands up IPFS + a venv, which a unit test should not), plus asserts the ONE thing
that would silently break the design: that --hub never reintroduces an external dependency.

The runtime half (a hub relay binds 0.0.0.0 and reports type 'hub') is exercised live elsewhere; here we
guard the installer wiring that a refactor could regress.

    python3 test/relay_hub_mode_test.py
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

print('--- --hub is a real option that selects hub mode ---')
check('--hub)' in SRC and re.search(r'--hub\)\s+USE_HUB=1', SRC) is not None,
      '--hub sets USE_HUB=1')
check('--hub=*)' in SRC and re.search(r'--hub=\*\)\s*USE_HUB=1', SRC) is not None,
      '--hub=<host> is accepted too')
check(re.search(r'USE_HUB" = 1 \];\s*then MODE=hub', SRC) is not None,
      'USE_HUB resolves to MODE=hub')
# The optional address is consumed only when it is not itself a flag — so `--hub --no-node` still works.
check(re.search(r'case "\$\{2:-\}" in\s*\'\'\|-\*\)', SRC) is not None,
      'an optional address after --hub is taken only if it is not a flag')

print('\n--- a hub serves a DIRECT http url, no tunnel ---')
check(re.search(r'MODE" = hub \]; then[\s\S]*?PUBLIC_URL="http://', SRC) is not None,
      'hub builds a direct http:// public url')
# with a node it is the node port that faces the world; --no-node exposes the relay port instead
check(re.search(r'_hubport="\$NODE_PORT";\s*\[ "\$WITH_NODE" = 1 \] \|\| _hubport="\$PORT"', SRC) is not None,
      'the public port is the node port with a node, the relay port without one')

print('\n--- NO external service, NO external dependency (the whole point) ---')
# cloudflared must be SKIPPED for hub, exactly as it is for direct.
check(re.search(r'MODE" = hub \];\s*then\s*\n\s*ok "hub mode: serving directly', SRC) is not None,
      'cloudflared is NOT downloaded in hub mode (no tunnel)')
# the address is read LOCALLY (routing table), never from an outside "what is my IP" service.
check('ip -4 route get' in SRC,
      'the public IP is read locally from the routing table (ip route get), no external lookup')
check(re.search(r'ipify|whatismyip|ifconfig\.me|icanhazip|checkip', SRC, re.I) is None,
      'no external IP-echo service is contacted')

print('\n--- run.sh wiring: bind public, and do not churn a tunnel that does not exist ---')
# a --no-node hub must bind the relay to 0.0.0.0 (a --with-node hub keeps the relay on loopback behind kt_server)
check(re.search(r'MODE" = hub \] && \[ "\\?\$WITH_NODE" != 1 \] && export BIND_HOST=', SRC) is not None,
      'a --no-node hub binds the relay to 0.0.0.0; a --with-node hub keeps it on loopback')
# the tunnel-rebuild heartbeat must not fire for hub (there is no tunnel to rebuild)
check(re.search(r'"\$MODE" != direct \] && \[ "\$MODE" != hub \]', SRC) is not None,
      'hub is excluded from the tunnel-rebuild health loop (like direct)')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
