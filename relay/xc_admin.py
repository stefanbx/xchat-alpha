#!/usr/bin/env python3
# ӾChat relay ADMIN — the operator's settings + status page.
#
#   xc_admin.py <admin_port> <relay_url> <config.json> [xc_home]
#
# BOUND TO LOOPBACK, ALWAYS. This is the one part of the install that must never be reachable from
# outside, and the reason is specific: the tunnel forwards the RELAY's port to the whole internet, so
# an admin page sharing that port would be an unauthenticated control panel on a public URL. It gets
# its own port that nothing forwards, which is also why it needs no password — reaching it at all
# means you are already on the operator's machine.
#
# It changes settings by writing config.json (read by run.sh on each start) and then stopping the
# relay; the supervisor that owns the relay brings it straight back up with the new values.
import json, os, sys, time, urllib.request, html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util

PORT = int(sys.argv[1])
RELAY = sys.argv[2].rstrip('/')
CONFIG = sys.argv[3]
XC_HOME = sys.argv[4] if len(sys.argv) > 4 else os.path.dirname(os.path.abspath(CONFIG))
BIND = '127.0.0.1'                                   # not configurable, on purpose

xc = None                                            # for ledger reads (earnings); optional
try:
    _spec = importlib.util.spec_from_file_location('xc_common', os.path.join(XC_HOME, 'xc_common.py'))
    xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)
except Exception:
    xc = None

STARTED = time.time()
_earn_cache = {'t': 0, 'v': None}


def read_config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except Exception:
        return {}


def write_config(cfg):
    tmp = CONFIG + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    os.replace(tmp, CONFIG)


def relay_get(path, timeout=4):
    try:
        return json.loads(urllib.request.urlopen(RELAY + path, timeout=timeout).read())
    except Exception:
        return None


def public_url():
    try:
        return open(os.path.join(XC_HOME, 'public-url.txt')).read().strip()
    except Exception:
        return ''


def earnings(acct):
    # What the payout account has actually received. A public ledger read — the relay holds no key to
    # this account and cannot move a thing; it only reports. Cached, because it hits a remote RPC.
    if not acct or xc is None:
        return None
    if time.time() - _earn_cache['t'] < 60 and _earn_cache['v'] is not None:
        return _earn_cache['v']
    out = {'account': acct, 'balance_xno': None, 'received': 0, 'recent': []}
    try:
        ai = xc.rpc({'action': 'account_info', 'account': acct})
        if 'error' not in ai:
            out['balance_xno'] = round(int(ai.get('balance', 0)) / 10 ** 30, 6)
        h = xc.rpc({'action': 'account_history', 'account': acct, 'count': '25'}).get('history', []) or []
        for x in h:
            if x.get('type') == 'receive':
                out['received'] += 1
                if len(out['recent']) < 8:
                    out['recent'].append({'xno': round(int(x.get('amount', 0)) / 10 ** 30, 6),
                                          'from': x.get('account', ''), 'ts': x.get('local_timestamp', '')})
    except Exception:
        pass
    _earn_cache.update(t=time.time(), v=out)
    return out


def state():
    cfg = read_config()
    relays, cache = relay_get('/relays'), relay_get('/cache')
    heads = relay_get('/heads')
    acct = (relay_get('/relayacct') or {}).get('account', '')
    up = relays is not None
    return {
        'up': up,
        'public_url': public_url(),
        'identity': (relays or {}).get('account', ''),
        'payout': acct,
        'peers': len((relays or {}).get('relays', []) or []),
        'signed_peers': len((relays or {}).get('peers', []) or []),
        'heads': len((heads or {}).get('heads', []) or []),
        'blobs': (cache or {}).get('blobs', 0),
        'bytes': (cache or {}).get('bytes', 0),
        'cap': (cache or {}).get('cap', 0),
        'pinned': (cache or {}).get('pinned', 0),
        'admin_uptime_s': int(time.time() - STARTED),
        'shard': (cache or {}).get('shard', 0),
        'opportunistic': (cache or {}).get('opportunistic', 0),
        'replicas': (cache or {}).get('replicas', 0),
        'placement_relays': (cache or {}).get('placement_relays', 0),
        'settings': {
            'relay_acct': cfg.get('relay_acct', ''),
            'blob_cap_mb': cfg.get('blob_cap_mb', ''),
            'bootstrap': cfg.get('bootstrap', ''),
            'keep_awake': cfg.get('keep_awake', True),
            'open_announce': cfg.get('open_announce', True),
        },
        'earnings': earnings(acct),
    }


def validate(body):
    cfg = read_config()
    a = (body.get('relay_acct') or '').strip()
    if a:
        if not a.startswith('nano_') or len(a) != 65:
            raise ValueError('that is not a Nano address (expected nano_ followed by 60 characters)')
    cfg['relay_acct'] = a

    cap = str(body.get('blob_cap_mb', '')).strip()
    if cap:
        if not cap.isdigit() or not (16 <= int(cap) <= 1_000_000):
            raise ValueError('storage cap must be a whole number of MB between 16 and 1000000')
        cfg['blob_cap_mb'] = int(cap)
    else:
        cfg.pop('blob_cap_mb', None)

    bs = (body.get('bootstrap') or '').split()
    for u in bs:
        if not u.startswith('http://') and not u.startswith('https://'):
            raise ValueError('bootstrap peers must be http(s) URLs — got: ' + u)
    cfg['bootstrap'] = ' '.join(bs)
    cfg['keep_awake'] = bool(body.get('keep_awake', True))
    cfg['open_announce'] = bool(body.get('open_announce', True))
    return cfg


def restart_relay():
    # Settings are read by run.sh at start, so applying them means stopping the relay and letting the
    # supervisor rebuild it. Kill only the pid the supervisor recorded — never a pattern match, which
    # on a machine running two relays would take down the wrong one.
    try:
        pid = int(open(os.path.join(XC_HOME, 'relay.pid')).read().strip())
    except Exception:
        return False
    try:
        os.kill(pid, 15)
        return True
    except Exception:
        return False


PAGE = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>ӾChat relay — settings</title>
<style>
:root{--bg:#050607;--card:#0f1317;--line:#1c2228;--ink:#eef3f7;--muted:#93a1ad;--accent:#2ca6e0;
      --accent2:#4fd1c5;--good:#38c172;--bad:#e0685a}
*{box-sizing:border-box}html,body{margin:0}
body{background:radial-gradient(1100px 620px at 50% -160px,rgba(44,166,224,.16),transparent 60%),var(--bg);
     color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:720px;margin:0 auto;padding:44px 20px 64px}
h1{font-size:24px;margin:0 0 4px;letter-spacing:-.3px}
.sub{color:var(--muted);margin:0 0 26px;font-size:13.5px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;margin:14px 0}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.12em;color:var(--muted);margin:0 0 14px}
.row{display:flex;justify-content:space-between;gap:14px;padding:7px 0;border-bottom:1px solid rgba(255,255,255,.04)}
.row:last-child{border-bottom:0}.row b{font-weight:600}
.k{color:var(--muted)}.v{text-align:right;word-break:break-all}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
.pill{display:inline-block;font-size:12px;border-radius:999px;padding:2px 10px}
.on{color:var(--good);border:1px solid rgba(56,193,114,.35);background:rgba(56,193,114,.08)}
.off{color:var(--bad);border:1px solid rgba(224,104,90,.35);background:rgba(224,104,90,.08)}
label{display:block;font-size:13px;color:var(--muted);margin:14px 0 5px}
input{width:100%;background:#080b0d;border:1px solid var(--line);border-radius:9px;padding:11px 12px;
      color:var(--ink);font:inherit;font-size:13.5px}
input:focus{outline:0;border-color:var(--accent)}
.hint{font-size:12px;color:var(--muted);margin:5px 0 0}
button{margin-top:18px;width:100%;background:linear-gradient(150deg,var(--accent),#1b7bb5);color:#fff;
       border:0;border-radius:11px;padding:13px;font:inherit;font-weight:700;font-size:15px;cursor:pointer}
button:disabled{opacity:.55;cursor:default}
.msg{margin-top:12px;font-size:13px;display:none}.msg.ok{color:var(--good);display:block}
.msg.err{color:var(--bad);display:block}
.bar{height:7px;background:#080b0d;border:1px solid var(--line);border-radius:99px;overflow:hidden;margin-top:8px}
.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2))}
a{color:var(--accent)}
label.check{display:flex;align-items:flex-start;gap:9px;margin:16px 0 0;color:var(--ink);font-size:13.5px}
label.check input{width:auto;margin:2px 0 0}
</style></head><body><div class=wrap>
<h1>Your ӾChat relay</h1>
<p class=sub>Only you can see this page — it listens on this computer alone and is not part of what
   your relay serves to the internet.</p>
<div class=card><h2>Status</h2><div id=status>loading…</div></div>
<div class=card><h2>Earnings</h2><div id=earn>loading…</div></div>
<div class=card><h2>Settings</h2>
  <label for=acct>Payout address — where pinning fees and your 10% share of tips are sent</label>
  <input id=acct class=mono placeholder="nano_… (leave empty to accept no payments)">
  <p class=hint>Paste your own address from the ӾChat app. Leave it empty and your relay simply
     won't take paid pins — it will never quietly pay someone else.</p>
  <label for=cap>Storage cap (MB)</label>
  <input id=cap inputmode=numeric placeholder="512">
  <p class=hint>How much disk the relay may fill with other people's media before evicting the least
     used. Paid pins are protected from eviction.</p>
  <label class=check><input type=checkbox id=awake>
    <span>Keep this computer awake to serve while it's plugged in</span></label>
  <p class=hint>Lets your relay work through the night on mains power. It never holds the machine
     awake on battery, and closing a laptop lid still sends it to sleep.</p>
  <label for=boot>Bootstrap peers</label>
  <input id=boot class=mono placeholder="https://xchat-alpha-node.fly.dev https://xchat-relay-1.fly.dev">
  <p class=hint>Space separated. These are just the first peers it says hello to; it finds the rest
     by gossip.</p>
  <label class=check><input type=checkbox id=openann>
    <span>Accept announcements from other relays (open federation)</span></label>
  <p class=hint>On: any new relay that checks in becomes discoverable through yours — this is what keeps
     the network open and hard to shut down. Off: your relay only talks to the bootstrap peers above and
     ignores strangers.</p>
  <button id=save>Save and restart the relay</button>
  <div class=msg id=msg></div>
</div>
<p class=sub style="margin-top:22px">Your relay keeps a permanent identity of its own, so people keep
   finding it even when this computer's address changes.</p>
</div>
<script>
const $ = i => document.getElementById(i);
const esc = s => String(s == null ? '' : s);
function row(k, v, cls) { return '<div class=row><span class=k>' + k + '</span><span class="v ' +
  (cls || '') + '">' + v + '</span></div>'; }
function mb(n) { return (n / 1048576).toFixed(1) + ' MB'; }
let dirty = false;
['acct','cap','boot'].forEach(i => $(i).addEventListener('input', () => { dirty = true; }));

async function load() {
  const s = await (await fetch('/api/state')).json();
  $('status').innerHTML =
    row('Relay', s.up ? '<span class="pill on">running</span>' : '<span class="pill off">not responding</span>') +
    row('Public address', s.public_url ? '<span class=mono>' + esc(s.public_url) + '</span>' : '—') +
    row('Identity', '<span class=mono>' + (esc(s.identity).slice(0, 22) || '—') + '…</span>') +
    row('Peers known', s.peers + (s.signed_peers ? ' (' + s.signed_peers + ' identified)' : '')) +
    row('Author heads served', s.heads) +
    row('Stored media', s.blobs + ' files · ' + mb(s.bytes) + ' of ' + mb(s.cap) +
        '<div class=bar><i style="width:' + Math.min(100, s.cap ? s.bytes / s.cap * 100 : 0) + '%"></i></div>') +
    row('Your share of the network', s.placement_relays > s.replicas
          ? s.shard + ' files you are responsible for · ' + s.opportunistic + ' spare copies'
          : 'holding everything (too few relays to share out yet)') +
    row('Protected by payment', s.pinned + ' files');
  const e = s.earnings;
  $('earn').innerHTML = !s.payout
    ? '<div class=row><span class=k>No payout address set — this relay accepts no payments.</span></div>'
    : row('Paid to', '<span class=mono>' + esc(s.payout).slice(0, 22) + '…</span>') +
      row('Balance', e && e.balance_xno != null ? '<b>' + e.balance_xno + ' XNO</b>' : 'unopened / unreachable') +
      row('Payments received', e ? e.received : '—') +
      ((e && e.recent.length) ? e.recent.map(r => row('received', '<b>' + r.xno + ' XNO</b>')).join('') : '');
  if (!dirty) {
    $('acct').value = s.settings.relay_acct || s.payout || '';
    $('cap').value = s.settings.blob_cap_mb || '';
    $('boot').value = s.settings.bootstrap || '';
    $('awake').checked = s.settings.keep_awake !== false;
    $('openann').checked = s.settings.open_announce !== false;
  }
}

$('save').onclick = async () => {
  const btn = $('save'), m = $('msg');
  btn.disabled = true; m.className = 'msg'; m.textContent = '';
  try {
    const r = await fetch('/api/settings', {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({relay_acct: $('acct').value.trim(), blob_cap_mb: $('cap').value.trim(),
                            bootstrap: $('boot').value.trim(), keep_awake: $('awake').checked,
                            open_announce: $('openann').checked})});
    const d = await r.json();
    if (!d.ok) throw new Error(d.error || 'could not save');
    m.className = 'msg ok';
    m.textContent = 'Saved. The relay is restarting — it will be back in a few seconds.';
    dirty = false;
    setTimeout(load, 6000);
  } catch (err) { m.className = 'msg err'; m.textContent = err.message; }
  btn.disabled = false;
};

load(); setInterval(load, 10000);
</script></body></html>"""


class A(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype='application/json'):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        # No CORS header: nothing off this machine has any business calling these.
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = self.path.split('?', 1)[0]
        if p in ('/', '/index.html'):
            return self._send(200, PAGE, 'text/html; charset=utf-8')
        if p == '/api/state':
            return self._send(200, json.dumps(state()))
        self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path.split('?', 1)[0] != '/api/settings':
            return self._send(404, '{"error":"not found"}')
        try:
            n = int(self.headers.get('Content-Length', 0) or 0)
            body = json.loads(self.rfile.read(n) or b'{}') if 0 < n <= 65536 else {}
            cfg = validate(body)
            write_config(cfg)
            self._send(200, json.dumps({'ok': True, 'restarting': restart_relay()}))
        except ValueError as e:
            self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        except Exception as e:
            self._send(500, json.dumps({'ok': False, 'error': str(e)}))


if __name__ == '__main__':
    print(f'ӾChat relay admin on http://{BIND}:{PORT}  relay={RELAY}  config={CONFIG}', flush=True)
    ThreadingHTTPServer((BIND, PORT), A).serve_forever()
