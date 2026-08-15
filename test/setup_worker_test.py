#!/usr/bin/env python3
# install-relay.sh --setup-worker is the one-command path that gives a node a short, stable address so
# it can be announced on the ledger. It drives `wrangler` and reads ids and URLs back out of that tool's
# human-readable output, which is exactly the kind of coupling that breaks quietly: a parse that picks
# the wrong 32-hex string still "succeeds", and the damage only shows up later as a worker answering
# 503 "no backend registered yet" with nothing pointing at the cause.
#
# So: run the REAL script against a stub `wrangler`, and assert on what it wrote.
#
# The create-output fixture below is the VERBATIM shape of wrangler 4.123.0 — JSON, not the toml
# snippet older versions printed. That distinction matters: the first version of this stub used the
# toml form, passed, and told us nothing about the format the tool actually emits.
#
#   python3 test/setup_worker_test.py
import os, shutil, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, 'relay', 'install-relay.sh')

# Real wrangler 4.123.0 output. Keep these verbatim — hand-tidying them is how the fixture drifts away
# from the tool and the test starts proving only that the stub agrees with itself.
CREATE_JSON = '''\\n ⛅️ wrangler 4.123.0\\n────────────────────\\nResource location: remote \\n
🌀 Creating namespace with title "$TITLE"\\n✨ Success!
To access your new KV Namespace in your Worker, add the following snippet to your configuration file:
{\\n  "kv_namespaces": [\\n    {\\n      "binding": "$TITLE",\\n      "id": "$KVID"\\n    }\\n  ]\\n}'''

STUB = r'''#!/bin/sh
# Stands in for `npx wrangler`. Cases are selected by STUB_* env vars.
while [ "$1" = "--yes" ] || [ "$1" = "wrangler" ]; do shift; done
KVID="${STUB_KV_ID:-16183313c75c4e21bad4894ad2b1927a}"

case "$1" in
  whoami) [ "${STUB_LOGGED_IN:-1}" = 1 ] || exit 1
          echo "👋 You are logged in with an OAuth Token, associated with the email t@example.com."
          exit 0 ;;
  login)  echo "Successfully logged in."; exit 0 ;;
esac

if [ "$1" = "kv" ] && [ "$2" = "namespace" ] && [ "$3" = "create" ]; then
    # Some wrangler builds print the ACCOUNT id first. Account ids are 32 hex too, so a parser that
    # takes "the first 32-hex run" binds the worker to the account and fails much later.
    [ "${STUB_ACCOUNT_FIRST:-0}" = 0 ] || echo 'Using account: throwaway (ffffffffffffffffffffffffffffffff)'
    if [ "${STUB_KV_GARBLED:-0}" = 1 ]; then
        echo '✨ Success!'; echo '(namespace id omitted in this wrangler build)'; exit 0
    fi
    printf '%s\n' "$STUB_CREATE_OUT"
    exit 0
fi

if [ "$1" = "deploy" ]; then
    [ "${STUB_DEPLOY_FAIL:-0}" = 0 ] || { echo '✘ [ERROR] Authentication error [code: 10000]' >&2; exit 1; }
    echo 'Total Upload: 1.53 KiB / gzip: 0.72 KiB'
    echo "Uploaded ${STUB_WORKER_NAME:-xc} (1.23 sec)"
    echo "Deployed ${STUB_WORKER_NAME:-xc} triggers (0.45 sec)"
    echo "  https://${STUB_HOST:-xc.throwaway-test.workers.dev}"
    echo 'Current Version ID: 8f7e6d5c-4b3a-2910-8f7e-6d5c4b3a2910'
    exit 0
fi

[ "$1" = "kv" ] && [ "$2" = "key" ] && { echo 'Writing the value to key "backend".'; exit 0; }
echo "stub: unhandled invocation: $*" >&2
exit 64
'''

KVID = '16183313c75c4e21bad4894ad2b1927a'
ACCOUNT_ID = 'ffffffffffffffffffffffffffffffff'
tmp = tempfile.mkdtemp(prefix='xc_setupworker_')
binp = os.path.join(tmp, 'bin')
os.makedirs(binp)
stub = os.path.join(binp, 'npx')
with open(stub, 'w') as f:
    f.write(STUB)
os.chmod(stub, 0o755)

fails = []


def run(case, **stub_env):
    """Run --setup-worker in a fresh relay home. Returns (returncode, output, worker.conf-or-None)."""
    home = os.path.join(tmp, 'home_' + case)
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home)
    if stub_env.pop('_reuse_conf', False):
        with open(os.path.join(home, 'worker.conf'), 'w') as f:
            f.write('WORKER_URL=https://xc.old.workers.dev\nKV_NAMESPACE_ID=%s\n' % KVID)
    with open(os.path.join(home, 'public-url.txt'), 'w') as f:
        f.write('https://four-random-words.trycloudflare.com\n')
    env = dict(os.environ)
    env['PATH'] = binp + os.pathsep + env['PATH']
    env['XC_RELAY_HOME'] = home
    # file:// so the worker source comes from this checkout: the test must not depend on the network,
    # and must exercise THIS tree's worker.js rather than whatever master happens to hold.
    env['XC_SRC'] = 'file://' + REPO
    env['STUB_CREATE_OUT'] = CREATE_JSON.replace('$TITLE', 'XCHAT_TEST').replace('$KVID', KVID)
    env.update({k: str(v) for k, v in stub_env.items()})
    p = subprocess.run(['sh', SCRIPT, '--setup-worker'], capture_output=True, text=True, env=env, timeout=120)
    conf_path = os.path.join(home, 'worker.conf')
    conf = open(conf_path).read() if os.path.exists(conf_path) else None
    return p.returncode, p.stdout + p.stderr, conf


def check(label, cond, detail=''):
    print(('  ok   ' if cond else '  FAIL ') + label + (('  -- ' + detail) if detail and not cond else ''))
    if not cond:
        fails.append(label)


print('happy path (real wrangler 4.123.0 JSON create output)')
rc, out, conf = run('happy')
check('exits 0', rc == 0, out[-400:])
check('parses the namespace id', conf is not None and ('KV_NAMESPACE_ID=' + KVID) in conf, str(conf))
check('parses the deployed URL', conf is not None and 'WORKER_URL=https://xc.throwaway-test.workers.dev' in conf, str(conf))
check('reports the on-chain budget', '29 of 32 bytes' in out, out[-300:])
check('fetches worker.js from the tree', os.path.exists(os.path.join(tmp, 'home_happy', 'cf-worker', 'src', 'worker.js')))

print('account id printed before the namespace id')
rc, out, conf = run('acct', STUB_ACCOUNT_FIRST=1)
check('picks the namespace id', conf is not None and ('KV_NAMESPACE_ID=' + KVID) in conf, str(conf))
check('does NOT pick the account id', conf is not None and ACCOUNT_ID not in conf, str(conf))

print('re-run with an existing worker.conf')
rc, out, conf = run('reuse', _reuse_conf=True)
check('exits 0', rc == 0, out[-300:])
check('reuses the namespace, creates no second one', 'Creating the KV namespace' not in out, out[-300:])

print('workers.dev host too long for the 32-byte on-chain link')
rc, out, conf = run('toolong', STUB_HOST='xchat-node.a-rather-long-account-name.workers.dev')
check('fails', rc != 0)
check('names the byte count', '49 bytes' in out, out[-300:])
check('advises a shorter --worker-name', '--worker-name' in out, out[-300:])
check('leaves no worker.conf', conf is None, str(conf))

print('wrangler prints no parseable namespace id')
rc, out, conf = run('garbled', STUB_KV_GARBLED=1)
check('fails', rc != 0)
check('leaves no worker.conf', conf is None, str(conf))

print('deploy fails')
rc, out, conf = run('deployfail', STUB_DEPLOY_FAIL=1)
check('fails', rc != 0)
check("surfaces wrangler's error", 'Authentication error' in out, out[-300:])
check('leaves no worker.conf', conf is None, str(conf))

print('not signed in')
rc, out, conf = run('nologin', STUB_LOGGED_IN=0)
check('runs the login step', 'Signing in to Cloudflare' in out, out[-300:])
check('then succeeds', rc == 0, out[-300:])

shutil.rmtree(tmp, ignore_errors=True)
print('\n%s' % ('FAILED: ' + ', '.join(fails) if fails else 'all setup-worker cases passed'))
sys.exit(1 if fails else 0)
