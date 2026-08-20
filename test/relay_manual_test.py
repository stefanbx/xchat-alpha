#!/usr/bin/env python3
"""The operator handbook ships with the relay and is reachable by command, click, and URL.

`relay/manual.html` (how the mesh works + a full command manual) is delivered in the package, served
by the admin server at /manual, and opened by `xchat manual` or a desktop shortcut. This guards every
wiring point so a refactor can't quietly drop one — plus a live check that the admin route actually
serves the file and 404s when it is absent.

    python3 test/relay_manual_test.py
"""
import os, re, subprocess, sys, tempfile, time, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = open(os.path.join(REPO, 'relay', 'install-relay.sh')).read()
ADMIN = open(os.path.join(REPO, 'relay', 'xc_admin.py')).read()

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

print('--- the file exists and is a complete standalone document ---')
man_path = os.path.join(REPO, 'relay', 'manual.html')
check(os.path.exists(man_path), 'relay/manual.html is in the package')
man = open(man_path, encoding='utf-8').read()
check(man.lstrip().lower().startswith('<!doctype html>'), 'it is a full standalone HTML doc (has a doctype)')
check('charset="utf-8"' in man, 'declares utf-8 (the Ӿ glyph + em dashes render)')
check('<title>' in man and '</title>' in man, 'has a <title>')
check('xchat manual' in man, 'the manual documents how to reopen itself (xchat manual)')
check('Auto-promote' in man or 'auto-promote' in man, 'reflects the shipped auto-promote default')

print('\n--- the installer delivers it, non-fatally ---')
check(re.search(r'fetch "\$SRC/relay/manual\.html"\s+"\$XC_HOME/manual\.html"', INSTALL) is not None,
      'the installer fetches manual.html into XC_HOME')
m = re.search(r'fetch "\$SRC/relay/manual\.html".*', INSTALL)
check(m is not None and '||' in m.group(0), 'the fetch is non-fatal (docs must never fail an install)')

print('\n--- reachable three ways: command, URL, click ---')
check(re.search(r'manual\|docs\|handbook\)', INSTALL) is not None, '`xchat manual` subcommand exists (aliases: docs/handbook)')
check('"$ADMIN_URL/manual"' in INSTALL, 'xchat manual opens the relay-served URL')
check('file://$XC_HOME/manual.html' in INSTALL, 'xchat manual falls back to the on-disk file when the server is down')
check('xchat manual' in INSTALL, 'the help listing mentions xchat manual')
check(INSTALL.count('ӾChat Relay Manual') >= 2, 'a desktop shortcut is created on both macOS and Linux')
check('xchat-relay-manual.desktop' in INSTALL and 'ӾChat Relay Manual.app' in INSTALL,
      'uninstall removes the manual shortcuts too')

print('\n--- the admin server serves /manual from disk ---')
check("p == '/manual'" in ADMIN, 'xc_admin.py routes GET /manual')
check("open(os.path.join(XC_HOME, 'manual.html')" in ADMIN, '/manual reads the file at request time (so --update refreshes it)')
check('/manual' in ADMIN and 'Open the handbook' in ADMIN, 'the settings page links to the handbook')

print('\n--- live: the route serves it, and 404s when absent ---')
with tempfile.TemporaryDirectory() as tmp:
    open(os.path.join(tmp, 'config.json'), 'w').write('{"relay_acct":""}')
    try:  # xc_common import is best-effort in the admin; provide it if present
        import shutil
        shutil.copy(os.path.join(REPO, 'backend', 'xc_common.py'), os.path.join(tmp, 'xc_common.py'))
    except Exception:
        pass
    shutil.copy(man_path, os.path.join(tmp, 'manual.html'))
    port = '7810'
    proc = subprocess.Popen(['python3', os.path.join(REPO, 'relay', 'xc_admin.py'),
                             port, 'http://127.0.0.1:7401', os.path.join(tmp, 'config.json'), tmp],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.5)
        def get(path):
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=3) as r:
                    return r.status, r.read().decode('utf-8', 'replace')
            except urllib.error.HTTPError as e:
                return e.code, ''
        st, body = get('/manual')
        check(st == 200 and '<title>' in body, 'GET /manual returns the handbook', f'status {st}')
        os.remove(os.path.join(tmp, 'manual.html'))
        st2, _ = get('/manual')
        check(st2 == 404, 'GET /manual 404s once the file is gone', f'status {st2}')
    finally:
        proc.terminate()
        proc.wait(timeout=5)

print()
if fails:
    print(f'FAIL — {checks} checks, {len(fails)} failure(s)')
    sys.exit(1)
print(f'PASS — {checks} checks, 0 failure(s)')
