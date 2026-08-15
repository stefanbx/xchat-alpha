#!/usr/bin/env python3
# THE TEST ON-DEVICE SIGNING RESTS ON.
#
# The app signs with Dart (nanodart, ed25519-blake2b) and the node verifies with Python (nanopy).
# If those two disagree by one byte, every post, comment, vote, follow, profile and DM key is
# rejected — and the failure looks like "the network is down" rather than "the crypto differs".
# So this runs the REAL app wallet (app/bin/interop_sign.dart imports the shipped wallet.dart) and
# checks each signature with the node's REAL verifier (backend/xc_common.verify_msg).
#
# It also checks the two things a valid signature alone would not catch:
#   - the key BINDS to the account (pub_to_addr(pub) == account), so nobody can sign as someone else
#   - a tampered message FAILS, so the check is doing work rather than returning True
#
#   python3 test/interop_test.py
import importlib.util, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(ROOT, "backend", "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

SEED = '07' * 32
# Every canonical message, built by calling the NODE'S OWN canon functions — not by hand-copying the
# format into this file. The previous version duplicated the strings "so a helper changing its canon
# fails here", but duplication rots: when signing moved to the v2 domain-separated preimage this table
# was left on the legacy '|'-joined format, so the test compared the app against a format nothing had
# used for weeks — and it went unnoticed because `dart` is usually absent and the run aborted first.
# Calling the real functions keeps the check that actually matters (the DART app and the PYTHON node
# must agree byte-for-byte) and removes the copy that can silently go stale.
#
# EVERY name the app's battery emits must appear here. The comparison is guarded by `name in CANON`,
# so a missing entry does not fail — it silently downgrades that type to "the signature verifies
# against the message it was signed over", which is true by construction and proves nothing. dm_key
# was in exactly that state: reported ok on every run, never once compared against the node's canon.
#
# `d` is the whole payload from the Dart side, for the cases that need a value only the app can
# supply (the DM public key is derived from the seed, so it cannot be a constant here).
CANON = {
    'head':          lambda a, d: xc.sig_canon('head', a, 5, 'bafycid', 9999999),        # xc_post.py
    'post_event':    lambda a, d: xc.sig_canon('post', 'you.xno', 'post', 'hello|world', 1700000000),
    'comment':       lambda a, d: xc.sig_canon('comment', 'p1', a, 1700000000, 'nice one', ''),
    'comment_reply': lambda a, d: xc.sig_canon('comment', 'p1', a, 1700000000, 'replying', 'c0'),
    'follow':        lambda a, d: xc.sig_canon('follow', a, 1700000000, 'nano_a,nano_b'),
    'poll':          lambda a, d: xc.sig_canon('poll', 'poll1', a, 0, 1700000000),
    'profile':       lambda a, d: xc.sig_canon('profile', a, 1700000000, 'Alice', 'my bio', '', ''),
    'dm_key':        lambda a, d: xc.sig_canon('dmkey', a, 1700000000, d['dm_pub']),      # xc_dm.py
}


def run_dart():
    out = subprocess.run(['dart', 'run', 'bin/interop_sign.dart', 'battery', SEED],
                         cwd=os.path.join(ROOT, 'app'), capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout + out.stderr); sys.exit('dart harness failed')
    return json.loads(out.stdout.strip().splitlines()[-1])


def main():
    d = run_dart()
    acct, fails = d['account'], 0

    # the account the app derived from the seed is the one the node derives from the app's pubkey
    if xc.pub_to_addr(d['pub']) != acct:
        print(f"FAIL  account binding: {xc.pub_to_addr(d['pub'])} != {acct}"); fails += 1
    else:
        print(f"ok    account binding  {acct}")

    for s in d['sigs']:
        name, msg, sig, pub = s['name'], s['msg'], s['sig'], s['pub']
        # An unknown name is a FAILURE, not a skip. The old `if name in CANON` meant a type the app
        # emits but this table forgot fell through to the signature check alone — which compares the
        # message against itself and can never fail. That is how dm_key printed ok for months without
        # its preimage ever being checked.
        if name not in CANON:
            print(f"FAIL  {name}: the app signs this but CANON has no entry — add one, or it is untested")
            fails += 1
            continue
        # the app's canonical message must be the one the node rebuilds
        if CANON[name](acct, d) != msg:
            print(f"FAIL  {name}: canonical message differs\n      app:  {msg!r}\n      node: {CANON[name](acct, d)!r}")
            fails += 1
            continue
        if not xc.verify_msg(pub, msg, sig):
            print(f"FAIL  {name}: the node rejects the app's signature"); fails += 1
            continue
        # and the check has to BITE: one flipped byte must fail
        if xc.verify_msg(pub, msg + 'x', sig):
            print(f"FAIL  {name}: a tampered message still verifies"); fails += 1
            continue
        print(f"ok    {name:<14} {msg[:56]}")

    # a signature from another identity must not pass as this account's
    other = xc.keyof(0x42)
    forged = dict(l.split(' ', 1) for l in xc._sign_lines(other, CANON['profile'](acct, d)))
    if xc.pub_to_addr(forged['pub']) == acct:
        print("FAIL  a different key derived the same account"); fails += 1
    else:
        print("ok    impersonation    a foreign key does not bind to this account")

    print(f"\n{'FAILED' if fails else 'PASS'} — {len(d['sigs'])} signatures, {fails} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
