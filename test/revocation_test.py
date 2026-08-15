#!/usr/bin/env python3
# Issue #10: a leaked release-publisher key had no answer — every node and app would keep accepting
# anything it signed, forever. A revocation signed by a SEPARATE offline root key now retires it and
# names a successor. This drives the real relay code.
#
# The property that matters most is the LAST one: with no root pinned the mechanism is completely
# inert, so shipping it changes nothing until an operator deliberately arms it.
#
#   python3 test/revocation_test.py
import importlib.util, os, sys, tempfile, time


def load_relay(root_acct):
    d = tempfile.mkdtemp(prefix='xc_revoke_')
    sys.argv = ['xc_relayd.py', '7995', os.path.join(d, 'state.json')]
    os.environ['XC_NANO_RPC'] = 'http://127.0.0.1:1'
    if root_acct:
        os.environ['XC_REVOCATION_ACCOUNT'] = root_acct
    else:
        os.environ.pop('XC_REVOCATION_ACCOUNT', None)
    import http.server
    http.server.ThreadingHTTPServer.serve_forever = lambda self, *a, **k: None
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    spec = importlib.util.spec_from_file_location('relayd_%s' % (root_acct or 'none'),
                                                  os.path.join(repo, 'relay', 'xc_relayd.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location('xc', os.path.join(REPO, 'backend', 'xc_common.py'))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

ROOT_KEY = 'aa' * 32
ROOT_ACCT = xc.derive(ROOT_KEY)[0]
IMPOSTOR_KEY = 'bb' * 32
SUCCESSOR = xc.derive('cc' * 32)[0]

results = []
def check(name, cond):
    results.append(cond)
    print(f'  {"PASS" if cond else "FAIL"}  {name}')


def signed(key, revoked, successor, ts):
    d = dict(l.split(' ', 1) for l in
             xc._sign_lines(key, xc.sig_canon('revocation', revoked, successor, ts)))
    return {'revoked': revoked, 'successor': successor, 'ts': ts, 'sig': d['sig'], 'pub': d['pub']}


print('publisher-key revocation\n')

r = load_relay(ROOT_ACCT)
PUB = r.PUBLISHER_ACCT
now = int(time.time())

check('an unrevoked publisher is not flagged', r.revoked_publisher(PUB)[0] is False)

# only the pinned ROOT may revoke — otherwise anyone could block updates network-wide
check('a revocation signed by an impostor is refused',
      r.accept_revocation(signed(IMPOSTOR_KEY, PUB, SUCCESSOR, now)) is False)
check('  and the publisher is still good', r.revoked_publisher(PUB)[0] is False)

check('a revocation signed by the pinned root is accepted',
      r.accept_revocation(signed(ROOT_KEY, PUB, SUCCESSOR, now)) is True)
gone, succ = r.revoked_publisher(PUB)
check('the publisher is now revoked', gone is True)
check('and the successor is named', succ == SUCCESSOR)
check('the successor takes the pinned publisher\'s place', r.successor_of_pinned() == SUCCESSOR)

# replay / rollback protection
check('an older revocation cannot roll it back',
      r.accept_revocation(signed(ROOT_KEY, PUB, '', now - 60)) is False)

# a release signed by the revoked key must be refused outright
rec = {'publisher': PUB, 'version': '9.9.9', 'cid': 'sha256-x', 'sha256': 'x',
       'size': 1, 'changelog': 'malicious'}
d = dict(l.split(' ', 1) for l in xc._sign_lines(xc.keyof(0x99), xc.release_canon(rec)))
rec['sig'] = d['sig']; rec['pub'] = d['pub']
check('a release from the revoked publisher is refused', r.accept_release(dict(rec)) is False)

# THE SAFETY PROPERTY: with no root pinned, none of this can fire
r2 = load_relay('')
check('with no root pinned, a root-signed revocation is IGNORED',
      r2.accept_revocation(signed(ROOT_KEY, r2.PUBLISHER_ACCT, SUCCESSOR, now)) is False)
check('  so an unarmed relay behaves exactly as before',
      r2.revoked_publisher(r2.PUBLISHER_ACCT)[0] is False)

print(f'\n{sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
