#!/usr/bin/env python3
"""Link previews: turn a URL in a post into a title, a description and a site name.

WHO FETCHES MATTERS MORE THAN WHAT IT LOOKS LIKE.

Three designs were possible and only one of them is honest:

  the reader's phone fetches   — every reader's IP and read-time goes to whatever host a post links
                                 to. Anyone could post a link and get a list of who read their post.
                                 That is a tracking pixel with extra steps, in an app whose whole
                                 claim is that relays see ciphertext and nothing else.
  the AUTHOR fetches, and the
  preview rides in the post    — cheapest, and the preview is signed. But then the author decides
                                 what the link "says": a card reading "nano.org — the digital
                                 currency" over a URL that goes somewhere else. The app renders the
                                 written URL precisely so text and destination cannot disagree;
                                 embedding an author-supplied summary hands that back.
  the NODE fetches  (this)     — the reader talks only to the node, which they already talk to. The
                                 card reflects what a neutral party actually retrieved, not what the
                                 author claims. The cost is that the node makes outbound requests to
                                 addresses a stranger chose, which is the danger this file spends
                                 most of its length on.

DMs MUST NEVER BE UNFURLED. A DM is end-to-end encrypted; asking the node to preview a link inside
one would hand the node a URL out of a conversation it is not supposed to be able to read. Previews
are a FEED feature. Nothing here is wired to the DM path, and nothing here should be.

SSRF: the guard is real, not decorative.
  - http/https only. No file:, no gopher:, no redirect into another scheme.
  - Every address the hostname resolves to must be globally routable. That rejects 127.0.0.1,
    10./172.16./192.168., 169.254.169.254 (the cloud metadata endpoint — the prize in most SSRF
    write-ups), CGNAT, multicast and the reserved ranges.
  - The connection is made TO THE VALIDATED IP with the Host header set, rather than by re-resolving
    the name. Validating a name and then handing that name to a fetcher is a DNS-rebinding hole:
    the check and the connection are two lookups, and an attacker only has to control what the
    second one returns.
  - Redirects are followed by hand, at most 3, each one re-validated from scratch.
  - The body is capped and the whole thing is on a short timeout, so a slow or endless response
    cannot pin a node worker.

Cached hard, successes and failures both, because the alternative is a public endpoint that fetches
whatever anyone asks for as often as they ask.
"""
import os, sys, json, time, socket, ssl, hashlib, ipaddress, http.client, urllib.parse
from html.parser import HTMLParser

TIMEOUT = float(os.environ.get('XC_UNFURL_TIMEOUT', '5'))     # per connect/read
MAX_BYTES = int(os.environ.get('XC_UNFURL_MAX', str(256 * 1024)))
MAX_REDIRECTS = 3
OK_TTL = float(os.environ.get('XC_UNFURL_TTL', str(6 * 3600)))
# Failures are cached too, briefly. A link that 404s is still in the post, so every reader who
# scrolls past would otherwise re-trigger the same doomed fetch.
FAIL_TTL = float(os.environ.get('XC_UNFURL_FAIL_TTL', '600'))
CACHE_DIR = os.environ.get('XC_UNFURL_CACHE', '/tmp/xc_unfurl')
UA = 'XChatBot/1.0 (+link preview; one fetch, cached)'


class Blocked(Exception):
    """Refused before any packet left the machine."""


def _check_ip(addr):
    ip = ipaddress.ip_address(addr)
    # is_global already excludes loopback, private, link-local, CGNAT and the reserved blocks; the
    # multicast test is belt-and-braces for the IPv6 side.
    if not ip.is_global or ip.is_multicast:
        raise Blocked('address is not globally routable: %s' % addr)
    return ip


def resolve_public(host, port):
    """Every address this name resolves to must be public. Returns (family, sockaddr) to connect to.

    ALL of them, not the first: a name with one public A record and one pointing at 127.0.0.1 is a
    deliberate attack, not a misconfiguration, and picking the first answer makes it a coin flip.
    """
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise Blocked('cannot resolve %s: %s' % (host, e))
    if not infos:
        raise Blocked('cannot resolve %s' % host)
    for fam, _t, _p, _c, sa in infos:
        _check_ip(sa[0])
    fam, _t, _p, _c, sa = infos[0]
    return fam, sa


def _split(url):
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ('http', 'https'):
        raise Blocked('scheme not allowed: %s' % (u.scheme or '(none)'))
    if not u.hostname:
        raise Blocked('no host')
    port = u.port or (443 if u.scheme == 'https' else 80)
    path = urllib.parse.urlunsplit(('', '', u.path or '/', u.query, ''))
    return u.scheme, u.hostname, port, path


def fetch(url, depth=0):
    """GET a URL through every guard above. Returns (final_url, html_text). Raises Blocked."""
    if depth > MAX_REDIRECTS:
        raise Blocked('too many redirects')
    scheme, host, port, path = _split(url)
    fam, sa = resolve_public(host, port)

    sock = socket.socket(fam, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.connect(sa)
        if scheme == 'https':
            # server_hostname is the NAME even though we dialled the IP: the certificate must still
            # be valid for the site the reader is being shown.
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        conn = http.client.HTTPConnection(host, port, timeout=TIMEOUT)
        conn.sock = sock                       # already connected, to an address we checked ourselves
        conn.request('GET', path, headers={
            'Host': host if port in (80, 443) else '%s:%d' % (host, port),
            'User-Agent': UA,
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'en',
            'Connection': 'close',
        })
        r = conn.getresponse()
        if r.status in (301, 302, 303, 307, 308):
            loc = r.getheader('Location') or ''
            r.read(1)
            if not loc:
                raise Blocked('redirect without a destination')
            # Relative redirects are normal; urljoin also keeps a scheme-relative //host working.
            return fetch(urllib.parse.urljoin(url, loc), depth + 1)
        if r.status != 200:
            raise Blocked('http %d' % r.status)
        ctype = (r.getheader('Content-Type') or '').split(';')[0].strip().lower()
        if ctype and ctype not in ('text/html', 'application/xhtml+xml'):
            raise Blocked('not a page: %s' % ctype)
        raw = r.read(MAX_BYTES)
        charset = 'utf-8'
        for part in (r.getheader('Content-Type') or '').split(';')[1:]:
            if 'charset=' in part:
                charset = part.split('charset=')[1].strip().strip('"\'') or 'utf-8'
        return url, raw.decode(charset, 'replace')
    except Blocked:
        raise
    except Exception as e:
        raise Blocked('fetch failed: %s' % e)
    finally:
        try:
            sock.close()
        except Exception:
            pass


class _Meta(HTMLParser):
    """Pull the handful of tags a card needs. A parser, not a regex — HTML is not a regular language
    and the attribute order in the wild is whatever the CMS felt like."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta = {}
        self.title = ''
        self._in_title = False
        self._done_head = False

    def handle_starttag(self, tag, attrs):
        if self._done_head:
            return
        if tag == 'title':
            self._in_title = True
        elif tag == 'meta':
            a = {k.lower(): (v or '') for k, v in attrs}
            key = (a.get('property') or a.get('name') or '').lower()
            if key and a.get('content'):
                self.meta.setdefault(key, a['content'])

    def handle_endtag(self, tag):
        if tag == 'title':
            self._in_title = False
        elif tag == 'head':
            self._done_head = True      # everything a preview wants is in <head>; stop reading a novel

    def handle_data(self, data):
        if self._in_title and len(self.title) < 400:
            self.title += data


def _clean(s, cap):
    s = ' '.join((s or '').split())          # collapse the newlines and tabs a CMS leaves in
    return s[:cap].strip()


def parse(html_text, base_url):
    """og: first, then twitter:, then the plain tags. Absent fields come back empty, never None, so a
    client never has to distinguish 'missing' from 'null'."""
    p = _Meta()
    try:
        p.feed(html_text)
        # close() flushes what feed() is still holding. HTMLParser buffers an incomplete trailing
        # construct waiting for more input, so without this a page cut off mid-tag — which is
        # exactly what the MAX_BYTES cap produces on a large page — silently loses its title.
        p.close()
    except Exception:
        pass                                  # a half-parsed head still yields a usable title
    m = p.meta

    def pick(*keys):
        for k in keys:
            if m.get(k):
                return m[k]
        return ''

    title = _clean(pick('og:title', 'twitter:title') or p.title, 200)
    desc = _clean(pick('og:description', 'twitter:description', 'description'), 300)
    site = _clean(pick('og:site_name'), 60) or (urllib.parse.urlsplit(base_url).hostname or '')
    image = pick('og:image', 'og:image:url', 'twitter:image')
    if image:
        image = urllib.parse.urljoin(base_url, image)
        # Only ever hand back an http(s) image. Nothing downstream should be asked to reason about a
        # data: URI that arrived from a stranger's page.
        if urllib.parse.urlsplit(image).scheme not in ('http', 'https'):
            image = ''
    return {'title': title, 'desc': desc, 'site': site, 'image': image}


def _cache_path(url):
    return os.path.join(CACHE_DIR, hashlib.sha256(url.encode()).hexdigest()[:32] + '.json')


def unfurl(url, use_cache=True):
    """The whole thing: cache → guard → fetch → parse → cache. Always returns a dict, never raises.

    A failure is a RESULT, not an exception: the caller is an HTTP handler serving a card that is
    allowed to be absent, and a link that cannot be previewed should render as the plain link it
    already was.
    """
    url = (url or '').strip()
    if not url:
        return {'ok': False, 'error': 'no url'}
    path = _cache_path(url)
    if use_cache:
        try:
            c = json.load(open(path))
            ttl = OK_TTL if c.get('ok') else FAIL_TTL
            if time.time() - c.get('cached_at', 0) < ttl:
                return c
        except Exception:
            pass
    try:
        final_url, html_text = fetch(url)
        out = parse(html_text, final_url)
        out.update({'ok': bool(out['title']), 'url': url})
        if not out['ok']:
            out['error'] = 'no title'         # a page with no title has nothing to show on a card
    except Blocked as e:
        out = {'ok': False, 'url': url, 'error': str(e)}
    except Exception as e:
        out = {'ok': False, 'url': url, 'error': 'unfurl failed: %s' % e}
    out['cached_at'] = time.time()
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(out, f)
        os.replace(tmp, path)                 # atomic: a reader never sees a half-written card
    except Exception:
        pass
    return out


if __name__ == '__main__':
    print(json.dumps(unfurl(sys.argv[1] if len(sys.argv) > 1 else ''), indent=2))
