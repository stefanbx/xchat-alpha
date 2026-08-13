#!/usr/bin/env python3
# Produce (or clear) a PUBLISHER-SIGNED network announcement — the scrolling banner the app shows only
# during a coordinated event (e.g. "network update coming — back up your seed, move your funds out").
#
# Security: the banner tells users to do high-stakes things, so it MUST be authenticated. It is signed by
# the SAME pinned publisher key that signs releases; the node verifies the signature (and expiry) before
# serving it, and the app shows nothing unless the node returns a valid, unexpired record. A rogue relay
# or a node operator WITHOUT the publisher key cannot forge one.
#
# Usage:
#   XC_PUBLISHER_KEY=<64hex>  python3 xc_announce.py make "text of the banner" <days_valid>
#   python3 xc_announce.py clear
# `make` prints a one-line JSON record. Activate it by serving that JSON from the node:
#   fly secrets set XC_ANNOUNCEMENT='<that json>'      # (or write it to backend/announcement.json)
# Deactivate by unsetting XC_ANNOUNCEMENT (or letting it expire).
import json, os, sys, time
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

KEY_FILE = os.path.expanduser(os.environ.get('XC_PUBLISHER_KEY_FILE', '~/.xchat/publisher.key'))

def rd(p, d=''):
    try:
        return open(p).read().strip()
    except Exception:
        return d

def publisher_key():
    k = os.environ.get('XC_PUBLISHER_KEY', '') or rd(KEY_FILE)
    return k if len(k) == 64 else ''

def canon(text, ts, expires):
    return xc.sig_canon('announce', text, ts, expires)   # domain-separated, same scheme as every other signed record

mode = sys.argv[1] if len(sys.argv) > 1 else 'make'

if mode == 'clear':
    print("To deactivate: unset XC_ANNOUNCEMENT on the node (fly secrets unset XC_ANNOUNCEMENT), "
          "or remove backend/announcement.json. It also auto-clears at its expiry.")
    sys.exit()

key = publisher_key()
if not key:
    print("no publisher key (set XC_PUBLISHER_KEY or ~/.xchat/publisher.key, 64 hex)", file=sys.stderr)
    sys.exit(1)
text = sys.argv[2] if len(sys.argv) > 2 else ''
days = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
if not text:
    print("usage: xc_announce.py make \"<text>\" <days_valid>", file=sys.stderr); sys.exit(1)

addr, pub = xc.derive(key)
ts = int(time.time()); expires = ts + int(days * 86400)
lines = dict(l.split(' ', 1) for l in xc._sign_lines(key, canon(text, ts, expires)))
rec = {'text': text, 'ts': ts, 'expires': expires, 'sig': lines['sig'], 'pub': lines['pub'], 'publisher': addr}
print(json.dumps(rec, ensure_ascii=False))
