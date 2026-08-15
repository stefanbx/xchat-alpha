#!/usr/bin/env python3
# Stake-gated community attestation (prototype).
#
# A release is trusted when >= K INDEPENDENT reviewers, each holding >= THRESHOLD XNO (a Sybil cost,
# checked LIVE on the ledger — not self-claimed), sign that a given commit builds to a given APK hash.
# Stake is a GATE, not a weight: each qualified reviewer counts ONCE, so it's "many independent people,"
# not "most money wins." Two attestation kinds: 'build' (mechanical: commit->hash, checkable by anyone)
# and 'review' (soft human vouch). This module is the verify side + a helper to make an attestation.
import json
import xc_common as xc

XNO = 10**30
THRESHOLD_RAW = 1 * XNO          # min stake to opt in as a dev/reviewer (the Sybil gate)
CAP_RAW = 10 * XNO              # a single dev's vote is capped here -> whales can't dominate
MIN_DISTINCT = 2               # a release needs at least this many DIFFERENT devs (never one wallet)
WEIGHT_MIN = 5 * XNO           # and this much total capped weight

def canon(a):
    return xc.attest_canon(a)          # v2 preimage (issue #7)

def canon_legacy(a):
    return xc.attest_canon_legacy(a)

def make_attestation(reviewer_key, version, commit, sha256, atype='build'):
    addr, pub = xc.derive(reviewer_key)
    a = {'version': version, 'commit': commit, 'sha256': sha256,
         'attestor': addr, 'type': atype, 'pub': pub}
    a['sig'] = dict(l.split(' ', 1) for l in xc._sign_lines(reviewer_key, canon(a)))['sig']
    return a

def balance_raw(addr):
    ai = xc.rpc({'action': 'account_info', 'account': addr})
    return int(ai['balance']) if 'error' not in ai else 0

def verify_release(version, commit, sha256, attestations,
                   threshold=THRESHOLD_RAW, cap=CAP_RAW, min_distinct=MIN_DISTINCT, weight_min=WEIGHT_MIN):
    """Accept iff enough DISTINCT staked devs attest this exact build. Stake gives rank + weight,
    but capped per dev and floored on head-count, so no single whale can carry a release alone."""
    devs, rejected = {}, []
    for a in attestations:
        why = None
        if not (xc.pub_to_addr(a.get('pub', '')) == a.get('attestor') and
                xc.verify_either(a['pub'], a['sig'], canon(a), canon_legacy(a))):
            why = 'bad signature / key-account mismatch'
        elif (a['version'], a['commit'], a['sha256']) != (version, commit, sha256):
            why = 'attests a different release'
        else:
            bal = balance_raw(a['attestor'])           # LIVE on-chain stake — not self-claimed
            if bal < threshold:
                why = f'under stake gate ({bal/XNO:.2f} XNO)'
        if why:
            rejected.append((a['attestor'][:14] + '…', why))
        else:
            devs[a['attestor']] = max(devs.get(a['attestor'], 0), balance_raw(a['attestor']))
    ranked = sorted(({'dev': d[:14] + '…', 'stake_xno': round(s / XNO, 2),
                      'weight_xno': round(min(s, cap) / XNO, 2)} for d, s in devs.items()),
                    key=lambda r: -r['stake_xno'])       # rank by stake
    total_weight = sum(min(s, cap) for s in devs.values())
    accepted = len(devs) >= min_distinct and total_weight >= weight_min
    return {'accepted': accepted, 'distinct_devs': len(devs), 'min_distinct': min_distinct,
            'total_weight_xno': round(total_weight / XNO, 2), 'weight_min_xno': weight_min / XNO,
            'cap_xno': cap / XNO, 'ranked_devs': ranked, 'rejected': rejected}
