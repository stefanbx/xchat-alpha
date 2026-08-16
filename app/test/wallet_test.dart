// The app half of the on-device-signing contract, testable with no node and no network.
//
// `test/interop_test.py` at the repo root proves the node ACCEPTS what this signs. This proves the
// wallet itself behaves: the same seed always yields the same identity (a restore on another phone
// has to return the same account), the canonical messages are byte-exact (the node rebuilds them
// from its own side, so a stray space here is a rejected post there), and a DM only opens for the
// peer it was sealed to.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/wallet.dart';

void main() {
  final seedA = '07' * 32;
  final seedB = '42' * 32;

  test('a seed always derives the same identity', () {
    final w = NanoWallet(seedA);
    expect(w.account, NanoWallet(seedA).account);
    expect(w.account, startsWith('nano_'));
    expect(w.pub.length, 64);
    expect(NanoWallet(seedB).account, isNot(w.account));
  });

  test('the account round-trips through its own public key', () {
    final w = NanoWallet(seedA);
    expect(w.pubOf(w.account), w.pub);
  });

  test('canonical messages are byte-exact', () {
    final w = NanoWallet(seedA);
    final a = w.account;
    // These expectations are built from the v2 RULE, not pasted from the implementation's output —
    // otherwise the test only proves the code agrees with itself. v2 (issue #7) is domain-tagged and
    // LENGTH-PREFIXED: "xchat/sig/v2/<type>" then "|<utf8 bytelen>:<field>" per field. The prefixes
    // are what stop two different field lists colliding on one preimage, e.g. ["a|b","c"] vs
    // ["a","b|c"], which under the old bare "|"-join signed identical bytes.
    //
    // This block asserted the LEGACY format until now and had been failing since v2 landed — unnoticed
    // because the Python suite never ran the Dart tests. It does now (test/dart_test.py).
    String canon(String type, List<Object> fields) =>
        'xchat/sig/v2/$type' +
        fields.map((f) => '|${utf8.encode(f.toString()).length}:$f').join();

    expect(w.headMsg(5, 'bafycid', 9999999), canon('head', [a, 5, 'bafycid', 9999999]));
    expect(w.postEventMsg('you.xno', 'post', 'hi', 7), canon('post', ['you.xno', 'post', 'hi', 7]));
    expect(w.commentMsg('p1', 7, 'nice', ''), canon('comment', ['p1', a, 7, 'nice', '']));
    expect(w.pollMsg('poll1', '0', 7), canon('poll', ['poll1', a, '0', 7]));
    expect(w.profileMsg(7, 'Alice', 'bio', '', ''), canon('profile', [a, 7, 'Alice', 'bio', '', '']));
    expect(w.dmKeyMsg(7, 'abc'), canon('dmkey', [a, 7, 'abc']));
    // A multi-byte field must be counted in BYTES, not characters, or the prefix lies.
    expect(w.postEventMsg('you.xno', 'post', 'héllo', 7),
        canon('post', ['you.xno', 'post', 'héllo', 7]));
    expect(w.postEventMsg('you.xno', 'post', 'héllo', 7), contains('|6:héllo|'));
    // The separator-injection case v2 exists to prevent: different fields, different preimages.
    expect(w.commentMsg('p1|x', 7, 'nice', ''), isNot(w.commentMsg('p1', 7, 'x|nice', '')));
    // the follow list is SORTED before signing, so two devices holding the same set sign the same
    // bytes regardless of the order they followed people in
    expect(w.followMsg(7, ['nano_b', 'nano_a']), w.followMsg(7, ['nano_a', 'nano_b']));
  });

  test('signing is deterministic and carries the signer', () {
    final w = NanoWallet(seedA);
    final s = w.signMsg('hello');
    expect(s['sig'], w.signMsg('hello')['sig']);
    expect(s['sig']!.length, 128);
    expect(s['pub'], w.pub);
    expect(w.signMsg('hello ')['sig'], isNot(s['sig']));
  });

  test('a DM opens for its recipient and nobody else', () {
    final a = NanoWallet(seedA), b = NanoWallet(seedB);
    final sealed = a.dmSeal(b.dmPub, 'meet at six');
    expect(b.dmOpen(a.dmPub, sealed), 'meet at six');
    // the DM keypair is separate from the Nano one, and a third party cannot open the box
    expect(a.dmPub, isNot(a.pub));
    expect(NanoWallet('99' * 32).dmOpen(a.dmPub, sealed), isNull);
  });
}
