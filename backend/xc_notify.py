#!/usr/bin/env python3
# Aggregate PUSH payloads for the viewer from the relays. In production a relay hands
# these to APNs/FCM, which wakes the suspended app; here the app collects them on check-in.
import json, os, urllib.request, urllib.parse
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
RELAYS = xc.discover_relays()
# Route by the viewer's UNIQUE account, not the shared 'you.xno' handle — otherwise every user reads one
# common bucket and sees everyone's tip/like alerts (including ones predating their own install). The
# account rides the relay's existing routing param, so no relay change is needed.
try:
    ACCT = open('/tmp/xc_notify_acct.txt').read().strip()
except Exception:
    ACCT = ''
seen = set(); out = []
for r in (RELAYS if ACCT else []):
    try:
        d = json.loads(urllib.request.urlopen(r + '/notify?handle=' + urllib.parse.quote(ACCT, safe=''), timeout=4).read())
        for n in d.get('notifs', []):
            k = (n.get('from'), n.get('ts'), n.get('text'))
            if k not in seen:
                seen.add(k); out.append(n)
    except Exception:
        pass
out.sort(key=lambda n: n.get('ts', 0), reverse=True)
json.dump({"notifs": out, "transport": "relay push queue (stands in for APNs/FCM)"},
          open('/tmp/xc_notify.json', 'w'))
