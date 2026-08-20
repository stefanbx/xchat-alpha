#!/usr/bin/env python3
"""`xchat` is always put on PATH — including when the user has NO shell rc file yet.

The installer symlinks `xchat` into ~/.local/bin, then makes sure that dir is on PATH. The old code
only appended the PATH line to ~/.zshrc / ~/.bashrc *if they already existed* — so a fresh box with
neither left `xchat` installed but unfindable. This closes that gap: when nothing exists to edit, it
CREATES the rc the current shell reads (zsh → ~/.zshrc, bash → ~/.bashrc, else ~/.profile).

Source-level like the other installer tests: we extract the real PATH block from install-relay.sh and
run it under a stubbed HOME/PATH/SHELL, so the test exercises the shipped shell, not a paraphrase.

    python3 test/xchat_path_install_test.py
"""
import os, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'install-relay.sh')).read()

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

# Extract from `add_path_line() {` through the block's closing `esac`.
i = SRC.find('add_path_line() {')
check(i != -1, 'found the PATH block in install-relay.sh')
j = SRC.find('\nesac', i)
check(j != -1, 'found the PATH block end')
BLOCK = SRC[i:j + len('\nesac')] if (i != -1 and j != -1) else ''
# `ok`/`say`/`BINDIR` are provided by the installer around the block; stub them for isolation.
HARNESS = 'ok(){ :; }\nsay(){ :; }\nBINDIR="$HOME/.local/bin"\n' + BLOCK + '\n'

def run(home, shell, on_path, pre_files=(), runs=1):
    for f in pre_files:
        open(os.path.join(home, f), 'w').close()
    path = f'{home}/.local/bin:/usr/bin:/bin' if on_path else '/usr/bin:/bin'
    env = {'HOME': home, 'PATH': path, 'SHELL': shell}
    for _ in range(runs):
        subprocess.run(['sh', '-c', HARNESS], env=env, capture_output=True, text=True)
    out = {}
    for name in ('.zshrc', '.bashrc', '.profile'):
        p = os.path.join(home, name)
        out[name] = open(p).read().count('added by xchat-relay') if os.path.exists(p) else None
    return out

def case(desc, shell, on_path, pre_files, expect, runs=1):
    with tempfile.TemporaryDirectory() as home:
        got = run(home, shell, on_path, pre_files, runs=runs)
        ok = all(got.get(k) == v for k, v in expect.items())
        check(ok, desc, f'got {got}')

print('\n--- an existing rc gets the line; nothing else is created ---')
case('.zshrc exists → line added to it only', '/bin/zsh', False, ['.zshrc'],
     {'.zshrc': 1, '.bashrc': None, '.profile': None})
case('both exist → line added to both', '/bin/bash', False, ['.zshrc', '.bashrc'],
     {'.zshrc': 1, '.bashrc': 1, '.profile': None})

print('\n--- THE GAP: no rc at all → create the one the shell reads ---')
case('no rc + zsh  → creates ~/.zshrc', '/bin/zsh', False, [],
     {'.zshrc': 1, '.bashrc': None, '.profile': None})
case('no rc + bash → creates ~/.bashrc', '/bin/bash', False, [],
     {'.zshrc': None, '.bashrc': 1, '.profile': None})
case('no rc + dash → creates ~/.profile', '/bin/dash', False, [],
     {'.zshrc': None, '.bashrc': None, '.profile': 1})

print('\n--- already on PATH → touch nothing ---')
case('~/.local/bin on PATH → no rc written', '/bin/zsh', True, [],
     {'.zshrc': None, '.bashrc': None, '.profile': None})

print('\n--- idempotent: re-running never stacks duplicate lines ---')
case('no-rc zsh, 3 runs → exactly one line', '/bin/zsh', False, [], {'.zshrc': 1}, runs=3)
case('existing .bashrc, 3 runs → exactly one line', '/bin/bash', False, ['.bashrc'], {'.bashrc': 1}, runs=3)

print()
if fails:
    print(f'FAIL — {checks} checks, {len(fails)} failure(s)')
    sys.exit(1)
print(f'PASS — {checks} checks, 0 failure(s)')
