#!/usr/bin/env python3
# Portable PROFILE: a SIGNED record keyed by the wallet account — display name, bio, and the
# content-addressed CIDs of the avatar/banner images. Published to the relays like the follow
# list, so a profile survives a restore and any viewer can resolve account -> profile.
# Usage: xc_profile.py pub   (reads /tmp/xc_profile_{display,bio,avatar,banner}.txt)
#        xc_profile.py get   (reads /tmp/xc_profile_account.txt -> that account's profile)
import json, os, sys, time, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'get'

def rd(p, d=''):
    try:
        return open(p).read().strip() if os.path.exists(p) else d
    except Exception:
        return d

def canon(acc, ts, display, bio, avatar, banner):
    return f"{acc}|{ts}|{display}|{bio}|{avatar}|{banner}"

def verify(pub, msg, sig):
    try:
        return xc.verify_msg(pub, msg, sig)
    except Exception:
        return False

if mode == 'pub':
    # The profile is ALREADY SIGNED BY THE APP (on-device). The node only verifies + relays — it
    # holds no seed and cannot forge or alter a profile.
    src = json.load(open('/tmp/xc_profile_rec.json'))
    acc = src.get('account', ''); display = src.get('display', ''); bio = src.get('bio', '')
    avatar = src.get('avatar', ''); banner = src.get('banner', '')
    ts = src.get('ts'); sig = src.get('sig', ''); pub = src.get('pub', '')
    if not (xc.pub_to_addr(pub) == acc and verify(pub, canon(acc, ts, display, bio, avatar, banner), sig)):
        json.dump({'ok': False, 'error': 'bad signature'}, open('/tmp/xc_profile_result.json', 'w')); sys.exit()
    rec = {'account': acc, 'display': display, 'bio': bio, 'avatar': avatar, 'banner': banner,
           'ts': ts, 'sig': sig, 'pub': pub}
    pushed = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/profile', json.dumps(rec).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
            pushed += 1
        except Exception:
            pass
    json.dump({'ok': True, 'relays': pushed, 'profile': rec}, open('/tmp/xc_profile_result.json', 'w'))
else:                                                        # get: newest valid record for an account
    acc = rd('/tmp/xc_profile_account.txt')
    best = None
    for r in RELAYS:
        try:
            rec = json.loads(urllib.request.urlopen(r + '/profile?account=' + acc, timeout=4).read()).get('record')
            if not rec:
                continue
            msg = canon(rec['account'], rec['ts'], rec['display'], rec['bio'], rec['avatar'], rec['banner'])
            # key must bind to the account and the signature must hold
            if rec['account'] == acc and xc.pub_to_addr(rec['pub']) == acc and verify(rec['pub'], msg, rec['sig']):
                if best is None or rec['ts'] > best['ts']:
                    best = rec
        except Exception:
            pass
    # follower / following counts for the profile header
    following = 0
    followers = 0
    for r in RELAYS:
        try:
            fr = json.loads(urllib.request.urlopen(r + '/follows?account=' + acc, timeout=4).read()).get('record')
            if fr:
                following = max(following, len(fr.get('follows') or []))
        except Exception:
            pass
        try:
            followers = max(followers, json.loads(urllib.request.urlopen(
                r + '/followers?account=' + acc, timeout=4).read()).get('followers', 0))
        except Exception:
            pass
    out = best or {'account': acc, 'display': '', 'bio': '', 'avatar': '', 'banner': ''}
    out['following'] = following
    out['followers'] = followers
    json.dump({'ok': True, 'profile': out}, open('/tmp/xc_profile_result.json', 'w'))
