// @mentions and #hashtags in a post body.
//
// The risk here is OVER-matching, not under-matching. Every false positive turns a piece of ordinary
// prose into a link that goes somewhere wrong — an email address becomes a mention of a stranger, a
// C# reference becomes a tag, a sentence-ending "@home." gains a trailing dot in the name. Under-
// matching just leaves text as text, which is what it already was.
//
// So this pins the boundaries rather than the happy path.
//
//   cd app && flutter test test/entity_parse_test.dart
import 'package:flutter_test/flutter_test.dart';

// Kept in step with the expression in main.dart. Duplicated deliberately: importing it would drag in
// the whole app for a pure-string test, and the point is to pin the SHAPE we intend.
final RegExp entityRe =
    RegExp(r'(?<![\w@])@([A-Za-z0-9_.-]{2,32})|(?<![\w#])#([A-Za-z0-9_]{1,48})');

List<String> entities(String s) =>
    entityRe.allMatches(s).map((m) => s.substring(m.start, m.end)).toList();

void main() {
  group('finds what it should', () {
    test('a mention', () => expect(entities('hey @jiovan look'), ['@jiovan']));
    test('a hashtag', () => expect(entities('shipping #nano today'), ['#nano']));
    test('both, several', () {
      expect(entities('@alice and @bob on #xno #crypto'),
          ['@alice', '@bob', '#xno', '#crypto']);
    });
    test('at the very start and end', () {
      expect(entities('@alice hi'), ['@alice']);
      expect(entities('ends with #tag'), ['#tag']);
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
    test('a URL fragment', () {
      expect(entities('https://example.com/page#section'), isEmpty);
    });
    test('a doubled sigil', () {
      expect(entities('##tag'), isEmpty);
      expect(entities('@@name'), isEmpty);
    });
  });

  group('boundaries are where a reader would put them', () {
    test('trailing punctuation is not part of a tag', () {
      // '#nano.' would otherwise link to a tag nobody wrote.
      expect(entities('about #nano.'), ['#nano']);
      expect(entities('about #nano, then'), ['#nano']);
      expect(entities('(#nano)'), ['#nano']);
    });
    test('a handle keeps internal dots but the regex bounds the length', () {
      expect(entities('@you.xno!'), ['@you.xno']);
    });
    test('numbers are fine, alone or mixed', () {
      expect(entities('#2026 #v2 @user42'), ['#2026', '#v2', '@user42']);
    });
    test('an emoji next to an entity does not swallow it', () {
      expect(entities('👍 #nano 🚀'), ['#nano']);
    });
  });
}
