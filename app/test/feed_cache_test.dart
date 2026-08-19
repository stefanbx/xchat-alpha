// On-device feed cache: the app persists a BOUNDED, merged set of posts and, on launch, loads them
// instantly and fetches only what's newer — instead of re-downloading the whole feed every time. This
// verifies the core of that without a device or network (SharedPreferences is mocked):
//   1. a Post round-trips through toJson/fromJson with every field intact;
//   2. saveCachedPosts EVICTS oldest-first down to the cap (bounded store, like a relay's);
//   3. loadCachedPosts returns newest-first regardless of input order;
//   4. an absent cache reads back as empty (first-run safe).
//
//   cd app && flutter test test/feed_cache_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/main.dart' show Api, Post;

Post _p(String id, int ts,
        {String kind = 'post', String text = 'hi', String? media, String? replyTo, List<String>? poll}) =>
    Post(id, 'a.xno', 'nano_x', kind, text, null, media, null, null, ts, 0, 0,
        replyTo: replyTo, poll: poll);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('absent cache reads back empty (first run)', () async {
    expect(await Api.loadCachedPosts(), isEmpty);
  });

  test('round-trips every field through save/load', () async {
    final orig = _p('cid1', 1000,
        kind: 'poll', text: 'best chain?', media: 'ipfs://x', replyTo: 'parent1', poll: ['nano', 'btc']);
    await Api.saveCachedPosts([orig], 300);
    final back = (await Api.loadCachedPosts()).single;
    expect(back.id, 'cid1');
    expect(back.ts, 1000);
    expect(back.kind, 'poll');
    expect(back.text, 'best chain?');
    expect(back.media, 'ipfs://x');
    expect(back.replyTo, 'parent1');
    expect(back.poll, ['nano', 'btc']);
  });

  test('caps to size, evicting OLDEST first', () async {
    final posts = [for (var i = 0; i < 10; i++) _p('id$i', 1000 + i)]; // ts 1000..1009
    await Api.saveCachedPosts(posts, 3);
    final back = await Api.loadCachedPosts();
    expect(back.length, 3);
    expect(back.map((p) => p.id), ['id9', 'id8', 'id7']); // newest 3 kept, newest-first
  });

  test('loads newest-first regardless of input order', () async {
    await Api.saveCachedPosts([_p('old', 100), _p('new', 300), _p('mid', 200)], 300);
    expect((await Api.loadCachedPosts()).map((p) => p.id), ['new', 'mid', 'old']);
  });

  test('cap <= 0 keeps everything (no accidental wipe)', () async {
    await Api.saveCachedPosts([_p('a', 1), _p('b', 2)], 0);
    expect((await Api.loadCachedPosts()).length, 2);
  });
}
