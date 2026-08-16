#!/usr/bin/env python3
"""Push delivery: a DM arrives when it is sent, not when the recipient next gets round to asking.

A DM used to wait for a poll — 5s inside a thread, 12s for the unread badge. That interval IS the
product: a chat where a reply can take twelve seconds to appear reads as a mailbox. The node already
sees every message sent through it, so it can wake the recipient directly.

Two invariants matter more than the speed, and both are the kind that fail silently:

  ISOLATION   a nudge for one account must never reach another account's stream. Getting this wrong
              leaks the fact that a specific person just received a message — to anyone who asks for
              a stream. It would look completely fine in use.

  NO CONTENT  the stream carries {"ts": ...}, meaning "there is something for you", and nothing else.
              Ciphertext continues to travel by the existing inbox path. If a payload ever creeps
              into the stream, the node is handling message content on a channel that was designed
              on the assumption that it does not.

Runs a REAL node on a spare port, in isolation (XC_ISOLATE=1, unroutable bootstrap) so nothing here
can reach the live relay mesh.

    python3 test/dm_push_test.py
"""
import json, os, socket, subprocess, sys, threading, time, urllib.error, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, 'backend')

DM_PING_S = 1.0                    # must match XC_DM_PING below

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()
BASE = f'http://127.0.0.1:{PORT}'
env = dict(os.environ,
           XC_ISOLATE='1',
           XCHAT_BOOTSTRAP='http://127.0.0.1:1',      # unroutable: cannot touch the real mesh
           XC_NS=f'pushtest{PORT}',
           XC_DM_WATCH='2',
           XC_DM_PING='1',                            # so the keep-alive is observable in a short test
           XC_DM_MAX_STREAMS='4')                     # small, so the cap is reachable
proc = subprocess.Popen([sys.executable, 'kt_server.py', str(PORT)], cwd=BACKEND, env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def stop():
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()


def wait_up(timeout=45):
    end = time.time() + timeout
    while time.time() < end:
        try:
            urllib.request.urlopen(BASE + '/api/status', timeout=2).read()
            return True
        except Exception:
            time.sleep(0.3)
    return False


class Stream:
    """An SSE reader on its own thread, collecting raw bytes as they arrive."""

    def __init__(self, account):
        self.buf = ''
        self.events = []
        self.status = None
        self.headers = {}
        self.stop = False
        self.t = threading.Thread(target=self._run, args=(account,), daemon=True)
        self.t.start()

    def _run(self, account):
        try:
            r = urllib.request.urlopen(f'{BASE}/api/dm_events?account={account}', timeout=30)
            self.status = r.status
            self.headers = {k.lower(): v for k, v in r.headers.items()}
            while not self.stop:
                line = r.readline()
                if not line:
                    break
                self.buf += line.decode('utf-8', 'replace')
                if line.startswith(b'data:'):
                    self.events.append(self.buf)
        except urllib.error.HTTPError as e:
            self.status = e.code
            self.headers = {k.lower(): v for k, v in e.headers.items()}
        except Exception:
            pass

    def wait_for(self, needle, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.buf:
                return True
            time.sleep(0.02)
        return False


def send_dm(to, frm='nano_1alice', ct='THISISTHECIPHERTEXT', ts=None):
    body = json.dumps({'to': to, 'from': frm, 'ct': ct, 'ts': int(ts or time.time())}).encode()
    req = urllib.request.Request(BASE + '/api/dm_send', body, {'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=15).read())


try:
    if not wait_up():
        print('FAIL — node did not start')
        print((proc.stdout.read() or b'').decode()[:2000])
        stop()
        sys.exit(1)

    print('--- the stream opens and says so ---')
    bob = Stream('nano_1bob')
    check(bob.wait_for('event: ready', 6), 'a ready event arrives without waiting for a message')
    check(bob.status == 200, 'stream returns 200', str(bob.status))
    check(bob.headers.get('content-type') == 'text/event-stream', 'content-type is text/event-stream')
    check('no-cache' in (bob.headers.get('cache-control') or ''), 'the stream is not cacheable')
    # Without this, a proxy buffers the response and the client gets nothing until bytes pile up —
    # push silently degrading into something WORSE than polling.
    check(bob.headers.get('x-accel-buffering') == 'no', 'buffering is disabled for proxies')

    print('\n--- a send wakes the recipient, quickly ---')
    t0 = time.time()
    r = send_dm('nano_1bob', ts=1786900001)
    got = bob.wait_for('event: dm', 5)
    dt = time.time() - t0
    check(got, 'the recipient is nudged by the send itself')
    check(dt < 2.0, f'and it is fast (took {dt:.2f}s, poll would have been 5-12s)', f'{dt:.2f}s')
    check('"ts": 1786900001' in bob.buf, 'the nudge carries the timestamp to fetch from')
    check(r.get('ok') is True, 'the send still reports its own result normally')

    print('\n--- NO CONTENT on the stream ---')
    # The whole design rests on this: the stream says "there is something for you", and the ciphertext
    # travels by the inbox path that already exists. One decryption path, and a bug in the stream can
    # delay a message but never leak one.
    check('THISISTHECIPHERTEXT' not in bob.buf, 'the ciphertext never appears on the stream')
    check('nano_1alice' not in bob.buf, 'nor does the sender — the stream is not a metadata channel')
    payloads = [l.split('data:', 1)[1].strip() for l in bob.buf.splitlines() if l.startswith('data:')]
    check(all(set(json.loads(p) or {}) <= {'ts'} for p in payloads if p),
          'every data payload contains at most a ts', str(payloads))

    print('\n--- ISOLATION between accounts ---')
    carol = Stream('nano_1carol')
    check(carol.wait_for('event: ready', 6), "carol's stream opens")
    before = carol.buf
    send_dm('nano_1bob', ts=1786900002)
    time.sleep(1.5)
    # The failure this catches is invisible in use: carol's app would simply refresh a little more
    # often, while learning exactly when bob receives mail.
    check('event: dm' not in carol.buf[len(before):],
          "a message for bob does NOT reach carol's stream", carol.buf[len(before):][:200])
    check(bob.wait_for('"ts": 1786900002', 5), 'and bob still got his')

    print('\n--- two streams for the SAME account both get it ---')
    # Phone and desktop at once. A registry keyed by account only, holding one queue, would silently
    # deliver to whichever connected last.
    bob2 = Stream('nano_1bob')
    check(bob2.wait_for('event: ready', 6), 'a second stream for bob opens')
    send_dm('nano_1bob', ts=1786900003)
    check(bob.wait_for('"ts": 1786900003', 5), 'first stream nudged')
    check(bob2.wait_for('"ts": 1786900003', 5), 'second stream nudged too')

    print('\n--- keep-alive ---')
    # Intermediaries in front of a home relay close an idle connection minutes later and tell nobody.
    # The client would sit there believing it had push. The ping is also the only way the server
    # learns a client has gone, so its interval doubles as how long a dead stream holds its slot.
    idle = Stream('nano_1dave')
    check(idle.wait_for('event: ready', 6), "dave's stream opens")
    check(idle.wait_for(': ping', 6), 'an idle stream is kept alive with comments')

    print('\n--- shedding, not queueing ---')
    # XC_DM_MAX_STREAMS=4, and bob + carol + bob2 + dave already fill it.
    over = Stream('nano_1eve')
    time.sleep(1.5)
    check(over.status == 503, 'past the cap the node refuses instead of accepting a dead stream',
          str(over.status))
    check((over.headers.get('retry-after') or '') != '', 'and says when to come back')

    print('\n--- a stream with no account is refused ---')
    try:
        body = urllib.request.urlopen(BASE + '/api/dm_events', timeout=10).read().decode()
        check(json.loads(body).get('ok') is False, 'no account → an error, not a stream', body[:120])
    except Exception as e:
        check(False, 'no account → an error, not a stream', str(e))

    print('\n--- disconnecting frees the slot ---')
    # Without an unsubscribe on the way out, the registry fills with dead streams and the cap above
    # eventually refuses everybody — a node that stops accepting push and never says why.
    for s in (bob, bob2, carol, idle):
        s.stop = True
    time.sleep(0.3)
    for s in (bob, bob2, carol, idle):
        s.t.join(timeout=2)
    time.sleep(DM_PING_S * 3)      # the slot is only released when the server next tries to write
    fresh = Stream('nano_1frank')
    check(fresh.wait_for('event: ready', 8), 'a new stream is accepted after the others hang up',
          f'status={fresh.status}')
    fresh.stop = True

finally:
    stop()

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
