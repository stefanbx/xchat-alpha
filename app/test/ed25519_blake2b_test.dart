// The BigInt Ed25519-Blake2b used by the web build must agree with nanodart EXACTLY — the phone signs
// with nanodart and the node verifies with nanopy, so a web signature that differs by one byte is a
// post nobody accepts or, worse, a tip that moves the wrong money. These tests run on the Dart VM,
// where both implementations work, and compare them over random vectors.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanodart/nanodart.dart';
import 'package:xchat/crypto/ed25519_blake2b.dart' as web;

Uint8List _hexToBytes(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Deterministic: a failure must be reproducible, not "sometimes red".
  final rng = Random(0xC0FFEE);
  Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

  test('public key matches nanodart over 200 random secrets', () {
    for (int i = 0; i < 200; i++) {
      final sk = randomBytes(32);
      final mine = _toHex(web.publicKeyFromSecret(sk)).toUpperCase();
      final theirs = NanoKeys.createPublicKey(_toHex(sk).toUpperCase());
      expect(mine, theirs, reason: 'public key mismatch for sk=${_toHex(sk)}');
    }
  });

  test('signature matches nanodart over 200 random (key, message) pairs', () {
    for (int i = 0; i < 200; i++) {
      final sk = randomBytes(32);
      // Nano signs 32-byte block hashes, but the app also signs arbitrary canonical strings, so
      // vary the length — including the empty message and lengths that straddle Blake2b's block.
      final msg = randomBytes([0, 1, 31, 32, 33, 63, 64, 65, 127, 200][i % 10]);
      final mine = _toHex(web.signDetached(msg, sk)).toUpperCase();
      final theirs = NanoSignatures.signBlock(_toHex(msg), _toHex(sk).toUpperCase());
      expect(mine, theirs,
          reason: 'signature mismatch for sk=${_toHex(sk)} msg=${_toHex(msg)}');
    }
  });

  // NOTE: nanodart's own Signature.detachedVerify cannot be used as an oracle — it throws
  // "Invalid digest length (required: 1 - 64)" even on signatures nanodart itself just produced
  // (its cryptoHashOff passes a bad digestSize to Blake2bDigest). That is a defect in the package,
  // not in either signer, and the app never calls it: the NODE verifies, with nanopy. So the oracles
  // here are byte-equality with nanodart's signatures above, our own verifier below, and the
  // cross-language check against the node's Python verifier in test/crosscheck_nanopy.sh.

  test('our verifier accepts nanodart signatures and rejects tampering', () {
    for (int i = 0; i < 50; i++) {
      final sk = randomBytes(32);
      final msg = randomBytes(32);
      final sig = _hexToBytes(
          NanoSignatures.signBlock(_toHex(msg), _toHex(sk).toUpperCase()).toLowerCase());
      final pk = _hexToBytes(NanoKeys.createPublicKey(_toHex(sk).toUpperCase()).toLowerCase());
      expect(web.verifyDetached(msg, sig, pk), isTrue, reason: 'rejected a valid signature');

      final flipped = Uint8List.fromList(sig)..[rng.nextInt(64)] ^= 1 << rng.nextInt(8);
      expect(web.verifyDetached(msg, flipped, pk), isFalse,
          reason: 'accepted a signature with one bit flipped');

      final otherMsg = Uint8List.fromList(msg)..[rng.nextInt(32)] ^= 0x01;
      expect(web.verifyDetached(otherMsg, sig, pk), isFalse,
          reason: 'accepted a signature over a different message');
    }
  });

  test('the address derived from our public key matches nanodart end to end', () {
    for (int i = 0; i < 50; i++) {
      final seedHex = _toHex(randomBytes(32)).toUpperCase();
      final priv = NanoKeys.seedToPrivate(seedHex, 0);       // Blake2b only — web-safe already
      final mine = _toHex(web.publicKeyFromSecret(_hexToBytes(priv.toLowerCase()))).toUpperCase();
      expect(NanoAccounts.createAccount(NanoAccountType.NANO, mine),
          NanoAccounts.createAccount(NanoAccountType.NANO, NanoKeys.createPublicKey(priv)));
    }
  });

  test('rejects a wrong-sized secret instead of signing garbage', () {
    expect(() => web.publicKeyFromSecret(Uint8List(31)), throwsArgumentError);
    expect(() => web.signDetached(Uint8List(4), Uint8List(64)), throwsArgumentError);
  });
}
