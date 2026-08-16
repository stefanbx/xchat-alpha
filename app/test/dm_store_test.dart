// The on-device DM store keeps decrypted messages so a poll stops re-decrypting history — measured
// at 437ms per poll over 500 messages before any caching. Speed is the reason it exists; being
// ENCRYPTED at rest is the reason it is allowed to exist. The whole claim of DMs is that relays hold
// ciphertext and nothing else, so a plaintext cache on the phone would hand away to any process with
// storage access exactly what we refused to give the network.
//
// So the tests here are about confidentiality first and hit-rate second:
//   - what lands in preferences must not contain the message
//   - a different seed must not be able to read it
//   - replacing or logging out of a wallet must remove it
//
// Two earlier caching attempts broke wallet_test.dart's recipient isolation (plaintext keyed by
// ciphertext, then a static Box map), which is why the store keys by ciphertext ONLY in a place that
// has already established the message is ours.
//
//   cd app && flutter test test/dm_store_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/main.dart' show DmStore;
import 'package:xchat/wallet.dart';

const _secret = 'the numbers are 4 8 15 16 23 42';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final alice = NanoWallet('a1' * 32);
  final mallory = NanoWallet('b2' * 32);

  // DmStore holds process-wide state (it is a cache, and the app has one wallet at a time). Reset it
  // between tests or the previous test's in-memory entries make put() a no-op and flush() skip the
  // write, which shows up as a confusing "the owning wallet cannot read it back".
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.clear(alice.account);
    await DmStore.clear(mallory.account);
  });

  Future<Map<String, Object?>> prefsDump() async {
    final p = await SharedPreferences.getInstance();
    return {for (final k in p.getKeys()) k: p.get(k)};
  }

  test('what reaches disk is ciphertext — the message is not in preferences', () async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.load(alice);
    DmStore.put('ct-1', _secret, 1000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);
    await DmStore.flush(alice);

    final dump = await prefsDump();
    expect(dump.keys.any((k) => k.startsWith('xchat_dm_store_')), isTrue,
        reason: 'the store should have written something');
    final blob = dump.values.map((v) => '$v').join('\n');
    // The plaintext must appear nowhere, in any encoding a casual dump would reveal.
    expect(blob.contains(_secret), isFalse, reason: 'plaintext leaked into preferences');
    expect(blob.contains(base64.encode(utf8.encode(_secret))), isFalse,
        reason: 'plaintext leaked base64-encoded');
  });

  test('the owning wallet can read it back', () async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.load(alice);
    DmStore.put('ct-1', _secret, 1000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);
    await DmStore.flush(alice);

    // Simulate a fresh app start: same wallet, memory cleared by loading someone else first.
    await DmStore.clear(mallory.account);
    await DmStore.load(alice);
    expect(DmStore.get('ct-1'), _secret);
  });

  test('a DIFFERENT seed cannot read the blob, and does not crash on it', () async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.load(alice);
    DmStore.put('ct-1', _secret, 1000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);
    await DmStore.flush(alice);
    final onDisk = await prefsDump();

    // Mallory's store is keyed by her own account, so she sees nothing of Alice's...
    await DmStore.load(mallory);
    expect(DmStore.get('ct-1'), isNull);

    // ...and even handed Alice's blob directly, Mallory's key cannot open it. This is the property
    // that makes it safe to keep the sealed blob in ordinary preferences at all.
    final aliceBlob = onDisk.entries
        .firstWhere((e) => e.key.contains(alice.account)).value as String;
    expect(mallory.dmOpen(mallory.dmPub, aliceBlob), isNull);
    expect(mallory.dmOpen(alice.dmPub, aliceBlob), isNull);
  });

  test('a corrupt blob yields an empty store rather than an exception', () async {
    // A poll must never be broken by a bad cache — it should just re-fetch and re-decrypt.
    SharedPreferences.setMockInitialValues(
        {'xchat_dm_store_${alice.account}': 'not-base64-!!!'});
    await DmStore.load(alice);
    expect(DmStore.get('ct-1'), isNull);
  });

  test('clear() removes the messages from disk, not just from memory', () async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.load(alice);
    DmStore.put('ct-1', _secret, 1000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);
    await DmStore.flush(alice);
    expect((await prefsDump()).keys.any((k) => k.contains(alice.account)), isTrue);

    // Handing the phone on, or restoring a different wallet, must not leave conversations behind.
    await DmStore.clear(alice.account);
    expect((await prefsDump()).keys.any((k) => k.contains(alice.account)), isFalse);
    await DmStore.load(alice);
    expect(DmStore.get('ct-1'), isNull);
  });

  test('re-putting a known ciphertext does not duplicate or overwrite', () async {
    SharedPreferences.setMockInitialValues({});
    await DmStore.clear(alice.account);
    await DmStore.load(alice);
    DmStore.put('ct-1', _secret, 1000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);
    DmStore.put('ct-1', 'tampered', 2000,
        from: alice.account, outgoing: false, peer: mallory.account, peerPk: mallory.dmPub);      // same ciphertext can only mean one plaintext
    expect(DmStore.get('ct-1'), _secret);
    expect(DmStore.count, 1);
  });
}
