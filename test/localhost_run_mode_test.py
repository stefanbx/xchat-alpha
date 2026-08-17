#!/usr/bin/env python3
"""install-relay.sh --localhost-run: a free SSH reverse tunnel, no account and no Cloudflare.

This exists because every Cloudflare failure mode we hit in one day — the quick-tunnel 1015 rate
limit, an account request-limit, and the worker/KV/wrangler layer breaking — came from depending on
Cloudflare to give a home relay a stable public address. localhost.run needs none of it: the relay
dials OUT over SSH (works behind NAT and a changing home IP), and the name it hands back is SHORT
enough to announce on-chain directly, so there is no worker front to break.

The risk, same as the tailscale mode: this reads a hostname out of another tool's output and then
ANNOUNCES it on a public ledger. Announcing the wrong string, or one too long for the 32-byte link,
is not recoverable — so the parse and the length get a test, not a hope.

Runs the REAL lhr branch lifted out of install-relay.sh against a stub `ssh`.

    python3 test/localhost_run_mode_test.py
"""
import os, re, shutil, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, 'relay', 'install-relay.sh')
SRC = open(SCRIPT).read()

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


# The banner localhost.run actually prints. The URL appears at the end of the "tunneled with tls"
# line; earlier lines mention the connection id and must NOT be mistaken for it.
def stub_ssh(host='d34db33f.lhr.life'):
    # The REAL localhost.run banner, captured live. The doc links (admin.localhost.run,
    # localhost.run/docs) are the trap: the first version of the parser matched *.localhost.run and
    # grabbed https://admin.localhost.run instead of the tunnel. Reproduced here so the test would
    # have caught it.
    return f'''#!/bin/sh
echo "Warning: Permanently added 'localhost.run' (ED25519) to the list of known hosts." >&2
echo "==============================================================================="
echo "Welcome to localhost.run!"
echo "To set up and manage custom domains go to https://admin.localhost.run/"
echo "More details on custom domains at https://localhost.run/docs/custom-domains"
echo "To explore using localhost.run visit the documentation site:"
echo "https://localhost.run/docs/"
echo "==============================================================================="
echo "** your connection id is 1.2.3.4:5678, please mention it if you send a message about an issue. **"
echo "authn: authenticated as anonymous user"
echo "{host} tunneled with tls termination, https://{host}"
echo "create an account and add your key for a longer lasting domain name."
sleep 15
'''

STUB_SSH_FAIL = '''#!/bin/sh
echo "ssh: could not resolve hostname localhost.run" >&2
exit 255
'''

# The lhr branch, lifted VERBATIM from the installer. Extracting beats re-typing: a hand-copy keeps
# passing after the real script changes.
m = re.search(r'^    elif \[ "\$MODE" = lhr \]; then\n(.*?)^    elif \[ "\$MODE" = named \]; then',
              SRC, re.S | re.M)
if not m:
    sys.exit('could not find the lhr branch in install-relay.sh — did it move?')
BLOCK = m.group(1)
check(len(BLOCK.splitlines()) > 15, 'extracted the real lhr branch from install-relay.sh',
      f'{len(BLOCK.splitlines())} lines')


def run(ssh_stub=None, have_ssh=True, with_node=1, port='7401', node_port='8790'):
    tmp = tempfile.mkdtemp(prefix='xc_lhr_')
    binp = os.path.join(tmp, 'bin')
    os.makedirs(binp)
    if have_ssh:
        p = os.path.join(binp, 'ssh')
        open(p, 'w').write(ssh_stub if ssh_stub is not None else stub_ssh())
        os.chmod(p, 0o755)
    harness = f'''#!/bin/sh
set -u
XC_HOME="{tmp}"
PORT="{port}"; NODE_PORT="{node_port}"; WITH_NODE={with_node}
MODE=lhr
URL=''; CF_PID='x'; TFAIL=0
# Sleep for real on the SHORT poll interval (the loop waits ~1s for the backgrounded ssh to print its
# URL), but skip the long 15s+ backoff so a failing case does not stall the test.
sleep() {{ case "${{1:-0}}" in 1|2|3) command sleep "$1";; *) :;; esac; }}
log() {{ echo "LOG $*" >> "$XC_HOME/log.txt"; }}
for _once in 1; do
{BLOCK}
done
echo "RESULT_URL=$URL"
echo "RESULT_CFPID=$CF_PID"
echo "RESULT_PORT=$TUNNEL_PORT"
[ -n "$CF_PID" ] && [ "$CF_PID" != x ] && kill "$CF_PID" 2>/dev/null || :   # reap the stub ssh
'''
    hp = os.path.join(tmp, 'h.sh')
    open(hp, 'w').write(harness)
    # A minimal PATH when "ssh absent" is the case, or the developer's real ssh silently satisfies it.
    path = binp + os.pathsep + ('/usr/bin' + os.pathsep + '/bin' if not have_ssh else os.environ['PATH'])
    env = {**os.environ, 'PATH': path}
    r = subprocess.run(['sh', hp], capture_output=True, text=True, env=env, timeout=60)
    logs_p = os.path.join(tmp, 'log.txt')
    logs = open(logs_p).read() if os.path.exists(logs_p) else ''
    url = (re.search(r'RESULT_URL=(\S*)', r.stdout) or [None, ''])[1] if 'RESULT_URL=' in r.stdout else ''
    cfpid = (re.search(r'RESULT_CFPID=(\S*)', r.stdout) or [None, ''])
    tport = (re.search(r'RESULT_PORT=(\S*)', r.stdout) or [None, ''])
    shutil.rmtree(tmp, ignore_errors=True)
    return {'url': url, 'logs': logs, 'stdout': r.stdout, 'stderr': r.stderr,
            'cfpid': cfpid[1] if 'RESULT_CFPID=' in r.stdout else None,
            'port': tport[1] if 'RESULT_PORT=' in r.stdout else None}


print('\n--- the happy path ---')
r = run()
check(r['url'] == 'https://d34db33f.lhr.life',
      'parses the lhr.life URL from the banner, not the connection id', r['url'])
check(r['cfpid'] not in ('', 'x', None),
      'CF_PID holds the ssh child, so the supervisor can watch and restart it', r['cfpid'])
check(r['port'] == '8790',
      'tunnels the NODE port when a node runs (the app needs /api)', r['port'])

# The URL is announced on-chain, packed as ASCII into a 32-byte block link. This is the whole reason
# localhost.run beats a quick tunnel: its name is short enough to announce DIRECTLY, no worker front.
host = r['url'].replace('https://', '')
check(len(host.encode()) <= 32, 'the lhr host fits the 32-byte on-chain link — no worker front needed',
      f'{len(host.encode())} bytes: {host}')

print('\n--- it does not grab a banner link instead of the tunnel URL (the real bug) ---')
# The banner prints https://admin.localhost.run and https://localhost.run/docs BEFORE the tunnel URL.
# This is the exact mistake the real test caught: match *.localhost.run and you announce a doc link.
r = run(ssh_stub=stub_ssh('abc123def.lhr.life'))
check(r['url'] == 'https://abc123def.lhr.life',
      'picks the *.lhr.life tunnel, never admin.localhost.run from the banner', r['url'])
check('localhost.run' not in r['url'].replace('lhr.life', ''),
      'the announced URL is not a documentation link', r['url'])

print('\n--- connects as the anonymous user (a plain key is rejected by localhost.run) ---')
# Verified against the real service: the default user answers "Permission denied (publickey)". nokey@
# is the free keyless entry point.
check('nokey@localhost.run' in BLOCK, 'the branch dials nokey@localhost.run, not the default user')

print('\n--- relay-only install tunnels the relay port ---')
r = run(with_node=0)
check(r['port'] == '7401', 'no node → tunnel the relay port', r['port'])

print('\n--- ssh missing is handled (source: ssh is ubiquitous, so this cannot be isolated at runtime) ---')
# /usr/bin/ssh exists on every dev machine and CI box, so a runtime "ssh absent" case would silently
# find the real ssh — the same trap the tailscale test calls out. Pin the guard by inspection instead.
check('command -v ssh >/dev/null 2>&1' in BLOCK, 'the branch checks for ssh before using it')
check('ssh is not installed' in BLOCK, 'and says so, with how to install it, rather than failing blind')

print('\n--- ssh failing to connect backs off instead of spinning ---')
r = run(ssh_stub=STUB_SSH_FAIL)
check(r['url'] == '', 'a failed dial yields no URL')
check('did not come up' in r['logs'], 'and logs the failure with the tunnel output', r['logs'][:200])

print('\n--- the operator is told how to pin a permanent name ---')
r = run()
check('forever-free' in r['logs'],
      'points at localhost.run forever-free so a churning name can be made permanent', r['logs'][:200])

print('\n--- the flag maps to the mode, and the branch lives in run.sh ---')
check('--localhost-run)' in SRC and 'USE_LHR=1' in SRC, '--localhost-run sets USE_LHR')
check(re.search(r'elif \[ "\$USE_LHR" = 1 \];\s*then MODE=lhr', SRC) is not None,
      'USE_LHR selects MODE=lhr in the dispatch')
_hd = re.search(r"cat >> \"\$XC_HOME/run\.sh\" <<'EOF'\n(.*?)\n^EOF$", SRC, re.S | re.M)
check(_hd is not None and 'MODE" = lhr' in _hd.group(1),
      'the lhr branch is written INTO run.sh, so the supervisor actually runs it')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
