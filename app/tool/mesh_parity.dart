// Parity check: reproduce xc_tunnel.token_seed / token_for in Dart and compare
// against the Python reference values. Run: dart run tool/mesh_parity.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:nanodart/nanodart.dart' show Blake2b, NanoHelpers;
import '../lib/crypto/ed25519_blake2b.dart' as webed;

const _kdfDomain = 'xchat/mesh-tunnel/v1';

String _urlNorm(String url) {
  var u = url.trim();
  while (u.endsWith('/')) u = u.substring(0, u.length - 1);
  final i = u.indexOf('://');
  return i >= 0 ? u.substring(i + 3) : u;
}

Uint8List _tokenSeed(String secret, String entryId, int epoch) {
  final b = BytesBuilder();
  b.add(utf8.encode(_kdfDomain));
  b.add([0x7c]); // '|'
  b.add(utf8.encode(secret));
  b.add([0x7c]);
  b.add(utf8.encode(entryId));
  b.add([0x7c]);
  b.add(utf8.encode('$epoch'));
  return Blake2b.digest256([b.toBytes()]);
}

String _tokenFor(String secret, String entryId, int epoch) {
  final seed = _tokenSeed(secret, entryId, epoch);
  final pub = webed.publicKeyFromSecret(seed);
  return NanoHelpers.byteToHex(pub).toLowerCase();
}

void main() {
  const secret = 'xchat-mesh-live-test-2026-08';
  final eid = _urlNorm('https://xchat-alpha-node.fly.dev');
  print('entry_id = $eid');
  final expect = {
    490000: [
      '2d49a319fb4567667e3fd57ef32661ad71773ceeb8a34f7c925e29a1f7548eb3',
      '3235191d570acbc3f3da6bc4ebf41c01fc6d8232c03461f41c6cf226f826f0fd',
    ],
    491000: [
      '27473f2f783ee6dcd984849d6f2f913115225f41ac452a01d34250b9e9ec7df5',
      '52ebc2e81ad8e944b66f38a038367774eca99e04352310b070244e554c47fd8e',
    ],
  };
  var ok = true;
  for (final epoch in expect.keys) {
    final seed = NanoHelpers.byteToHex(_tokenSeed(secret, eid, epoch)).toLowerCase();
    final pub = _tokenFor(secret, eid, epoch);
    final seedOk = seed == expect[epoch]![0];
    final pubOk = pub == expect[epoch]![1];
    ok = ok && seedOk && pubOk;
    print('epoch=$epoch');
    print('  seed ${seedOk ? "MATCH" : "MISMATCH"}  $seed');
    print('  pub  ${pubOk ? "MATCH" : "MISMATCH"}  $pub');
  }
  print(ok ? '\nPARITY OK ✅' : '\nPARITY FAILED ❌');
}
