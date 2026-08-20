#!/usr/bin/env python3
"""The zero-flag default AUTO-PROMOTES instead of falling to a quick tunnel.

A quick tunnel churns its hostname every restart (so it can never be announced) and rate-limits into
hours of downtime. So a fresh `install-relay.sh` with no mode flag no longer defaults to it. Instead it
looks at what the box can do: a PUBLIC IP becomes a HUB (an entry other relays tunnel through); anything
behind NAT becomes a PUBLIC, self-healing MESH NODE. `--quick` still asks for the old Cloudflare tunnel.

This guards two things a refactor could silently break:
  1. the classifier boundaries (RFC1918 / CGNAT / loopback are private; a real public IP is public), and
  2. the ONE safety property — re-running the installer (that's how you --update) must inherit the mode a
     prior install chose and NEVER re-home a running relay to a different address.

Source-level like the other mode tests (relay_hub_mode, localhost_run_mode, tailscale_mode): a real
install stands up IPFS + a venv, which a unit test should not. We extract the two pure-shell pieces —
is_public_ip() and the mode-resolution block — and exercise them directly.

    python3 test/auto_promote_default_test.py
"""
import os, re, subprocess, sys, tempfile, textwrap

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'install-relay.sh')).read()

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

# ---- extract the exact shell we ship, so the test runs the real code, not a paraphrase ----
def slice_between(start, end_marker, label, include_end=False):
    """From the literal `start` up to `end_marker` (a literal string that follows the region)."""
    i = SRC.find(start)
    check(i != -1, f'found {label} start in install-relay.sh')
    if i == -1:
        return ''
    j = SRC.find(end_marker, i)
    check(j != -1, f'found {label} end in install-relay.sh')
    if j == -1:
        return ''
    return SRC[i:j + len(end_marker)] if include_end else SRC[i:j]

# is_public_ip(): from its `{` to the first line that is a lone `}` (the case arms have no bare brace).
IS_PUBLIC_FN = slice_between('is_public_ip() {', '\n}\n', 'is_public_ip()', include_end=True)
# The resolution block is bounded below by the comment that immediately follows it — a robust anchor
# that a nested `fi` inside the block would otherwise fool.
RESOLVE = slice_between("AUTO_PROMOTED=''", '\n# --public only means', 'mode-resolution block')

print('\n--- the flag and its docs exist ---')
check(re.search(r'--quick\)\s+USE_QUICK=1', SRC) is not None, '--quick maps to USE_QUICK=1')
check(re.search(r'elif \[ "\$USE_QUICK" = 1 \];\s*then MODE=quick', SRC) is not None,
      'USE_QUICK resolves to MODE=quick (the escape hatch back to the old default)')
check('AUTO-PROMOTES' in SRC or 'auto-promote' in SRC.lower(), 'the default is documented as auto-promote')

print('\n--- is_public_ip() classifies every boundary correctly ---')
IP_CASES = [
    ('', False), ('10.0.0.5', False), ('192.168.1.20', False), ('127.0.0.1', False),
    ('169.254.1.1', False), ('172.16.4.4', False), ('172.31.255.1', False),
    ('172.15.0.1', True), ('172.32.0.1', True),                       # just outside 172.16/12
    ('100.64.0.1', False), ('100.127.1.1', False),                   # CGNAT edges
    ('100.63.0.1', True), ('100.128.0.1', True),                     # just outside CGNAT
    ('203.0.113.4', True), ('8.8.8.8', True), ('1.1.1.1', True),
    ('fe80::1', False), ('not-an-ip', False),
]
harness = IS_PUBLIC_FN + '\nif is_public_ip "$1"; then echo public; else echo private; fi\n'
for ip, want_public in IP_CASES:
    out = subprocess.run(['sh', '-c', harness, '_', ip], capture_output=True, text=True).stdout.strip()
    got = (out == 'public')
    check(got == want_public, f'is_public_ip({ip!r}) -> {"public" if want_public else "private"}',
          f'got {out!r}')

print('\n--- the resolution block picks the right mode (fresh installs + updates) ---')
# Drive the real block with stubbed inputs. FAKE_IP feeds a stubbed detect_public_ip; run.sh presence
# simulates an update. We echo the outcome the installer would carry forward.
DRIVER = IS_PUBLIC_FN + '\n' + textwrap.dedent('''\
    detect_public_ip() { printf '%s' "$FAKE_IP"; }
    XC_HOME="$TMP"
    DOMAIN=''; TUNNEL_TOKEN=''
    USE_HUB=${USE_HUB:-0}; USE_MESH=${USE_MESH:-0}; USE_TAILSCALE=${USE_TAILSCALE:-0}
    USE_LHR=${USE_LHR:-0}; USE_QUICK=${USE_QUICK:-0}; PUBLIC=${PUBLIC:-0}
    ''') + RESOLVE + '\necho "$MODE $PUBLIC $AUTO_PROMOTED"\n'

def resolve(env, prev=None):
    with tempfile.TemporaryDirectory() as tmp:
        if prev is not None:
            open(os.path.join(tmp, 'run.sh'), 'w').write(prev)
        e = dict(os.environ, TMP=tmp, **{k: str(v) for k, v in env.items()})
        out = subprocess.run(['sh', '-c', DRIVER], capture_output=True, text=True, env=e).stdout.strip()
        mode, pub, auto = (out.split() + ['', '', ''])[:3]
        return mode, pub, auto

# fresh installs (no run.sh)
m, p, a = resolve({'FAKE_IP': '203.0.113.4'})
check((m, p, a) == ('hub', '0', 'hub'), 'fresh + public IP -> hub', f'{m} {p} {a}')
m, p, a = resolve({'FAKE_IP': '192.168.1.10'})
check((m, p, a) == ('mesh', '1', 'node'), 'fresh + NAT IP -> public mesh node', f'{m} {p} {a}')
m, p, a = resolve({'FAKE_IP': ''})
check((m, p, a) == ('mesh', '1', 'node'), 'fresh + no detectable IP -> public mesh node', f'{m} {p} {a}')

# explicit flags always win, and --mesh-tunnel is the private opt-out
m, p, a = resolve({'FAKE_IP': '192.168.1.10', 'USE_MESH': 1})
check((m, p) == ('mesh', '0'), 'explicit --mesh-tunnel -> PRIVATE node (not auto-listed)', f'{m} {p} {a}')
m, p, a = resolve({'FAKE_IP': '203.0.113.4', 'USE_QUICK': 1})
check(m == 'quick', 'explicit --quick -> quick even on a public box', f'{m} {p} {a}')
m, p, a = resolve({'FAKE_IP': '203.0.113.4', 'USE_HUB': 1})
check(m == 'hub', 'explicit --hub -> hub', f'{m} {p} {a}')
m, p, a = resolve({'FAKE_IP': '203.0.113.4', 'PUBLIC': 1})
check((m, p) == ('mesh', '1'), '--public alone -> public mesh node', f'{m} {p} {a}')

# UPDATE (run.sh already exists): inherit the prior mode, never silently re-home.
for prev_mode, prev_pub, ip, want in [
    ('quick', 0, '203.0.113.4', ('quick', '0')),   # a NAT'd quick install stays quick, not flipped to hub
    ('mesh',  1, '203.0.113.4', ('mesh', '1')),    # a public node stays a public node
    ('mesh',  0, '192.168.1.10', ('mesh', '0')),   # a PRIVATE node stays private
    ('hub',   0, '192.168.1.10', ('hub', '0')),    # a hub stays a hub
    ('lhr',   0, '192.168.1.10', ('lhr', '0')),
]:
    prev = f'MODE={prev_mode}\nPUBLIC={prev_pub}\n'
    m, p, a = resolve({'FAKE_IP': ip}, prev=prev)
    check((m, p) == want and a == '', f'update of a {prev_mode} install is inherited, not re-homed',
          f'{m} {p} {a}')

print()
if fails:
    print(f'FAIL — {checks} checks, {len(fails)} failure(s)')
    sys.exit(1)
print(f'PASS — {checks} checks, 0 failure(s)')
