// A failed or timed-out DM poll must SHOW the on-device store, not empty the thread.
//
// The bug the user saw as "my DMs disappear then appear again": dmInbox() returned [] from its catch
// block on ANY fetch failure — a timeout, a slow node, a dropped connection. The chat screen then did
// `_msgs = next` with that empty result, so the whole conversation vanished until the next good poll
// restored it. The 12s timeout added earlier to stop DMs HANGING is what made a failed poll frequent
// enough to see it strobe.
//
// The store is the source of truth: every message ever decrypted, persisted and sealed to our own
// key. A poll that fetches nothing must ADD nothing — never REMOVE everything. So dmInbox() now
// rebuilds from the store on failure as well as success.
//
// This drives the real Api.dmInbox() with the network failing. Under TestWidgetsFlutterBinding every
// HTTP request returns 400 with a body that does not parse, so the fetch path throws and the catch
// fires — the exact failure this fix is about — with no mocking needed.
//
//   cd app && flutter test test/dm_flicker_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/main.dart' show Api, DmStore, gWallet;
import 'package:xchat/wallet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NanoWallet('a1' * 32);
  final peer = NanoWallet('b2' * 32);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gWallet = me;
    await DmStore.clear(me.account);
    await DmStore.load(me);
  });

  Future<void> seed() async {
    // Two messages in one conversation, already decrypted and in the store — i.e. history the user is
    // currently looking at.
    DmStore.put('ct-1', 'dinner at eight', 1000,
        from: peer.account, outgoing: false, peer: peer.account, peerPk: peer.dmPub);
    DmStore.put('ct-2', 'on my way', 1100,
        from: me.account, outgoing: true, peer: peer.account, peerPk: peer.dmPub);
    await DmStore.flush(me);
  }

  test('a FAILED poll returns the stored conversation, not an empty list', () async {
    await seed();
    // The network is down (every request 400s under test). This is the poll that used to wipe the
    // thread.
    final convos = await Api.dmInbox();
    expect(convos, isNotEmpty, reason: 'a failed poll emptied the inbox — this is the flicker');
    final mine = convos.firstWhere((c) => c['peer'] == peer.account, orElse: () => {});
    expect(mine, isNotEmpty, reason: 'the conversation vanished on a failed poll');
    final msgs = (mine['messages'] as List).cast<Map<String, dynamic>>();
    expect(msgs.length, 2, reason: 'a failed poll must not shrink the thread');
    expect(msgs.map((m) => m['text']), containsAll(['dinner at eight', 'on my way']));
  });

  test('messages stay put across repeated failed polls — no strobe', () async {
    await seed();
    // Ten polls in a row, all failing. Every one must return the same full history; none may blank it
    // even for a single tick.
    for (var i = 0; i < 10; i++) {
      final convos = await Api.dmInbox();
      final mine = convos.firstWhere((c) => c['peer'] == peer.account, orElse: () => {});
      expect((mine['messages'] as List?)?.length, 2,
          reason: 'poll #$i lost the conversation — that is the disappear/reappear the user reported');
    }
  });

  test('the thread comes back ordered oldest-first, whatever the poll did', () async {
    // Insert out of order; the store→conversation build must sort by ts so a failed poll cannot also
    // scramble the thread.
    DmStore.put('ct-late', 'later', 2000,
        from: me.account, outgoing: true, peer: peer.account, peerPk: peer.dmPub);
    DmStore.put('ct-early', 'earlier', 1000,
        from: peer.account, outgoing: false, peer: peer.account, peerPk: peer.dmPub);
    await DmStore.flush(me);

    final convos = await Api.dmInbox();
    final msgs = (convos.first['messages'] as List).cast<Map<String, dynamic>>();
    expect(msgs.map((m) => m['text']).toList(), ['earlier', 'later']);
  });

  test('an empty store with a failed poll returns empty — no phantom conversation', () async {
    // The fix must not invent messages. Nothing stored and nothing fetched is genuinely nothing.
    final convos = await Api.dmInbox();
    expect(convos, isEmpty);
  });

  test('a second peer keeps its own thread; a failed poll does not merge or drop them', () async {
    await seed();
    final peer2 = NanoWallet('c3' * 32);
    DmStore.put('ct-x', 'from someone else', 1500,
        from: peer2.account, outgoing: false, peer: peer2.account, peerPk: peer2.dmPub);
    await DmStore.flush(me);

    final convos = await Api.dmInbox();
    expect(convos.length, 2, reason: 'a failed poll collapsed two conversations into one, or lost one');
    final peers = convos.map((c) => c['peer']).toSet();
    expect(peers, {peer.account, peer2.account});
  });
}
