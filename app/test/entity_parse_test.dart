// Links, @mentions and #hashtags in a post body.
//
// The risk here is OVER-matching, not under-matching. Every false positive turns a piece of ordinary
// prose into a link that goes somewhere wrong — an email address becomes a mention of a stranger, a
// C# reference becomes a tag, a sentence-ending "@home." gains a trailing dot in the name. Under-
// matching just leaves text as text, which is what it already was.
//
// So this pins the boundaries rather than the happy path.
//
// It imports the REAL scanner. The first version of this file re-declared the regex by hand to avoid
// pulling in the app, which meant the expression under test was not the expression that shipped — and
// the divergence was not theoretical: the shipped one linked the '#tag' inside a URL fragment while
// this file's copy "proved" it did not.
//
//   cd app && flutter test test/entity_parse_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/body.dart';

/// Just the marked-up pieces, in order — what a reader would see rendered differently from prose.
List<String> entities(String s) => scanBody(s)
    .where((t) => t.kind != BodyKind.text)
    .map((t) => t.text)
    .toList();

List<String> links(String s) =>
    scanBody(s).where((t) => t.kind == BodyKind.link).map((t) => t.value).toList();

void main() {
  test('every token together reproduces the input, always', () {
    // The invariant the renderer leans on: it concatenates token texts, so any gap or overlap here
    // silently eats or duplicates a reader's words.
    for (final s in <String>[
      '', 'plain words only', '@alice hi #tag', 'see https://ex.com/a. thanks',
      'bob@example.com and C# and ##x and (https://ex.com/b)',
      'https://ex.com/#frag @you.xno! ...', '@a #  @@b http://', 'ünïcödé @ok #tág',
    ]) {
      expect(scanBody(s).map((t) => t.text).join(), s, reason: 'coverage broke on ${s.length}: "$s"');
    }
  });

  group('finds what it should', () {
    test('a mention', () => expect(entities('hey @jiovan look'), ['@jiovan']));
    test('a hashtag', () => expect(entities('shipping #nano today'), ['#nano']));
    test('a link', () => expect(entities('read https://nano.org/whitepaper now'),
        ['https://nano.org/whitepaper']));
    test('both, several', () {
      expect(entities('@alice and @bob on #xno #crypto'),
          ['@alice', '@bob', '#xno', '#crypto']);
    });
    test('at the very start and end', () {
      expect(entities('@alice hi'), ['@alice']);
      expect(entities('ends with #tag'), ['#tag']);
      expect(entities('ends with https://ex.com'), ['https://ex.com']);
    });
    test('handles with dots, dashes and underscores', () {
      expect(entities('@you.xno @a-b @a_b'), ['@you.xno', '@a-b', '@a_b']);
    });
  });

  group('does NOT match', () {
    test('an email address', () {
      // The killer case: "mail me at bob@example.com" must not mention @example.com.
      expect(entities('mail me at bob@example.com'), isEmpty);
    });
    test('a bare @ or #', () {
      expect(entities('@ # @@ ##'), isEmpty);
    });
    test('a one-character handle', () {
      expect(entities('@a'), isEmpty);            // too short to be a real handle
    });
    test('a hash inside a word', () {
      expect(entities('C#'), isEmpty);
      expect(entities('item#4'), isEmpty);
    });
    test('a doubled sigil', () {
      expect(entities('##tag'), isEmpty);
      expect(entities('@@name'), isEmpty);
    });
    test('a bare domain — deliberately', () {
      // No scheme, no link. Guessing at bare domains cannot tell "example.com" from "etc.io", and a
      // wrong link is worse than plain text.
      expect(entities('go to example.com for more'), isEmpty);
    });
    test('a scheme with nothing after it', () {
      expect(entities('the difference between http:// and https://'), isEmpty);
    });
    test('a non-http scheme', () {
      // Nothing here can produce javascript:, file: or intent: — they are not in the grammar at all,
      // which is the only reliable way to keep them out of a URL handed to the OS.
      expect(entities('javascript:alert(1) file:///etc/passwd intent://x'), isEmpty);
    });
  });

  group('a URL is consumed whole', () {
    test('its fragment is not a hashtag', () {
      // The bug this file previously failed to catch: '/' satisfies the tag lookbehind, so the
      // fragment in a rooted URL used to render as a link to a tag nobody wrote.
      expect(entities('https://example.com/#nano'), ['https://example.com/#nano']);
      expect(entities('https://example.com/page#section'), ['https://example.com/page#section']);
    });
    test('an @ in its path is not a mention', () {
      expect(entities('https://x.com/@someone/status/1'), ['https://x.com/@someone/status/1']);
    });
    test('a query string survives intact', () {
      expect(links('https://ex.com/s?q=a&b=c#top'), ['https://ex.com/s?q=a&b=c#top']);
    });
    test('www. is linked, and normalised to an absolute URL', () {
      expect(entities('see www.nano.org today'), ['www.nano.org']);
      expect(links('see www.nano.org today'), ['https://www.nano.org']);
    });
    test('a www. inside an email address is not a link', () {
      expect(entities('bob@www.example.com'), isEmpty);
    });
  });

  group('boundaries are where a reader would put them', () {
    test('trailing punctuation is not part of a tag', () {
      // '#nano.' would otherwise link to a tag nobody wrote.
      expect(entities('about #nano.'), ['#nano']);
      expect(entities('about #nano, then'), ['#nano']);
      expect(entities('(#nano)'), ['#nano']);
    });
    test('trailing punctuation is not part of a URL', () {
      expect(links('see https://ex.com/a.'), ['https://ex.com/a']);
      expect(links('see https://ex.com/a, then'), ['https://ex.com/a']);
      expect(links('(https://ex.com/a)'), ['https://ex.com/a']);
      expect(links('"https://ex.com/a"'), ['https://ex.com/a']);
    });
    test('a bracket the URL itself opened is kept', () {
      // Wikipedia's disambiguation paths are real, and stripping the ')' 404s them.
      expect(links('https://en.wikipedia.org/wiki/Nano_(cryptocurrency)'),
          ['https://en.wikipedia.org/wiki/Nano_(cryptocurrency)']);
    });
    test('a handle does not end in a dot or dash', () {
      expect(entities('ask @jiovan.'), ['@jiovan']);
      expect(entities('@you.xno!'), ['@you.xno']);
      expect(entities('@a-b-'), ['@a-b']);
    });
    test('numbers are fine, alone or mixed', () {
      expect(entities('#2026 #v2 @user42'), ['#2026', '#v2', '@user42']);
    });
    test('an emoji next to an entity does not swallow it', () {
      expect(entities('👍 #nano 🚀'), ['#nano']);
    });
  });

  group('firstLink', () {
    test('is the first one, not the last', () {
      expect(firstLink('a https://one.com b https://two.com'), 'https://one.com');
    });
    test('is null when there is none', () {
      expect(firstLink('just @alice and #nano here'), isNull);
    });
    test('is absolute even when written bare', () {
      expect(firstLink('www.nano.org'), 'https://www.nano.org');
    });
  });
}
