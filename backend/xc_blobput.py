#!/usr/bin/env python3
# Pin a raw blob (e.g. an avatar/banner image) to the relays, content-addressed. The app hands
# base64 bytes; we name them by sha256 (cid = "sha256-<hex>"), push to every relay's blob cache,
# and return the cid. Fetch later via /api/media?cid= (which already falls back to relay /blob).
# Usage: xc_blobput.py   (reads /tmp/xc_blob_in.txt = base64)
import json, os, base64, hashlib, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
try:
    b64 = open('/tmp/xc_blob_in.txt').read().strip()
    data = base64.b64decode(b64)
    cid = 'sha256-' + hashlib.sha256(data).hexdigest()
    pinned = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + '/blob', json.dumps({'cid': cid, 'b64': b64}).encode(),
                                   {'Content-Type': 'application/json'}), timeout=15).read()
            pinned += 1
        except Exception:
            pass
    json.dump({'ok': True, 'cid': cid, 'size': len(data), 'pinned_relays': pinned},
              open('/tmp/xc_blobput_result.json', 'w'))
except Exception as e:
    json.dump({'ok': False, 'error': str(e)}, open('/tmp/xc_blobput_result.json', 'w'))
