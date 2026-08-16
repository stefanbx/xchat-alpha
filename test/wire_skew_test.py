#!/usr/bin/env python3
"""Version-skew testbed: run the RELEASED relay next to the WORKING-TREE relay and prove they
interoperate at the wire level — BEFORE a format change ships to the installs already in the field.

WHY THIS EXISTS
---------------
Every other test in this repo runs new code against new code. That is exactly the blind spot that let
the 2.5.0 DM regression ship: a green suite that never reproduced the real network. A WIRE change —
sealed sender is the one driving this — is strictly more dangerous, because the failure is not "slow",
it is "a 2.5.1 phone can no longer read a message a newer phone sent", and that cannot be undone by a
server redeploy once the record is on the relays.

So this harness checks out the RELEASED code into a git worktree and boots it as the "old" relay,
alongside the working tree as the "new" relay, and asserts the two agree on the wire.

    XC_BASELINE_REF=<release-commit>  python3 test/wire_skew_test.py
    python3 test/wire_skew_test.py          # baseline defaults to HEAD

With no ref set, old == new (both HEAD), so the interop assertions are trivially symmetric — that run
proves the HARNESS. The moment sealed sender lands in the working tree, set XC_BASELINE_REF to the
last release and the SAME assertions become the compatibility contract between the two formats.

WHAT IT PINS FOR SEALED SENDER (found by reading the relay before writing any wire code)
---------------------------------------------------------------------------------------
1. A deployed relay stores a record it does not understand INTACT — unknown fields survive. This is
   the property sealed sender needs from the 2.5.1 relays already in the field: if it failed, no
   client could use the new format until every relay updated.
2. The relay dedups DMs on (from, ts). Sealed sender hides `from`, so every sealed record would dedup
   as (None, ts) and two senders in the same second would lose a message. Sealed sender MUST carry
   its own message id. This test asserts the CURRENT behaviour so the change is forced to reckon with
   it rather than discover it in production.
3. The mailbox filter is `to == acc OR from == acc`. The `from == acc` half is how a sender reads
   their OWN sent messages. Hide `from` and the sender loses their history unless sealed sender adds a
   sender-side copy. Also asserted against current behaviour.

Conclusion this harness makes unavoidable: sealed sender is NOT a pure client change. Relays must
update too, and the rollout has to be capability-gated so old installs never receive a format they
cannot read.
"""
import json, os, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE_REF = os.environ.get('XC_BASELINE_REF', 'HEAD')

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close()
    return p


def sh(*args):
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True)


class Relay:
    """A relay booted from a specific code directory (a git worktree for OLD, the repo for NEW)."""

    def __init__(self, label, code_dir):
        self.label = label
        self.port = free_port()
        self.base = f'http://127.0.0.1:{self.port}'
        self.store = tempfile.NamedTemporaryFile(prefix=f'wireskew-{label}-', suffix='.json',
                                                 delete=False).name
        env = dict(os.environ,
                   XC_ISOLATE='1',                       # never touch the real relay mesh
                   XCHAT_BOOTSTRAP='',                   # and discover nothing
                   XC_NANO_RPC='http://127.0.0.1:9')     # a dead ledger, so no mainnet scan
        self.p = subprocess.Popen(
            [sys.executable, 'xc_relayd.py', str(self.port), self.store],
            cwd=os.path.join(code_dir, 'relay'), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        end = time.time() + 40
        while time.time() < end:
            try:
                urllib.request.urlopen(self.base + '/heads', timeout=2).read()
                return
            except urllib.error.HTTPError:
                return
            except Exception:
                time.sleep(0.3)
        out = ''
        try:
            self.p.terminate(); out = (self.p.stdout.read() or b'').decode()[:1500]
        except Exception:
            pass
        raise RuntimeError(f'{label} relay did not start:\n{out}')

    def post_dm(self, record):
        body = json.dumps(record).encode()
        r = urllib.request.urlopen(
            urllib.request.Request(self.base + '/dm', body, {'Content-Type': 'application/json'}),
            timeout=10)
        return json.loads(r.read())

    def get_dms(self, account):
        r = urllib.request.urlopen(f'{self.base}/dm?account={account}', timeout=10)
        return json.loads(r.read()).get('dms', [])

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        try:
            os.remove(self.store)
        except OSError:
            pass


# The current, released DM record shape.
def dm_record(frm, to, ts, ct='SEALEDCIPHERTEXT'):
    return {'to': to, 'from': frm, 'from_pk': 'aa' * 32, 'to_pk': 'bb' * 32, 'ct': ct, 'ts': ts}


ALICE = 'nano_1alice'
BOB = 'nano_1bob'


def suite(relay):
    """The interop + forward-compat + constraint checks, run against ONE relay version."""
    L = relay.label

    # ---- a current record round-trips unchanged ------------------------------------------------
    rec = dm_record(ALICE, BOB, 1000)
    relay.post_dm(rec)
    back = [m for m in relay.get_dms(BOB) if m.get('ts') == 1000]
    check(len(back) == 1 and back[0].get('ct') == rec['ct'],
          f'[{L}] a current DM record stores and reads back unchanged')

    # ---- FORWARD-COMPAT: an already-deployed relay must keep fields it does not understand ------
    # This is the property sealed sender depends on from the 2.5.1 relays in the field. A sealed
    # record has an ephemeral key and a version and NO plaintext sender.
    future = {'to': BOB, 'ts': 2000, 'ct': 'OUTERSEALED', 'epk': 'cc' * 32, 'v': 2}
    relay.post_dm(future)
    got = [m for m in relay.get_dms(BOB) if m.get('ts') == 2000]
    check(len(got) == 1, f'[{L}] a future-shaped record (no plaintext sender) is accepted, not rejected')
    if got:
        check(got[0].get('epk') == 'cc' * 32 and got[0].get('v') == 2,
              f'[{L}] unknown fields (epk, v) survive intact — additive changes are safe to store',
              json.dumps(got[0]))

    # ---- CONSTRAINT 1: dedup is on (from, ts). Hiding `from` collapses distinct messages. --------
    # Two DIFFERENT sealed messages, same second, no plaintext sender: both dedup to (None, 3000).
    relay.post_dm({'to': BOB, 'ts': 3000, 'ct': 'FIRST', 'epk': 'd1' * 32})
    relay.post_dm({'to': BOB, 'ts': 3000, 'ct': 'SECOND', 'epk': 'd2' * 32})
    at3000 = [m for m in relay.get_dms(BOB) if m.get('ts') == 3000]
    # On the CURRENT relay this is 1 (the hazard). A sealed-sender relay must make it 2 by deduping on
    # a message id instead. Either way the number is the contract, so a change to it is deliberate.
    check(len(at3000) == 1,
          f'[{L}] CONSTRAINT: two senderless records in one second dedup to one — sealed sender '
          f'needs its own message id',
          f'got {len(at3000)} (current relay: expect 1; a fixed relay: expect 2 and this test updates)')

    # ---- CONSTRAINT 2: the SENDER reads their own sent mail via `from == acc`. ------------------
    # A record addressed to BOB with a plaintext sender ALICE is visible to BOTH. Remove the sender
    # (sealed) and ALICE can no longer see her own sent message.
    relay.post_dm(dm_record(ALICE, BOB, 4000, ct='WITHSENDER'))
    relay.post_dm({'to': BOB, 'ts': 4001, 'ct': 'SEALEDNOSENDER', 'epk': 'ee' * 32})
    alice_sees = {m.get('ts') for m in relay.get_dms(ALICE)}
    bob_sees = {m.get('ts') for m in relay.get_dms(BOB)}
    check(4000 in alice_sees and 4000 in bob_sees,
          f'[{L}] a record WITH a plaintext sender is visible to both sender and recipient')
    check(4001 in bob_sees, f'[{L}] a senderless record still reaches its recipient (to is kept)')
    check(4001 not in alice_sees,
          f'[{L}] CONSTRAINT: a senderless record is INVISIBLE to its sender — sealed sender needs a '
          f'sender-side copy or the author loses their own history')


def main():
    print(f'baseline ref: {BASELINE_REF}  (set XC_BASELINE_REF to a release commit once sealed '
          f'sender is in the working tree)\n')

    # A git worktree of the baseline: a full, self-contained checkout the OLD relay runs from. The
    # working tree may have uncommitted sealed-sender changes; the worktree deliberately does NOT.
    worktree = tempfile.mkdtemp(prefix='wireskew-baseline-')
    r = sh('git', 'worktree', 'add', '--detach', '--force', worktree, BASELINE_REF)
    if r.returncode != 0:
        print('FAIL — could not create baseline worktree:\n' + r.stderr)
        sys.exit(1)

    old = new = None
    try:
        base_sha = sh('git', 'rev-parse', '--short', BASELINE_REF).stdout.strip()
        head_sha = sh('git', 'rev-parse', '--short', 'HEAD').stdout.strip()
        print(f'OLD relay = {base_sha} (released)   NEW relay = {head_sha} (working tree)')
        if base_sha == head_sha:
            print('  note: identical today, so this run proves the HARNESS; the assertions become a\n'
                  '        real cross-version contract once the working tree and baseline differ.\n')

        old = Relay('OLD', worktree)
        new = Relay('NEW', REPO)
        check(True, 'both relay versions booted')

        print('\n--- OLD (the relay already deployed in the field) ---')
        suite(old)
        print('\n--- NEW (the working tree, where sealed sender will live) ---')
        suite(new)

        # Cross-version: the deployed OLD relay must serve a record posted in the future shape so a
        # NEW client fetching from an OLD relay is not left blind.
        print('\n--- cross-version: NEW-shaped record on an OLD relay ---')
        old.post_dm({'to': 'nano_1carol', 'ts': 5000, 'ct': 'X', 'epk': 'ff' * 32, 'v': 2})
        served = [m for m in old.get_dms('nano_1carol') if m.get('ts') == 5000]
        check(len(served) == 1 and served[0].get('v') == 2,
              'an OLD relay stores and serves a NEW-shaped record — so a mixed network can carry it')
    finally:
        if old:
            old.stop()
        if new:
            new.stop()
        sh('git', 'worktree', 'remove', '--force', worktree)

    print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
    for f in fails:
        print('  - ' + f)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
