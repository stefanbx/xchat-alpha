// What a post body is made of: plain text, links, @mentions, #hashtags.
//
// ORDER IS THE WHOLE TRICK. A URL is matched first and consumed WHOLE, so `https://ex.com/page#top`
// cannot have its fragment re-read as a hashtag and `https://x.com/@someone` cannot become a mention.
// Scanning entities first tears every fragment-bearing URL in half — and that is not hypothetical:
// before this file, `#tag` in `https://ex.com/#tag` DID match, because the character before it was a
// '/', which the tag lookbehind happily allows.
//
// Conservative by design. Over-matching is worse than under-matching, because a false positive turns
// ordinary prose into a link that goes somewhere WRONG, and a wrong link is worse than no link at all:
// `bob@example.com` is an email, `C#` is a language, and the '.' ending a sentence is punctuation
// rather than the last character of a path.
//
// Split out of main.dart so the tests exercise the REAL scanner. The previous version lived inline and
// the test file re-declared the regex by hand; two copies of a parser is two parsers, and the one
// under test is never the one that ships.

enum BodyKind { text, link, mention, tag }

class BodyToken {
  final BodyKind kind;
  final String text;    // the source substring, exactly as written — never a rewritten display form
  final String value;   // link: an absolute URL; mention: handle without '@'; tag: tag without '#'
  const BodyToken(this.kind, this.text, this.value);

  @override
  String toString() => '${kind.name}:$text';
  @override
  bool operator ==(Object o) =>
      o is BodyToken && o.kind == kind && o.text == text && o.value == value;
  @override
  int get hashCode => Object.hash(kind, text, value);
}

// 1: url   2: mention   3: tag
//
// The URL alternative demands an explicit `https?://` or a `www.` prefix. Bare-domain detection (X
// links `example.com`) is deliberately absent: it cannot tell a domain from "etc.io" or from the end
// of a sentence, and every mistake it makes is a link. The lookbehind keeps a URL from starting inside
// a longer token — `bob@www.example.com` is one email address, not an email followed by a website.
final RegExp _bodyRe = RegExp(
  r'(?<![\w@.])((?:https?://|www\.)[^\s<>]+)'
  r'|(?<![\w@])@([A-Za-z0-9_.-]{2,32})'
  r'|(?<![\w#])#([A-Za-z0-9_]{1,48})',
);

const String _trail = '.,;:!?…"\'«»“”';

/// Where a URL actually ends, once the sentence around it is subtracted.
///
/// "see https://ex.com/a." links to `/a`; "(https://ex.com)" links without the bracket. A closing
/// bracket only goes when nothing inside the URL opened it — Wikipedia's `..._(disambiguation)` is a
/// real path, and a blanket strip would break it.
int _urlEnd(String s, int start, int end) {
  var e = end;
  while (e > start) {
    final c = s[e - 1];
    if (_trail.contains(c)) {
      e--;
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      final open = c == ')' ? '(' : (c == ']' ? '[' : '{');
      final body = s.substring(start, e);
      if (open.allMatches(body).length < c.allMatches(body).length) {
        e--;
        continue;
      }
    }
    break;
  }
  return e;
}

/// Still a URL after trimming? "https://." is not, and neither is the bare scheme left behind by a
/// sentence like "the difference between http:// and https://".
bool _isUrl(String u) {
  final rest = u.startsWith('www.') ? u.substring(4) : u.replaceFirst(RegExp(r'^https?://'), '');
  return rest.length > 1 && RegExp(r'[A-Za-z0-9]').hasMatch(rest);
}

/// A handle may contain dots and dashes (`@you.xno`, `@a-b`) but cannot END with one: "ask @jiovan."
/// is a sentence about jiovan, not a mention of a handle nobody registered.
int _wordEnd(String s, int start, int end) {
  var e = end;
  while (e > start && (s[e - 1] == '.' || s[e - 1] == '-')) {
    e--;
  }
  return e;
}

/// Break a body into tokens. Always covers the input exactly: concatenating every token's `text`
/// reproduces the original string, so a renderer can never silently drop or duplicate a reader's words.
List<BodyToken> scanBody(String s) {
  final out = <BodyToken>[];
  var i = 0;
  void plain(int a, int b) {
    if (b > a) out.add(BodyToken(BodyKind.text, s.substring(a, b), ''));
  }

  for (final m in _bodyRe.allMatches(s)) {
    if (m.start < i) continue;
    plain(i, m.start);
    if (m.group(1) != null) {
      final e = _urlEnd(s, m.start, m.end);
      final raw = s.substring(m.start, e);
      if (_isUrl(raw)) {
        out.add(BodyToken(BodyKind.link, raw, raw.startsWith('www.') ? 'https://$raw' : raw));
        i = e;                       // whatever was trimmed becomes plain text on the next pass
        continue;
      }
      plain(m.start, m.end);
      i = m.end;
    } else if (m.group(2) != null) {
      final e = _wordEnd(s, m.start + 1, m.end);
      final raw = s.substring(m.start, e);
      if (raw.length > 2) {          // '@' plus at least two characters, same floor as the regex
        out.add(BodyToken(BodyKind.mention, raw, raw.substring(1)));
        i = e;
        continue;
      }
      plain(m.start, m.end);
      i = m.end;
    } else {
      out.add(BodyToken(BodyKind.tag, s.substring(m.start, m.end), m.group(3)!));
      i = m.end;
    }
  }
  plain(i, s.length);
  return out;
}

/// The first link in a body, or null — what a preview card would unfurl.
String? firstLink(String s) {
  for (final t in scanBody(s)) {
    if (t.kind == BodyKind.link) return t.value;
  }
  return null;
}
