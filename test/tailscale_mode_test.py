#!/usr/bin/env python3
# install-relay.sh --tailscale exposes the relay through Tailscale Funnel: a free, PERMANENT hostname
# for an operator who has no domain of their own. It exists because the default quick tunnel churns its
# name on every restart (so it can never be announced on-chain) and is rate-limited by Cloudflare with
# error 1015 — which cost a real operator hours of silent downtime.
#
# The risk here is the same shape as --setup-worker: this code reads a hostname out of another tool's
# output and then ANNOUNCES it on a public ledger, permanently. Announcing the wrong string is not a
# recoverable mistake, so the parse gets a test rather than a hope.
#
# So: run the REAL block from install-relay.sh against a stub `tailscale`, and assert on what it picked.
#
#   python3 test/tailscale_mode_test.py
import json, os, re, shutil, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, 'relay', 'install-relay.sh')

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


# The shape `tailscale status --json` actually returns. Self and Peer BOTH carry DNSName, and the KEY
# ORDER here is load-bearing: real tailscale emits Self BEFORE Peer, and there are usually several
# peers. Keep it that way.
#
# The first version of this fixture listed Peer first, and it proved nothing. sed's leading `.*` is
# greedy, so on one-line JSON it matches the LAST DNSName — which, with peers listed first, happened
# to be Self's. The broken parser passed. In the real order the same greedy match lands on the last
# PEER instead, and the relay would announce a neighbour's machine as its own address, permanently, on
# a public ledger. Order the fixture the way the tool actually prints it or it tests nothing.
def status_json(self_name='myrelay.tail1a2b3.ts.net.', logged_in=True):
    if not logged_in:
        return json.dumps({'BackendState': 'NeedsLogin', 'Self': None, 'Peer': {}})
    return json.dumps({
        'Version': '1.80.0',
        'BackendState': 'Running',
        'Self': {'DNSName': self_name, 'HostName': self_name.split('.')[0]},
        'MagicDNSSuffix': 'tail1a2b3.ts.net',
        'Peer': {
            'nodekey:aaa': {'DNSName': 'someone-elses-laptop.tail1a2b3.ts.net.',
                            'HostName': 'someone-elses-laptop'},
            'nodekey:bbb': {'DNSName': 'zzz-last-peer.tail1a2b3.ts.net.',
                            'HostName': 'zzz-last-peer'},
        },
    })


STUB = r'''#!/bin/sh
# Stands in for `tailscale`. Cases selected by STUB_* env vars.
case "$1" in
  status)
      cat "$STUB_STATUS_FILE"
      exit 0 ;;
  funnel)
      if [ "${STUB_FUNNEL_OK:-1}" != 1 ]; then
          echo "Funnel is not enabled for this tailnet." >&2
          exit 1
      fi
      # record how we were invoked so the test can assert the port
      echo "$@" > "$STUB_FUNNEL_ARGS"
      exit 0 ;;
esac
exit 0
'''

# The tailscale branch, lifted VERBATIM out of the installer. Extracting it rather than re-typing it
# is the whole point: a hand-copied duplicate would keep passing after the real script changed.
src = open(SCRIPT).read()
m = re.search(r'^    elif \[ "\$MODE" = tailscale \]; then\n(.*?)^    elif \[ "\$MODE" = \w+ \]; then',
              src, re.S | re.M)
if not m:
    sys.exit('could not find the tailscale branch in install-relay.sh — did it move?')
BLOCK = m.group(1)
check(len(BLOCK.splitlines()) > 10, 'extracted the real tailscale branch from install-relay.sh',
      f'{len(BLOCK.splitlines())} lines')


def run(logged_in=True, installed=True, funnel_ok=True, self_name='myrelay.tail1a2b3.ts.net.',
        with_node=1, port='7401', node_port='8790'):
    tmp = tempfile.mkdtemp(prefix='xc_ts_')
    binp = os.path.join(tmp, 'bin')
    os.makedirs(binp)
    statusf = os.path.join(tmp, 'status.json')
    argsf = os.path.join(tmp, 'funnel_args.txt')
    open(statusf, 'w').write(status_json(self_name, logged_in))
    if installed:
        p = os.path.join(binp, 'tailscale')
        open(p, 'w').write(STUB)
        os.chmod(p, 0o755)
    # `continue`/`sleep` only make sense inside the installer's supervisor loop; give them one.
    harness = f'''#!/bin/sh
set -u
XC_HOME="{tmp}"
PORT="{port}"; NODE_PORT="{node_port}"; WITH_NODE={with_node}
PY="{sys.executable}"
MODE=tailscale
URL=''; CF_PID='x'
sleep() {{ :; }}                 # the real block sleeps 60s before retrying; not in a test
log() {{ echo "LOG $*" >> "$XC_HOME/log.txt"; }}
for _once in 1; do
{BLOCK}
done
echo "RESULT_URL=$URL"
echo "RESULT_CFPID=$CF_PID"
'''
    hp = os.path.join(tmp, 'h.sh')
    open(hp, 'w').write(harness)
    # The "not installed" case has to mean it, and inheriting the caller's PATH does not: the moment
    # a developer installs tailscale for real (which is the likely reason they are touching this file
    # at all) `command -v tailscale` starts finding /opt/homebrew/bin/tailscale and the case silently
    # stops testing anything. Caught exactly that way. A minimal PATH is the only honest way to say
    # "absent" — tailscale is never shipped in /usr/bin or /bin.
    path = binp + os.pathsep + ('/usr/bin' + os.pathsep + '/bin' if not installed
                                else os.environ['PATH'])
    env = {**os.environ,
           'PATH': path,
           'STUB_STATUS_FILE': statusf,
           'STUB_FUNNEL_ARGS': argsf,
           'STUB_FUNNEL_OK': '1' if funnel_ok else '0'}
    r = subprocess.run(['sh', hp], capture_output=True, text=True, env=env, timeout=60)
    logs = open(os.path.join(tmp, 'log.txt')).read() if os.path.exists(os.path.join(tmp, 'log.txt')) else ''
    fargs = open(argsf).read().strip() if os.path.exists(argsf) else ''
    url = (re.search(r'RESULT_URL=(\S*)', r.stdout) or [None, ''])[1] if 'RESULT_URL=' in r.stdout else ''
    cfpid = re.search(r'RESULT_CFPID=(\S*)', r.stdout)
    shutil.rmtree(tmp, ignore_errors=True)
    return {'url': url, 'logs': logs, 'funnel_args': fargs, 'stderr': r.stderr,
            'cfpid': cfpid.group(1) if cfpid else None}


# ---- the happy path -------------------------------------------------------
r = run()
check(r['url'] == 'https://myrelay.tail1a2b3.ts.net',
      'picks SELF\'s hostname, not a peer\'s, and strips the trailing dot', r['url'])
check('someone-elses' not in r['url'], 'never announces another machine on the tailnet', r['url'])
check(r['funnel_args'].split()[-1] == '8790',
      'funnels the NODE port when a node is running (the app needs /api)', r['funnel_args'])
check('--bg' in r['funnel_args'], 'runs funnel in the background so it outlives this shell', r['funnel_args'])
check(r['cfpid'] == '', 'clears CF_PID — funnel has no cloudflared child of ours to supervise', r['cfpid'])

# The URL is announced on-chain, packed as ASCII into a 32-byte block link. A name that does not fit
# cannot be announced at all, which is the whole reason this mode exists.
host = r['url'].replace('https://', '')
check(len(host.encode()) <= 32, 'the resulting host fits the 32-byte on-chain link',
      f'{len(host.encode())} bytes: {host}')

# ---- relay-only install ---------------------------------------------------
r = run(with_node=0)
check(r['funnel_args'].split()[-1] == '7401', 'funnels the RELAY port when there is no node',
      r['funnel_args'])

# ---- tailscale missing ----------------------------------------------------
# Guard the guard: if a future PATH change let a real tailscale back in, the two checks below would
# pass for the wrong reason. Prove absence first.
probe = subprocess.run(['sh', '-c', 'command -v tailscale || true'], capture_output=True, text=True,
                       env={**os.environ, 'PATH': '/usr/bin:/bin'})
check(probe.stdout.strip() == '', 'the "absent" case really has no tailscale on PATH',
      probe.stdout.strip())
r = run(installed=False)
check(r['url'] == '', 'no URL invented when tailscale is not installed', r['url'])
check('not installed' in r['logs'], 'says tailscale is not installed', r['logs'][:120])

# ---- installed but not logged in -----------------------------------------
r = run(logged_in=False)
check(r['url'] == '', 'no URL when not logged in', r['url'])
check('not logged in' in r['logs'], 'says to run `tailscale up`', r['logs'][:120])

# ---- funnel refused (not enabled for the tailnet) ------------------------
r = run(funnel_ok=False)
check('funnel refused' in r['logs'], 'reports a refused funnel rather than announcing a dead address',
      r['logs'][:160])
check('admin console' in r['logs'], 'points at the setting that actually fixes it', r['logs'][:200])
# The important part: a refused funnel must NOT leave a usable-looking URL behind, or the relay would
# announce an address that routes nowhere — permanently, on the ledger.
check(not r['url'].startswith('https://'),
      'a refused funnel leaves NO announceable URL', r['url'])

# ---- a long tailnet name is caught, not silently truncated ----------------
r = run(self_name='a-very-long-machine-name.tail1a2b3c4d5e.ts.net.')
host = r['url'].replace('https://', '')
check(len(host.encode()) > 32, 'fixture really is over the on-chain limit', f'{len(host.encode())} bytes')
print(f'      (note: {host} is {len(host.encode())} bytes — url_to_link refuses >32, so the announce '
      f'fails loudly rather than committing a truncated host)')

print()
print(f'{"PASS" if not fails else "FAIL"} — {checks} checks, {len(fails)} failure(s)')
for f in fails:
    print('  -', f)
sys.exit(1 if fails else 0)
