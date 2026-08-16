#!/usr/bin/env python3
"""Link-preview unfurling — mostly a test of what it REFUSES to fetch.

/api/unfurl is the only endpoint on the node that makes an outbound request to an address a stranger
picked, which makes it the one place where a bug is a server-side request forgery rather than a
cosmetic glitch. The prize in most SSRF write-ups is 169.254.169.254, the cloud metadata endpoint:
reach it and you read the instance's credentials. This node runs on Fly.

So the fetch guards get tested first and hardest, and almost all of it runs WITHOUT network: the
address checks work on literals, the parser works on fixture strings, and the redirect and scheme
rules are refused before a packet leaves.

    python3 test/unfurl_test.py
"""
import os, sys, json, time, socket, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'backend'))
import xc_unfurl as U

fails = []
checks = [0]


def ok(cond, label):
    checks[0] += 1
    print(('ok    ' if cond else 'FAIL  ') + label)
    if not cond:
        fails.append(label)


def blocked(fn, label, *a, **kw):
    """The call must raise Blocked — not succeed, and not die with some other exception."""
    checks[0] += 1
    try:
        fn(*a, **kw)
    except U.Blocked:
        print('ok    ' + label)
        return
    except Exception as e:
        print('FAIL  %s  (raised %s, not Blocked)' % (label, type(e).__name__))
        fails.append(label)
        return
    print('FAIL  %s  (was allowed)' % label)
    fails.append(label)


print('--- addresses that must never be dialled ---')
# Every one of these has been somebody's incident.
for addr, why in [
    ('127.0.0.1', 'loopback'),
    ('0.0.0.0', 'unspecified'),
    ('10.0.0.5', 'private 10/8'),
    ('172.16.0.5', 'private 172.16/12'),
    ('192.168.1.1', 'private 192.168/16'),
    ('169.254.169.254', 'CLOUD METADATA — the one that leaks credentials'),
    ('100.64.0.1', 'CGNAT'),
    ('::1', 'IPv6 loopback'),
    ('fd00::1', 'IPv6 unique-local'),
    ('fe80::1', 'IPv6 link-local'),
    ('ff02::1', 'IPv6 multicast'),
    ('224.0.0.1', 'IPv4 multicast'),
]:
    blocked(U._check_ip, 'refuses %-16s (%s)' % (addr, why), addr)

ok(U._check_ip('93.184.216.34') is not None, 'allows an ordinary public address')
ok(U._check_ip('2606:2800:220:1:248:1893:25c8:1946') is not None, 'allows a public IPv6 address')

print('\n--- names that resolve inward ---')
blocked(U.resolve_public, 'refuses localhost, however it resolves', 'localhost', 80)
# The rebinding shape: a name whose answer set is not entirely public. resolve_public checks EVERY
# answer rather than the first, so one poisoned record is enough to refuse the whole name.
_real = socket.getaddrinfo


def _mixed(host, port, *a, **kw):
    if host == 'rebind.test':
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('93.184.216.34', port)),
                (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('127.0.0.1', port))]
    return _real(host, port, *a, **kw)


socket.getaddrinfo = _mixed
try:
    blocked(U.resolve_public, 'refuses a name with ONE private answer among public ones',
            'rebind.test', 80)
finally:
    socket.getaddrinfo = _real

print('\n--- schemes and shapes refused before any packet ---')
for url, why in [
    ('file:///etc/passwd', 'file:'),
    ('gopher://evil/x', 'gopher:'),
    ('ftp://host/x', 'ftp:'),
    ('javascript:alert(1)', 'javascript:'),
    ('data:text/html,<h1>x', 'data:'),
    ('//evil.com/x', 'no scheme'),
    ('http://', 'no host'),
]:
    blocked(U._split, 'refuses %-24s (%s)' % (url, why), url)

s, h, p, path = U._split('https://example.com/a/b?q=1#frag')
ok((s, h, p) == ('https', 'example.com', 443), 'parses scheme/host/default port')
ok(path == '/a/b?q=1', 'sends the path and query, and NOT the fragment (it is client-side only)')
ok(U._split('http://example.com:8080/x')[2] == 8080, 'honours an explicit port')

print('\n--- redirects ---')
blocked(U.fetch, 'gives up rather than following redirects forever',
        'https://example.com/', U.MAX_REDIRECTS + 1)

print('\n--- parsing a page ---')
PAGE = '''<!doctype html><html><head>
<meta charset="utf-8">
<title>  Fallback   title\n  here </title>
<meta property="og:title" content="Nano — Digital money for the modern world">
<meta property="og:description" content="Nano is a  cryptocurrency\nwith zero fees.">
<meta property="og:site_name" content="Nano">
<meta property="og:image" content="/img/card.png">
</head><body><p>ignored</p></body></html>'''
m = U.parse(PAGE, 'https://nano.org/page')
ok(m['title'] == 'Nano — Digital money for the modern world', 'og:title wins over <title>')
ok(m['desc'] == 'Nano is a cryptocurrency with zero fees.', 'whitespace in a description is collapsed')
ok(m['site'] == 'Nano', 'og:site_name is used when present')
ok(m['image'] == 'https://nano.org/img/card.png', 'a relative og:image is made absolute')

m = U.parse('<html><head><title>  Just   a title </title></head></html>', 'https://ex.com/x')
ok(m['title'] == 'Just a title', 'falls back to <title>, collapsed')
ok(m['site'] == 'ex.com', 'falls back to the hostname as the site name')
ok(m['desc'] == '' and m['image'] == '', 'absent fields are empty strings, never null')

m = U.parse('<html><head><meta name="twitter:title" content="T">'
            '<meta name="description" content="D"></head></html>', 'https://ex.com/')
ok(m['title'] == 'T' and m['desc'] == 'D', 'twitter: and plain description are read too')

m = U.parse('<html><head><title>x</title>'
            '<meta property="og:image" content="javascript:alert(1)"></head></html>',
            'https://ex.com/')
ok(m['image'] == '', 'a non-http og:image is dropped, not passed on')

m = U.parse('<html><head><title>t</title><meta property="og:description" content="%s">'
            '</head></html>' % ('x' * 900), 'https://ex.com/')
ok(len(m['desc']) <= 300, 'a description is capped rather than echoed whole')

m = U.parse('<html><head><title>ok</title></head><body>' + '<p>x</p>' * 5000 + '</body></html>',
            'https://ex.com/')
ok(m['title'] == 'ok', 'a huge body does not break the head parse')

m = U.parse('<html><head><title>unclosed', 'https://ex.com/')
ok(m['title'].strip() == 'unclosed', 'truncated HTML still yields what it had')

print('\n--- results and caching ---')
U.CACHE_DIR = tempfile.mkdtemp(prefix='unfurl-test-')
r = U.unfurl('file:///etc/passwd')
ok(r['ok'] is False and 'scheme' in r['error'], 'a refused URL returns a result, it does not raise')
ok(U.unfurl('') == {'ok': False, 'error': 'no url'}, 'an empty URL is refused without touching disk')

# A blocked fetch is cached too, or a bad link in a popular post re-fetches on every scroll past it.
r2 = U.unfurl('file:///etc/passwd')
ok(r2.get('cached_at') == r.get('cached_at'), 'a FAILURE is served from cache, not retried')
ok(len(os.listdir(U.CACHE_DIR)) == 1, 'one cache file per URL')

# ...but only until FAIL_TTL, so a site that was down gets another chance.
c = json.load(open(U._cache_path('file:///etc/passwd')))
c['cached_at'] = time.time() - (U.FAIL_TTL + 60)
json.dump(c, open(U._cache_path('file:///etc/passwd'), 'w'))
r3 = U.unfurl('file:///etc/passwd')
ok(r3['cached_at'] != c['cached_at'], 'a stale failure is retried once its short TTL passes')

ok(U._cache_path('https://a.com/') != U._cache_path('https://b.com/'),
   'different URLs get different cache files')
ok(U.OK_TTL > U.FAIL_TTL, 'a success is cached far longer than a failure')

print('\n--- DMs are never unfurled ---')
# The invariant with the worst failure mode here, and the easiest to break by accident: a DM is
# end-to-end encrypted, so previewing a link inside one hands the node a URL out of a conversation it
# is specifically unable to read. Nobody would write that on purpose — someone would move the shared
# body renderer into the chat bubble for consistency and never notice what came with it. So it is
# checked against the source rather than left to reviewer memory.
_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         '..', 'app', 'lib', 'main.dart')).read()
_lines = _src.splitlines()


def _class_body(name):
    """The source of one class: from its declaration to the next top-level one."""
    start = next((i for i, l in enumerate(_lines) if l.startswith('class %s ' % name)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(_lines)) if _lines[i].startswith('class ')), len(_lines))
    return '\n'.join(_lines[start:end])


for cls in ('_DmChatScreenState', '_DmInboxScreenState'):
    body = _class_body(cls)
    ok(body is not None, 'found %s in the source (rename it and fix this test)' % cls)
    if body:
        ok('LinkPreview' not in body and 'firstLink' not in body,
           '%s does not unfurl — no node fetch from an E2E conversation' % cls)

ok(_src.count('LinkPreview(url:') == 1,
   'exactly one place builds a preview card (the post card), so the blast radius stays known')

print('\n--- limits are set, not just intended ---')
ok(U.MAX_BYTES <= 512 * 1024, 'the body is capped (%d bytes)' % U.MAX_BYTES)
ok(U.TIMEOUT <= 10, 'the timeout is short (%ss)' % U.TIMEOUT)
ok(U.MAX_REDIRECTS <= 5, 'redirects are capped (%d)' % U.MAX_REDIRECTS)

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks[0], len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
