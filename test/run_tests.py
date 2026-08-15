#!/usr/bin/env python3
# Run every test/*_test.py and summarise.
#
#   python3 test/run_tests.py              # everything
#   python3 test/run_tests.py -k interop   # only tests whose name matches
#   python3 test/run_tests.py --list       # names only, run nothing
#   python3 test/run_tests.py --timeout 60
#
# Two things this handles that running them by hand does not:
#
#   dart — the cross-language tests shell out to `dart`, which is NOT on PATH on a normal dev machine
#   here (Flutter lives in ~/flutter/bin). Without it e2e_test.py and interop_test.py fail with a bare
#   FileNotFoundError that looks like a code fault. Find the SDK and put it on PATH for the children;
#   if it genuinely isn't installed, say so once rather than reporting the same confusing error twice.
#
#   isolation — several tests start a real relay on a fixed port. They are run one at a time, never in
#   parallel, because two relays fighting over a port fail in ways that read as logic bugs.
#
# There is deliberately NO known-failures allowlist. A red suite should stay visibly red: an allowlist
# is how a real regression gets to hide behind an entry somebody added "for now" two years ago.
import argparse, glob, os, shutil, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DART_CANDIDATES = [
    os.path.expanduser('~/flutter/bin'),
    os.path.expanduser('~/development/flutter/bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
]


def dart_dir():
    """Directory holding a usable `dart`, or None. PATH wins; otherwise look where Flutter lands."""
    found = shutil.which('dart')
    if found:
        return os.path.dirname(found)
    for d in DART_CANDIDATES:
        if os.path.isfile(os.path.join(d, 'dart')) and os.access(os.path.join(d, 'dart'), os.X_OK):
            return d
    return None


def summarise(text):
    """Each test prints its own verdict; find that line rather than just taking the last one.

    Taking the last line naively picked up dart's "Running build hooks..." — written to stderr by the
    toolchain, after the test had already said what happened — so a red e2e run was labelled with build
    chatter instead of "FAILED — 13 checks, 7 failure(s)". Read stdout only, scan back for a line that
    states a verdict, and fall back to the last non-empty line.
    """
    lines = [l.rstrip() for l in text.strip().splitlines() if l.strip()]
    if not lines:
        return ''
    for line in reversed(lines):
        low = line.lower()
        if any(w in low for w in ('passed', 'failed', 'failure', 'pass —', 'all pass', 'skipping')):
            return line.strip()[:60]
    return lines[-1].strip()[:60]


def main():
    ap = argparse.ArgumentParser(description='run the xchat test suite')
    ap.add_argument('-k', metavar='PATTERN', help='only tests whose filename contains PATTERN')
    ap.add_argument('--timeout', type=int, default=300, help='per-test timeout in seconds (default 300)')
    ap.add_argument('--list', action='store_true', help='list the tests and exit')
    args = ap.parse_args()

    tests = sorted(glob.glob(os.path.join(REPO, 'test', '*_test.py')))
    if args.k:
        tests = [t for t in tests if args.k in os.path.basename(t)]
    if not tests:
        print('no tests matched' + (' -k %s' % args.k if args.k else ''))
        return 1
    if args.list:
        for t in tests:
            print(os.path.relpath(t, REPO))
        return 0

    env = dict(os.environ)
    dd = dart_dir()
    if dd:
        env['PATH'] = dd + os.pathsep + env['PATH']
        print('dart: %s' % os.path.join(dd, 'dart'))
    else:
        print('dart: NOT FOUND — cross-language tests will fail or self-skip.')
        print('      Install Flutter, or set PATH to include its bin/ directory.')
    print('running %d test%s\n' % (len(tests), '' if len(tests) == 1 else 's'))

    results = []
    for t in tests:
        name = os.path.basename(t)
        sys.stdout.write('  %-30s ' % name)
        sys.stdout.flush()
        t0 = time.time()
        try:
            # cwd=REPO so tests resolve repo-relative paths the same way they do when run by hand.
            p = subprocess.run([sys.executable, t], cwd=REPO, env=env,
                               capture_output=True, text=True, timeout=args.timeout)
            rc, out, own = p.returncode, p.stdout + p.stderr, p.stdout
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or '') + (e.stderr or '') + '\n[timed out after %ss]' % args.timeout
            rc, own = -1, (e.stdout or '')
        dt = time.time() - t0
        summary = summarise(own or out)
        print('%-5s %5.1fs  %s' % ('ok' if rc == 0 else 'FAIL', dt, summary))
        results.append((name, rc, out, dt))

    failed = [r for r in results if r[1] != 0]
    if failed:
        for name, rc, out, _ in failed:
            print('\n' + '=' * 72 + '\n%s (exit %s)\n' % (name, rc) + '=' * 72)
            # Enough context to act on without burying the summary of a long run.
            tail = out.strip().splitlines()[-40:]
            print('\n'.join(tail))
    total = time.time()
    print('\n%d/%d passed in %.1fs' % (len(results) - len(failed), len(results), sum(r[3] for r in results)))
    if failed:
        print('failed: ' + ', '.join(r[0] for r in failed))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
