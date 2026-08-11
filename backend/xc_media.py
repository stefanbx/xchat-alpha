#!/usr/bin/env python3
# Serve media by CID for the app: try the IPFS origin, else a relay CACHE — so thumbnails
# and movies survive loss of the origin host (media over relays). Returns base64.
import json, os, base64, subprocess, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

cid = open('/tmp/xc_media_cid.txt').read().strip()
data = None
try:
    data = subprocess.check_output(['ipfs', 'cat', cid], env={**os.environ, 'IPFS_PATH': xc.IPFS_PATH}, timeout=10)
except Exception:
    for r in xc.discover_relays():
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=5).read())
            if d.get('b64'):
                data = base64.b64decode(d['b64']); break
        except Exception:
            pass
json.dump({"cid": cid, "b64": base64.b64encode(data).decode() if data else None,
           "source": "ipfs-or-relay-cache"}, open('/tmp/xc_media_result.json', 'w'))
