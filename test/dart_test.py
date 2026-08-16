#!/usr/bin/env python3
# Run the app's Dart tests as part of the ONE suite.
#
# They existed for a long time and never ran here: run_tests.py globs test/*_test.py, and the Dart
# tests live under app/test/. The cost of that showed up exactly as you'd expect — wallet_test.dart's
# "canonical messages are byte-exact" had been failing since the v2 signing preimage landed (issue #7),
# asserting the old bare "|"-join format, and nobody saw it. A test nothing runs is a comment.
#
# Skips (exit 0) rather than fails when Flutter is absent, so the Python suite still runs on a machine
# without it — the CI workflow installs Flutter, so it does not skip there.
#
#   python3 test/dart_test.py
import os, shutil, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(REPO, 'app')


def flutter():
    exe = shutil.which('flutter')
    if exe:
        return exe
    guess = os.path.expanduser('~/flutter/bin/flutter')
    return guess if os.path.exists(guess) else None


fl = flutter()
if not fl:
    print('SKIP — flutter not found (install it, or add ~/flutter/bin to PATH)')
    sys.exit(0)
if not os.path.isdir(os.path.join(APP, 'test')):
    print('SKIP — no app/test directory')
    sys.exit(0)

p = subprocess.run([fl, 'test', '--reporter', 'compact'], cwd=APP,
                   capture_output=True, text=True, timeout=1200)
out = (p.stdout or '') + (p.stderr or '')

# `flutter test` is noisy on first run (pub resolution, version nags). Keep the lines that carry a
# result so a failure is readable in the suite's summary without scrolling past dependency chatter.
lines = [l for l in out.splitlines()
         if ('All tests passed' in l or 'Some tests failed' in l or '[E]' in l
             or l.startswith('Failing tests:') or l.strip().startswith('/'))]
tail = [l for l in lines if l.strip()][-12:]

if p.returncode == 0:
    passed = ''
    for l in out.splitlines():
        if 'All tests passed' in l:
            passed = l.strip()
    print(passed or 'all dart tests passed')
    sys.exit(0)

print('dart tests FAILED')
for l in tail:
    print('  ' + l)
sys.exit(1)
