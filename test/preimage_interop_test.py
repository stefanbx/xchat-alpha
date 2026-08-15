#!/usr/bin/env python3
# The Dart app and the Python node/relay are two implementations of ONE signing wire format. If their
# canonical preimages ever differ by a byte, the signature is still perfectly valid — it just verifies
# against nothing, and the symptom is "my report/reshare silently doesn't count" rather than an error.
# So compare the preimages directly, and then prove a Dart-made signature verifies in Python.
#
# Covers the four types migrated in issue #7 plus two already on v2, and checks that the LEGACY
# preimage is still accepted (the transition contract: verifiers take either, signers emit v2).
#
#   python3 test/preimage_interop_test.py
import json, os, shutil, subprocess, sys, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEED = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'
POST, TS = 'u1786728999', 1786728999
# PATH first, then the usual local SDK spot. Hard-coding ~/flutter/bin/dart alone meant this test
# silently skipped its whole cross-language half on any machine that installs Flutter elsewhere —
# including CI, where it reported "ok" while checking nothing. A skip that looks like a pass is worse
# than a failure: it is the green tick that made the preimage drift invisible in the first place.
DART = shutil.which('dart') or os.path.expanduser('~/flutter/bin/dart')

spec = importlib.util.spec_from_file_location('xc', os.path.join(REPO, 'backend', 'xc_common.py'))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

if not os.path.exists(DART):
    print('dart not found — skipping the cross-language half'); sys.exit(0)

out = subprocess.run([DART, 'run', 'bin/preimage_dump.dart', SEED], cwd=os.path.join(REPO, 'app'),
                     capture_output=True, text=True, timeout=600).stdout
dart = json.loads([l for l in out.splitlines() if l.startswith('{')][-1])
acct = dart['account']

python = {
    'report':  xc.report_canon(acct, POST, TS),
    'reshare': xc.reshare_canon(acct, POST, TS),
    'delete':  xc.sig_canon('delete', acct, POST, TS),
    'head':    xc.sig_canon('head', acct, 13,
                            'bafybeigao5y5rreaw2ds6vlp7soudighqplfty7iahfv6zup67o4fn65ne', 1789113375),
}

ok = True
print('canonical preimage, Dart app vs Python node/relay\n')
for k in sorted(python):
    same = dart[k] == python[k]
    ok &= same
    print(f'  {"PASS" if same else "FAIL"}  {k}')
    if not same:
        print(f'        dart  : {dart[k]}')
        print(f'        python: {python[k]}')

# A signature the APP makes must verify with the relay/node verifier — preimage equality is necessary
# but not sufficient (encoding of ints, unicode, etc. all have to agree too).
proc = subprocess.Popen([DART, 'run', 'bin/interop_sign.dart', 'daemon', SEED],
                        cwd=os.path.join(REPO, 'app'), stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, text=True)
try:
    while not (proc.stdout.readline() or '').startswith('{'):
        pass
    print()
    for name, msg in (('report', python['report']), ('reshare', python['reshare'])):
        proc.stdin.write(json.dumps({'op': 'sign', 'msg': msg}) + '\n'); proc.stdin.flush()
        d = json.loads(proc.stdout.readline())
        good = xc.verify_msg(d['pub'], msg, d['sig'])
        # and the transition contract: the verifier must ALSO still take a legacy-signed one
        legacy = {'report': xc.report_canon_legacy, 'reshare': xc.reshare_canon_legacy}[name](acct, POST, TS)
        proc.stdin.write(json.dumps({'op': 'sign', 'msg': legacy}) + '\n'); proc.stdin.flush()
        dl = json.loads(proc.stdout.readline())
        either_v2 = xc.verify_either(d['pub'], d['sig'], msg, legacy)
        either_legacy = xc.verify_either(dl['pub'], dl['sig'], msg, legacy)
        ok &= good and either_v2 and either_legacy
        print(f'  {"PASS" if good else "FAIL"}  {name}: app-signed v2 verifies in python')
        print(f'  {"PASS" if either_legacy else "FAIL"}  {name}: legacy signature still accepted (transition)')
    proc.stdin.write(json.dumps({'op': 'quit'}) + '\n'); proc.stdin.flush()
finally:
    proc.terminate()

print('\nALL PASS' if ok else '\nFAILURES')
sys.exit(0 if ok else 1)
