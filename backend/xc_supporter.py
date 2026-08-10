#!/usr/bin/env python3
# Register/deregister this phone as a SUPPORTER (relaying/pinning) across the relays.
# The client only calls this while charging + on Wi-Fi, so contribution never costs battery.
import json, os, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
RELAYS = xc.discover_relays()
m = json.load(open('/tmp/xc_supporter_in.json'))     # {account, on:"1"/"0", ts:"..."}
on = str(m.get('on')) in ('1', 'true', 'True')
body = json.dumps({'account': m['account'], 'on': on, 'ts': int(m.get('ts', 0) or 0)}).encode()
count = 0
for r in RELAYS:
    try:
        resp = json.loads(urllib.request.urlopen(urllib.request.Request(
            r + '/supporter', body, {'Content-Type': 'application/json'}), timeout=4).read())
        count = max(count, resp.get('count', 0))
    except Exception:
        pass
json.dump({"ok": True, "active": on, "supporters": count}, open('/tmp/xc_supporter_result.json', 'w'))
