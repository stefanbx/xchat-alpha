#!/usr/bin/env python3
# Forward a SIGNED community report to every relay. The app signs "report|account|post_id|ts" on-device
# and the node just fans it out — it holds no seed and adds no authority. Relays store the report; the
# aggregator (xc_labels.py) verifies signatures and counts distinct reporters. Outbound-only.
import json, os, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

RELAYS = xc.discover_relays()
try:
    rec = json.load(open('/tmp/xc_report_rec.json'))
    body = json.dumps({'post_id': rec.get('post_id', ''), 'account': rec.get('account', ''),
                       'ts': rec.get('ts', 0), 'sig': rec.get('sig', ''), 'pub': rec.get('pub', ''),
                       'cid': rec.get('cid', '')}).encode()
    sent = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(
                r + '/report', body, {'Content-Type': 'application/json'}), timeout=5).read()
            sent += 1
        except Exception:
            pass
    json.dump({'ok': sent > 0, 'relays': sent}, open('/tmp/xc_report_result.json', 'w'))
except Exception as e:
    json.dump({'ok': False, 'error': str(e)}, open('/tmp/xc_report_result.json', 'w'))
