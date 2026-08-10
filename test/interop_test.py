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
# every canonical message, rebuilt HERE the way each node helper rebuilds it. These are copied from
# the helpers on purpose: if a helper's canon changes and the app's does not, this fails.
CANON = {
    'head':          lambda a: f"{a}|5|bafycid|9999999",                      # xc_post.py submit
    'post_event':    lambda a: f"you.xno|post|hello|world|1700000000",        # xc_post.py prepare
    'comment':       lambda a: f"p1|{a}|1700000000|nice one|",                # xc_comments.py
    'comment_reply': lambda a: f"p1|{a}|1700000000|replying|c0",              # xc_comments.py (nested)
    'follow':        lambda a: f"{a}|1700000000|nano_a,nano_b",               # xc_follows.py
    'poll':          lambda a: f"poll1|{a}|0|1700000000",                     # xc_poll.py
    'profile':       lambda a: f"{a}|1700000000|Alice|my bio||",              # xc_profile.py
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
        # the app's canonical message must be the one the node rebuilds
        if name in CANON and CANON[name](acct) != msg:
            print(f"FAIL  {name}: canonical message differs\n      app:  {msg!r}\n      node: {CANON[name](acct)!r}")
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
    forged = dict(l.split(' ', 1) for l in xc._sign_lines(other, CANON['profile'](acct)))
    if xc.pub_to_addr(forged['pub']) == acct:
        print("FAIL  a different key derived the same account"); fails += 1
    else:
        print("ok    impersonation    a foreign key does not bind to this account")

    print(f"\n{'FAILED' if fails else 'PASS'} — {len(d['sigs'])} signatures, {fails} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
