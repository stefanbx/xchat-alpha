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
    # Fetch from a relay's cache. Try OUR OWN loopback relay FIRST: it is local, instant, and for
    # anything this node stored — DM attachments especially, but also pinned media — it reliably HAS
    # the blob. Only fall through to peers for media the loopback never cached. The timeout must fit a
    # whole RELEASE APK (~20 MB) pulled across relays, not just a thumbnail — 5 s silently failed the
    # in-app update download.
    #
    # An earlier version SKIPPED the loopback relay entirely, on the assumption "it's why we're here —
    # it doesn't have it". That holds for uncached FEED media, but is FALSE for DM attachments: the
    # sender uploads the sealed blob to every relay including the loopback, so /api/media then returned
    # b64:null and the image showed "unavailable" for BOTH sender and recipient whenever no PEER relay
    # happened to hold it (e.g. a node whose only relay is local). Ordering loopback first fixes that
    # and is faster in the common case; peers remain the fallback for genuinely-uncached media.
    def _local(r):
        return '127.0.0.1' in r or 'localhost' in r
    relays = xc.discover_relays()
    for r in sorted(relays, key=lambda r: 0 if _local(r) else 1):
        try:
            d = json.loads(urllib.request.urlopen(r + '/blob?cid=' + cid, timeout=90).read())
            if d.get('b64'):
                b = base64.b64decode(d['b64'])
                if xc.content_matches_cid(cid, b):     # a rogue relay can't swap content for the requested CID
                    data = b; break
                # bytes don't hash to the CID — skip this lying/corrupt relay, try the next
        except Exception:
            pass
json.dump({"cid": cid, "b64": base64.b64encode(data).decode() if data else None,
           "source": "ipfs-or-relay-cache"}, open('/tmp/xc_media_result.json', 'w'))
