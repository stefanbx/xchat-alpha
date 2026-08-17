#!/usr/bin/env python3
"""The Cloudflare Worker front, and the silent failure that took a node off the air for a day.

The worker is a stable, short workers.dev hostname that reverse-proxies to a home relay whose quick
tunnel churns its name on every restart. The announced-on-chain address is the WORKER's, and the
current tunnel URL lives in the worker's KV, re-pushed by the relay each time it starts.

What went wrong, in order:

  1. the Cloudflare OAuth token wrangler uses expired
  2. every KV push after that failed with "Authentication error [code: 10000]"
  3. the push ran in a background subshell whose exit status nobody checked, and whose output went
     to a log nobody reads
  4. the tunnel went on churning, so KV kept pointing at a hostname that no longer resolved
  5. the worker faithfully proxied to it and Cloudflare answered 530 to every client
  6. `--status` printed a GREEN TICK next to the worker URL the whole time, because all it did was
     read the address out of worker.conf

This is the same shape as the tunnel bug already fixed in this file's subject: a live tunnel is not a
working tunnel, and a configured address is not a working address. Anything that can silently stop
being true has to be probed.

So these tests run the REAL kv_push out of install-relay.sh against a stub `npx`, and assert on the
source of the status and heartbeat paths.

    python3 test/worker_front_test.py
"""
import os, re, subprocess, sys, tempfile

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


def kv_push_body():
    """The real function, lifted from the installer so the test cannot drift from what ships."""
    m = re.search(r'^kv_push\(\) \{.*?^\}', SRC, re.S | re.M)
    assert m, 'kv_push() not found in install-relay.sh — renamed?'
    return m.group(0)


def run_push(npx_behaviour, prior_log=''):
    """Run kv_push with a stub npx. Returns (exit_code, kv_failed_contents, log_contents)."""
    home = tempfile.mkdtemp(prefix='xcworker-')
    binp = os.path.join(home, 'bin')
    os.makedirs(binp)
    with open(os.path.join(binp, 'npx'), 'w') as f:
        f.write(npx_behaviour)
    os.chmod(os.path.join(binp, 'npx'), 0o755)
    if prior_log:
        open(os.path.join(home, 'kv-update.log'), 'w').write(prior_log)
    script = f'''
XC_HOME="{home}"
PATH="{binp}:$PATH"
{kv_push_body()}
kv_push "ns-123" "https://tunnel-abc.trycloudflare.com"
'''
    p = subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=60)
    failed = os.path.join(home, 'kv-failed')
    log = os.path.join(home, 'kv-update.log')
    return (p.returncode,
            open(failed).read().strip() if os.path.exists(failed) else None,
            open(log).read() if os.path.exists(log) else '')


print('--- a successful push ---')
code, failed, log = run_push('#!/bin/sh\nexit 0\n')
check(code == 0, 'succeeds when wrangler succeeds')
check(failed is None, 'leaves no kv-failed marker behind')
check('backend -> https://tunnel-abc.trycloudflare.com' in log,
      'records WHICH url it pointed at, so the log can be read after the fact')

print('\n--- a push that fails on auth ---')
AUTH_FAIL = '''#!/bin/sh
echo "A request to the Cloudflare API (/accounts/x/storage/kv/...) failed."
echo "  Authentication error [code: 10000]"
exit 1
'''
code, failed, log = run_push(AUTH_FAIL)
check(code != 0, 'reports failure through its exit status, not just into a log')
check(failed is not None, 'writes a kv-failed marker --status can find')
check('wrangler login' in (failed or ''),
      'names the REMEDY, not just the symptom', failed)
check('expired' in (failed or '').lower(),
      'names the likely cause in plain words', failed)

print('\n--- a push that fails some other way ---')
code, failed, log = run_push('#!/bin/sh\necho "boom"\nexit 1\n')
check(code != 0, 'a non-auth failure is still a failure')
check(failed is not None and 'wrangler login' not in failed,
      'does not blame the login when the login is not the problem', failed)
check('kv-update.log' in (failed or ''), 'points at the log for the details', failed)

print('\n--- recovery clears the alarm ---')
# A stale kv-failed marker would make --status cry wolf forever after one bad night.
home = tempfile.mkdtemp(prefix='xcworker-')
binp = os.path.join(home, 'bin'); os.makedirs(binp)
open(os.path.join(binp, 'npx'), 'w').write('#!/bin/sh\nexit 0\n')
os.chmod(os.path.join(binp, 'npx'), 0o755)
open(os.path.join(home, 'kv-failed'), 'w').write('Cloudflare login expired — run: ...\n')
subprocess.run(['sh', '-c', f'XC_HOME="{home}"\nPATH="{binp}:$PATH"\n{kv_push_body()}\n'
                            f'kv_push ns https://new.trycloudflare.com'],
               capture_output=True, text=True, timeout=60)
check(not os.path.exists(os.path.join(home, 'kv-failed')),
      'a later success removes the marker')

print('\n--- an auth error from a PREVIOUS run does not poison a new diagnosis ---')
# kv_push greps the log to classify the failure, and the log is append-only across restarts. A
# months-old auth error must not relabel today's unrelated failure as an expired login.
code, failed, log = run_push('#!/bin/sh\necho "network unreachable"\nexit 1\n',
                             prior_log='Authentication error [code: 10000]\n')
check(failed is not None and 'wrangler login' not in failed,
      'classifies THIS failure, not one from the log history', failed)

print('\n--- --status probes the address instead of trusting the file ---')
status = re.search(r'ACTION\b.*', SRC, re.S).group(0)
check('curl -fsS -m 12 -o /dev/null "$WORKER_URL/heads"' in SRC,
      'status actually requests the worker URL')
check('is NOT answering' in SRC,
      'says plainly that an announced-but-dead address is unreachable')
check(re.search(r'ok "stable address: \$WORKER_URL \(answering\)"', SRC) is not None,
      'the green tick is only printed AFTER a successful probe')
check(SRC.count('ok "stable address:') == 1,
      'there is no second, unprobed place that prints the tick')
check('cat "$XC_HOME/kv-failed"' in SRC,
      'status surfaces the recorded cause when there is one')

print('\n--- the heartbeat re-points a stale front by itself ---')
check('announced address not answering' in SRC,
      'the watch loop probes the ANNOUNCED address, not only the tunnel')
check(re.search(r'kv_push "\$KV_NAMESPACE_ID" "\$URL"\s*\\\s*\n\s*&& log "worker backend re-pointed"', SRC)
      is not None,
      're-pushes KV when the front is stale but the tunnel is fine')
# The death-spiral guard. Rebuilding the tunnel cannot fix an expired login, and doing it on this
# branch would churn the hostname forever while the real fault persisted — the exact failure mode the
# tunnel backoff was added to stop.
hb = SRC[SRC.find('announced address not answering') - 1200:
         SRC.find('announced address not answering') + 600]
check('rebuilding it' not in hb,
      'a stale FRONT never triggers a tunnel rebuild — the tunnel is not what is broken')
check('Never rebuild' in SRC or 'never rebuild' in SRC,
      'and the reason is written down next to the code')

print('\n--- run.sh must DEFINE every local function it CALLS ---')
# The bug that kept an operator down: kv_push was defined at the top of install-relay.sh but CALLED
# only inside the generated run.sh supervisor. The installer runs fine; the supervisor does not — it
# hits "kv_push: not found" on every tunnel churn and the worker never re-points, serving 530 forever
# while --status looks healthy. The earlier tests ran kv_push in isolation and never noticed it was
# missing from the one script that actually calls it.
#
# So: extract the run.sh heredoc, and assert every locally-defined helper the supervisor calls is also
# defined WITHIN the supervisor. This is the general invariant, and it would have caught the bug.
_m = re.search(r"cat >> \"\$XC_HOME/run\.sh\" <<'EOF'\n(.*?)\n^EOF$", SRC, re.S | re.M)
check(_m is not None, 'found the run.sh heredoc (renamed? update this test)')
if _m:
    runsh = _m.group(1)
    all_funcs = set(re.findall(r'(?m)^([a-z_][a-z0-9_]*)\(\)\s*\{', SRC))
    runsh_defs = set(re.findall(r'(?m)^([a-z_][a-z0-9_]*)\(\)\s*\{', runsh))

    def is_called_in(name, text):
        # the function name as a COMMAND: at a statement start, not as its own definition or a substring
        for m in re.finditer(r'(?:^|;|&&|\|\||\bthen\b|\belse\b|\bdo\b|\()\s*(%s)\b' % re.escape(name),
                             text, re.M):
            line = text[text.rfind('\n', 0, m.start()) + 1: text.find('\n', m.start())]
            if name + '()' in line:          # the definition line itself
                continue
            if line.lstrip().startswith('#'):  # a comment
                continue
            return True
        return False

    missing = sorted(f for f in all_funcs
                     if is_called_in(f, runsh) and f not in runsh_defs)
    check(not missing,
          'every local function the supervisor calls is defined inside run.sh',
          'missing from run.sh: ' + ', '.join(missing) if missing else '')
    # Name kv_push explicitly, since it is the one that regressed and the one operators depend on.
    check('kv_push' in runsh_defs,
          'kv_push is defined inside run.sh (the supervisor calls it on churn to re-point the worker)')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
