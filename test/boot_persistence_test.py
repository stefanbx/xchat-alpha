#!/usr/bin/env python3
"""The relay must SAY when it will not survive a reboot, instead of finding out the hard way.

A real operator's relay went dark and nobody could see why. The chain:

  - the installer runs `systemctl --user enable --now xchat-relay`
  - on his machine that failed (no user D-Bus session is the usual cause over SSH)
  - the old line swallowed the error to /dev/null and fell SILENTLY to a nohup fallback
  - the relay ran until the next sleep, then died, and nothing restarted it
  - `--status` showed no sign of any of this — it only checks whether the process is running NOW

So the same silent-failure shape as the worker-KV and tunnel bugs already fixed in this file's
subject: a thing that can quietly stop being true has to be surfaced, not assumed. Two fixes, guarded
here against a quiet regression:

  1. the install path no longer swallows the enable error, and warns clearly that a running-but-not-
     enabled relay will die on the next reboot, with the exact commands to fix it
  2. --status reports boot-persistence, because --status is where you look when it is ALREADY broken

Source-level guards, not behavioural: exercising the real path needs a live `systemd --user` bus,
which CI and a plain checkout do not have. The strings and structure are what regress, so those are
what this pins.

    python3 test/boot_persistence_test.py
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


def region(anchor, before=0, after=800):
    i = SRC.find(anchor)
    return SRC[max(0, i - before):i + after] if i >= 0 else ''


print('--- the enable failure is no longer swallowed ---')
# The exact bug: the error redirected to /dev/null so nobody learned enable had failed.
check('enable --now xchat-relay >/dev/null 2>&1' not in SRC,
      'the enable output is NOT discarded to /dev/null anymore')
check('_en=$(systemctl --user enable --now xchat-relay 2>&1)' in SRC,
      'the enable output is captured so it can be shown when it fails')

setup = region('_en=$(systemctl --user enable', after=700)
check('is-active xchat-relay' in setup,
      'the install path checks whether the service actually came up (is-active)')
check('is-enabled xchat-relay' in setup,
      'and, separately, whether it is enabled for boot (is-enabled)')
check('NOT enabled for boot' in setup and 'die on the next reboot' in setup,
      'a running-but-unenabled relay is called out in plain words')
check('enable-linger' in setup and 'systemctl --user enable xchat-relay' in setup,
      'and the exact fix commands are printed, not left to the operator to find')

print('\n--- --status reports whether the relay survives a reboot ---')
# --status is where an operator looks when the relay is ALREADY down. It has to say boot-persistence.
status = region('    status)', after=1400)
check('is-enabled xchat-relay' in status,
      '--status asks systemd whether the service is enabled')
check('will NOT start on boot' in status,
      '--status says plainly when the relay will not come back after a reboot')
check(re.search(r'ok\s+"starts on boot', status) is not None,
      '--status confirms boot-persistence when it IS set up, so the check is not one-sided')

print('\n--- the running/enabled distinction is not conflated ---')
# The heart of the bug: "running" was treated as "fine". A guard that a relay reported as started via
# systemd is only counted so when it is genuinely active.
check('STARTED=systemd' in setup and setup.index('is-active') < setup.index('STARTED=systemd'),
      'STARTED=systemd is set only after confirming the service is active, so no double-start with nohup')

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
