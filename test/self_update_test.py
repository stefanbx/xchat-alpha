#!/usr/bin/env python3
# install-relay.sh refreshes ITSELF during --update. It used to do that by writing straight over the
# file, which is a bug with a coin-flip failure mode: `sh` reads a script incrementally and seeks by
# byte offset, so overwriting the file mid-run makes the shell resume reading DIFFERENT bytes at the
# same offset. The observed symptom is a syntax error on a line that is valid in both the old and the
# new file — and it only stays hidden while the two versions happen to be the same length, which the
# next release never is.
#
# It bit the maintainer's own relay: the update died at `syntax error near unexpected token 'fi'`,
# leaving the relay stopped and the node gone.
#
# The fix is temp-file + atomic mv: mv swaps the directory entry while the running shell keeps its
# open inode, so it finishes reading the bytes it started with.
#
# This test reproduces the mechanism directly rather than trusting the reasoning, because `sh -n`
# passes on BOTH the old and new file — static checking cannot see this class of bug at all.
#
#   python3 test/self_update_test.py
import os, shutil, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, 'relay', 'install-relay.sh')

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


# A script long enough that sh must read it in more than one chunk, which is what makes the offset
# matter. It rewrites itself part-way through and then has to keep executing.
FILLER = '\n'.join(f'# padding line {i} ' + 'x' * 80 for i in range(400))


def run_case(rewrite):
    """rewrite: 'inplace' (the old bug) or 'atomic' (temp + mv). Returns (exit_code, stderr)."""
    d = tempfile.mkdtemp(prefix='xc_selfupd_')
    me = os.path.join(d, 'me.sh')
    # The "new version" is deliberately a DIFFERENT length, exactly as a real release is.
    newer = os.path.join(d, 'newer.sh')
    open(newer, 'w').write('#!/bin/sh\n' + FILLER + '\n' * 50 + 'echo NEW\n')

    if rewrite == 'inplace':
        swap = f'cat "{newer}" > "$0"'
    else:
        swap = f'cp "{newer}" "$0.new" && mv -f "$0.new" "$0"'

    body = f'''#!/bin/sh
set -eu
{FILLER}
{swap}
{FILLER}
if [ 1 = 1 ]; then
    echo REACHED_END
fi
'''
    open(me, 'w').write(body)
    os.chmod(me, 0o755)
    p = subprocess.run(['sh', me], capture_output=True, text=True, timeout=60)
    shutil.rmtree(d, ignore_errors=True)
    return p.returncode, (p.stdout or '') + (p.stderr or '')


# ---- the mechanism, demonstrated ------------------------------------------
rc_bad, out_bad = run_case('inplace')
rc_good, out_good = run_case('atomic')

check(rc_bad != 0 or 'REACHED_END' not in out_bad,
      'writing over a running script CORRUPTS it (the bug being fixed)',
      f'rc={rc_bad} out={out_bad.strip()[:80]!r}')
check(rc_good == 0 and 'REACHED_END' in out_good,
      'temp-file + atomic mv lets the running script finish intact',
      f'rc={rc_good} out={out_good.strip()[:80]!r}')

# ---- and the real installer uses the safe form ----------------------------
src = open(SCRIPT).read()
check('fetch "$SRC/relay/install-relay.sh" "$SELF"' not in src,
      'install-relay.sh no longer fetches directly over itself')
check('mv -f "$_self_new" "$SELF"' in src,
      'it installs its own update through an atomic mv')
# Refusing to install a truncated download matters more here than anywhere else: this file IS the
# recovery tool, so a half-written copy leaves the operator with no way to repair the relay.
check('sh -n "$_self_new"' in src,
      'the downloaded installer is syntax-checked before replacing the working one')

# ---- --update must not silently change what the operator chose ------------
# A relay installed --with-node came back from an update with WITH_NODE=0: kt_server gone, the tunnel
# pointed at the relay instead of the node, every /api path 404ing. From outside that is
# indistinguishable from a broken tunnel, which is how it survived on the maintainer's own relay.
# --update is documented as keeping your setup; this is the part of that promise that was false.
import re                                                          # noqa: E402
head = src.split('# ---------------------------------------------------------------- preflight')[0]
head = head.replace('set -eu', 'set -u')


def with_node(prev, args):
    d = tempfile.mkdtemp(prefix='xc_wn_')
    if prev is not None:
        open(os.path.join(d, 'run.sh'), 'w').write(f'#!/bin/sh\n{prev}\nPORT=7401\n')
    f = os.path.join(d, 'h.sh')
    open(f, 'w').write(head + '\necho "WITH_NODE=$WITH_NODE"\n')
    p = subprocess.run(['sh', f] + args, capture_output=True, text=True,
                       env={**os.environ, 'XC_RELAY_HOME': d, 'XC_WITH_NODE': ''}, timeout=60)
    shutil.rmtree(d, ignore_errors=True)
    m = re.search(r'WITH_NODE=([01])', p.stdout)
    return m.group(1) if m else '?'


for prev, args, want, label in [
    ('WITH_NODE=1', [], '1', 'an existing --with-node install is INHERITED across --update'),
    ('WITH_NODE=0', [], '0', 'an existing --no-node install stays off'),
    ('WITH_NODE=1', ['--no-node'], '0', 'an explicit --no-node still overrides the inherited value'),
    ('WITH_NODE=0', ['--with-node'], '1', 'an explicit --with-node still wins'),
    (None, [], '1', 'a fresh install (no run.sh) defaults to a NODE (every relay serves /api)'),
]:
    got = with_node(prev, args)
    check(got == want, label, f'got {got}, want {want}')

print()
print(f'{"PASS" if not fails else "FAIL"} — {checks} checks, {len(fails)} failure(s)')
for f in fails:
    print('  -', f)
sys.exit(1 if fails else 0)
