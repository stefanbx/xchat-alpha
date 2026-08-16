#!/usr/bin/env python3
# ONE-OFF: sweep the publicly-derivable demo payout account into an address you control.
#
# Why this exists. Until RELAY_ACCT was set as a Fly secret, the hosted relays advertised
# acct(0x50) as their pay-to address. That key derives from a fixed repeated byte, so ANYONE
# with the repo can compute it — it is a fixture, not a wallet. Pinning fees and tip splits
# landed there anyway: 6 receivable blocks, 0.0123 XNO at the time of writing. Whoever claims
# them first keeps them, so this is worth running promptly and once.
#
# It does two things, in order:
#   1. opens/receives every pending block on the demo account (it must hold a spendable
#      balance before it can send — a send to a never-opened Nano account is only RECEIVABLE)
#   2. sends the whole balance to DEST
#
# Run it yourself — deliberately not automated, because it moves money:
#
#     python3 deploy/recover-demo-payouts.py --dry-run     # show what would move, touch nothing
#     python3 deploy/recover-demo-payouts.py               # actually sweep
#
# Afterwards the demo account is empty and stays that way: RELAY_ACCT now points at DEST, so
# nothing new is ever paid into the derivable key again.
import argparse, importlib.util, json, os, sys, urllib.request

DEST = 'nano_1egg8kim6cw4dktmrttwno5hrcwwtey7c4i15xy1iwi8ixw1156881kkbhs3'
SEED_BYTE = 0x50            # acct(0x50) — what the relays advertised while XC_DEV=1 was set
RAW = 10 ** 30

ap = argparse.ArgumentParser()
ap.add_argument('--dry-run', action='store_true', help='report only; sign and broadcast nothing')
ap.add_argument('--dest', default=DEST, help='where to sweep to (default: %(default)s)')
args = ap.parse_args()

here = os.path.dirname(os.path.abspath(__file__))
common = os.path.join(os.path.dirname(here), 'backend', 'xc_common.py')
os.environ.setdefault('XC_NANO_RPC', 'https://nanoslo.0x.no/proxy,https://rainstorm.city/api')
spec = importlib.util.spec_from_file_location('xc', common)
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)
xc.RPCS = ['https://nanoslo.0x.no/proxy', 'https://rainstorm.city/api', 'https://node.somenano.com/proxy']

def get_work(root):
    """Proof-of-work for one block.

    xc.work_generate only speaks JSON-RPC POST, so it never sees the LOCAL GPU work server that
    run.sh already starts (xc_workd, GET /work?hash=..). That mattered: the public work endpoints
    were all answering HTTP 500, so the first attempt at this sweep sat grinding through them and
    died. The GPU does the same job in ~3s. Try it first, then fall back to the public ones.
    """
    for base in (os.environ.get('XC_WORK'), 'http://127.0.0.1:7503'):
        if not base:
            continue
        try:
            u = '%s/work?hash=%s&difficulty=%s' % (base.rstrip('/'), root, xc.MAINNET_WORK_DIFF)
            r = json.loads(urllib.request.urlopen(u, timeout=180).read())
            if r.get('work'):
                return r['work']
        except Exception:
            pass
    return xc.work_generate(root)          # public endpoints: slow, and currently flaky


key = xc.keyof(SEED_BYTE)
src, pub = xc.derive(key)
print('from : %s  (derivable demo key, seed byte 0x%02x)' % (src, SEED_BYTE))
print('to   : %s' % args.dest)

if not args.dest.startswith('nano_') or len(args.dest) != 65:
    sys.exit('destination is not a nano_ address of 65 characters')
try:
    xc.nano_to_pub(args.dest)
except Exception as e:
    sys.exit('destination failed its checksum: %s' % e)

rec = xc.rpc({'action': 'receivable', 'account': src, 'count': '200',
              'source': 'true', 'include_only_confirmed': 'false'})
blocks = rec.get('blocks') or {}
pending = sum(int(v['amount']) for v in blocks.values() if isinstance(v, dict)) if isinstance(blocks, dict) else 0
info = xc.rpc({'action': 'account_info', 'account': src})
balance = int(info['balance']) if 'balance' in info else 0
print('balance   : %.8f XNO' % (balance / RAW))
print('unreceived: %d block(s), %.8f XNO' % (len(blocks) if isinstance(blocks, dict) else 0, pending / RAW))
total = balance + pending
print('total     : %.8f XNO' % (total / RAW))

if total == 0:
    sys.exit('nothing to sweep — already empty')
if args.dry_run:
    sys.exit('dry run: nothing signed, nothing sent')

print('\nreceiving pending blocks…')
# Do the receives HERE rather than via xc._receive_all, so a failure says which block and why.
# The first run died somewhere in this loop and printed only a traceback on stderr.
opened = 'error' not in info
prev = info['frontier'] if opened else '0' * 64
bal = int(info['balance']) if opened else 0
for n, (h, meta) in enumerate(blocks.items(), 1):
    amt = int(meta['amount'])
    print('  [%d/%d] %s  %.8f XNO' % (n, len(blocks), h[:16] + '…', amt / RAW))
    try:
        root = prev if set(prev) != {'0'} else pub
        print('        proof-of-work…', end='', flush=True)
        wk = get_work(root)
        print(' ok')
        d = xc.sign(key, prev, pub, str(bal + amt), h)
        r = xc.rpc({'action': 'process', 'json_block': 'true',
                    'subtype': 'receive' if opened else 'open',
                    'block': {'type': 'state', 'account': src, 'previous': prev,
                              'representative': d['rep'], 'balance': str(bal + amt),
                              'link': h, 'signature': d['sig'], 'work': wk}})
        if not (isinstance(r, dict) and r.get('hash')):
            sys.exit('        REJECTED: %s' % ((r or {}).get('error', r)))
        prev, bal, opened = d['hash'], bal + amt, True
        print('        banked, running balance %.8f XNO' % (bal / RAW))
    except SystemExit:
        raise
    except Exception as e:
        sys.exit('        FAILED on this block: %s: %s' % (type(e).__name__, str(e)[:200]))
info = xc.rpc({'action': 'account_info', 'account': src})
if 'error' in info:
    sys.exit('account still not opened after receive: %s' % info['error'])
bal = int(info['balance'])
print('spendable now: %.8f XNO' % (bal / RAW))
if bal == 0:
    sys.exit('nothing spendable after receiving — stop here and look at why')

print('sending the full balance…')
d = xc.sign(key, info['frontier'], pub, '0', xc.nano_to_pub(args.dest))
r = xc.rpc({'action': 'process', 'json_block': 'true', 'subtype': 'send',
            'block': {'type': 'state', 'account': src, 'previous': info['frontier'],
                      'representative': d['rep'], 'balance': '0',
                      'link': xc.nano_to_pub(args.dest), 'signature': d['sig'],
                      'work': get_work(info['frontier'])}})
if isinstance(r, dict) and r.get('hash'):
    print('sent %.8f XNO -> %s' % (bal / RAW, args.dest))
    print('block: %s' % r['hash'])
    print('\nThe funds are RECEIVABLE at the destination — open the app so its wallet pockets them.')
else:
    sys.exit('send was not accepted: %s' % r)
