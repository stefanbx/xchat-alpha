// The app half of the on-device-signing contract, testable with no node and no network.
//
// `test/interop_test.py` at the repo root proves the node ACCEPTS what this signs. This proves the
// wallet itself behaves: the same seed always yields the same identity (a restore on another phone
// has to return the same account), the canonical messages are byte-exact (the node rebuilds them
// from its own side, so a stray space here is a rejected post there), and a DM only opens for the
// peer it was sealed to.
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
    expect(w.headMsg(5, 'bafycid', 9999999), '$a|5|bafycid|9999999');
    expect(w.postEventMsg('you.xno', 'post', 'hi', 7), 'you.xno|post|hi|7');
    expect(w.commentMsg('p1', 7, 'nice', ''), 'p1|$a|7|nice|');
    expect(w.pollMsg('poll1', '0', 7), 'poll1|$a|0|7');
    expect(w.profileMsg(7, 'Alice', 'bio', '', ''), '$a|7|Alice|bio||');
    expect(w.dmKeyMsg(7, 'abc'), '$a|7|abc');
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
