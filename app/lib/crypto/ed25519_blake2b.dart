// Ed25519-Blake2b (Nano's signature scheme) implemented with BigInt, so it works on the WEB.
//
// WHY THIS EXISTS. nanodart signs via a TweetNaCl port whose field arithmetic is Uint64List, and
// dart2js has no 64-bit integers — under JS every call throws UnsupportedError, so the browser build
// cannot derive a key or sign anything. The usual fix is to re-limb the arithmetic the way
// tweetnacl-js does (16-bit limbs in a Float64Array); that is fiddly, easy to get subtly wrong, and a
// subtle error here forges or corrupts money. BigInt sidesteps the whole class of bug: there is no
// limb, no carry, no overflow to reason about, and Dart's BigInt is exact on both the VM and JS.
// The cost is speed, and it does not matter — a wallet signs a handful of blocks, not a stream.
//
// THIS IS ONLY USED ON THE WEB. Android keeps signing through nanodart, which is what every existing
// install already used; see NanoWallet. So a defect here cannot reach the phone build.
//
// CORRECTNESS. This is RFC-8032 Ed25519 with Blake2b-512 substituted for SHA-512, matching
// TweetNaclFast.cryptoSign byte for byte. It is checked against nanodart over random vectors in
// test/ed25519_blake2b_test.dart, and those signatures are additionally verified by the node's
// independent Python verifier (nanopy) — a different language and a different implementation.
//
// LIMITATION, stated plainly: BigInt operations are not constant-time, so this leaks timing about the
// secret scalar in a way the TweetNaCl code does not. In a browser tab that is a secondary concern
// next to the seed living in ordinary site storage (which the UI already warns about), but it is a
// real difference and a reason the phone app remains the place for an account of any value.
import 'dart:typed_data';

import 'package:nanodart/nanodart.dart' show Blake2b;

// Curve25519 / Ed25519 domain parameters (RFC 8032 §5.1).
final BigInt _p = (BigInt.one << 255) - BigInt.from(19); // field prime 2^255 - 19
final BigInt _l = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493'); // group order
final BigInt _d = BigInt.parse(
        '37095705934669439343138083508754565189542113879843219016388785533085940283555') %
    _p; // -121665/121666
final BigInt _d2 = (_d * BigInt.two) % _p;

// The standard base point B, in extended coordinates (X : Y : Z : T), Z = 1, T = X*Y.
final BigInt _bx = BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202');
final BigInt _by = BigInt.parse(
    '46316835694926478169428394003475163141307993866256225615783033603165251855960');
final List<BigInt> _base = [_bx, _by, BigInt.one, (_bx * _by) % _p];

final BigInt _byteMask = BigInt.from(0xff);

BigInt _decodeLE(List<int> b) {
  var r = BigInt.zero;
  for (int i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _encodeLE(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (int i = 0; i < len; i++) {
    out[i] = (x & _byteMask).toInt();
    x >>= 8;
  }
  return out;
}

/// Point addition in extended twisted-Edwards coordinates for a = -1 (add-2008-hwcd-3). The formula
/// is unified — correct for doubling too — which removes the "did I pick the right case" class of bug.
List<BigInt> _add(List<BigInt> p1, List<BigInt> p2) {
  final a = ((p1[1] - p1[0]) * (p2[1] - p2[0])) % _p;
  final b = ((p1[1] + p1[0]) * (p2[1] + p2[0])) % _p;
  final c = (p1[3] * _d2 % _p) * p2[3] % _p;
  final dd = (p1[2] * BigInt.two % _p) * p2[2] % _p;
  final e = (b - a) % _p;
  final f = (dd - c) % _p;
  final g = (dd + c) % _p;
  final h = (b + a) % _p;
  return [(e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p];
}

List<BigInt> _scalarMult(List<BigInt> point, BigInt e) {
  var q = <BigInt>[BigInt.zero, BigInt.one, BigInt.one, BigInt.zero]; // identity
  var n = point;
  var k = e;
  while (k > BigInt.zero) {
    if (k.isOdd) q = _add(q, n);
    n = _add(n, n);
    k >>= 1;
  }
  return q;
}

/// (X:Y:Z:T) -> the 32-byte little-endian encoding of y with x's low bit in the top bit.
Uint8List _encodePoint(List<BigInt> p) {
  final zInv = p[2].modInverse(_p);
  final x = (p[0] * zInv) % _p;
  final y = (p[1] * zInv) % _p;
  final out = _encodeLE(y, 32);
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

Uint8List _blake2b512(List<Uint8List> parts) => Blake2b.digest(64, parts);

/// The clamped scalar and the prefix, from a 32-byte secret: h = Blake2b-512(sk); the low half is
/// clamped to a valid scalar, the high half is the deterministic nonce prefix.
Uint8List _expand(Uint8List secret) {
  final h = _blake2b512([secret]);
  h[0] &= 248;
  h[31] &= 127;
  h[31] |= 64;
  return h;
}

/// 32-byte secret key -> 32-byte Ed25519-Blake2b public key. Matches `Nano.pkFromSecret`.
Uint8List publicKeyFromSecret(Uint8List secret) {
  if (secret.length != 32) {
    throw ArgumentError('secret key must be 32 bytes, got ${secret.length}');
  }
  final h = _expand(secret);
  final a = _decodeLE(h.sublist(0, 32));
  return _encodePoint(_scalarMult(_base, a));
}

/// Detached 64-byte signature over [message] with a 32-byte secret key.
/// Matches `Signature.detached(message, secret)` from nanodart byte for byte.
///
/// A signature needs the signer's own public key as part of the challenge hash. Deriving it costs a
/// scalar multiplication — the single most expensive operation here — and the caller almost always
/// has it already (NanoWallet holds it), so [publicKey] lets that be skipped: it halves the cost of
/// every signature. It is only ever an optimisation; pass nothing and it is derived as before. Note a
/// WRONG key would produce a signature that verifies against nothing, so it is validated for length
/// and, in debug builds, checked against the derived value.
Uint8List signDetached(Uint8List message, Uint8List secret, {Uint8List? publicKey}) {
  if (secret.length != 32) {
    throw ArgumentError('secret key must be 32 bytes, got ${secret.length}');
  }
  if (publicKey != null && publicKey.length != 32) {
    throw ArgumentError('public key must be 32 bytes, got ${publicKey.length}');
  }
  final pk = publicKey ?? publicKeyFromSecret(secret);
  assert(() {
    final derived = publicKeyFromSecret(secret);
    return _bytesEqual(pk, derived);
  }(), 'the supplied public key does not belong to this secret key');
  final h = _expand(secret);
  final a = _decodeLE(h.sublist(0, 32));

  // r = Blake2b-512(prefix || m) mod l — deterministic, so the same message never signs two ways.
  final r = _decodeLE(_blake2b512([h.sublist(32, 64), message])) % _l;
  final rPoint = _encodePoint(_scalarMult(_base, r));

  final k = _decodeLE(_blake2b512([rPoint, pk, message])) % _l;
  final s = (r + k * a) % _l;

  final sig = Uint8List(64);
  sig.setRange(0, 32, rPoint);
  sig.setRange(32, 64, _encodeLE(s, 32));
  return sig;
}

// ---- verification: not needed to sign, but it lets the app self-check a signature it just made,
// and it is what the round-trip test exercises. Mirrors RFC 8032 §5.1.7.
final BigInt _sqrtM1 =
    BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);

List<BigInt>? _decodePoint(Uint8List b) {
  if (b.length != 32) return null;
  final y = _decodeLE(b) & ((BigInt.one << 255) - BigInt.one);
  if (y >= _p) return null;
  final y2 = (y * y) % _p;
  final u = (y2 - BigInt.one) % _p;
  final v = (_d * y2 + BigInt.one) % _p;
  final vInv = v.modInverse(_p);
  var x2 = (u * vInv) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  final wantOdd = (b[31] & 0x80) != 0;
  if (x.isOdd != wantOdd) x = (_p - x) % _p;
  return [x, y, BigInt.one, (x * y) % _p];
}

bool verifyDetached(Uint8List message, Uint8List signature, Uint8List publicKey) {
  if (signature.length != 64 || publicKey.length != 32) return false;
  final aPoint = _decodePoint(publicKey);
  if (aPoint == null) return false;
  final s = _decodeLE(signature.sublist(32, 64));
  if (s >= _l) return false; // reject malleable / non-canonical S
  final rPoint = signature.sublist(0, 32);
  final k = _decodeLE(_blake2b512([rPoint, publicKey, message])) % _l;
  final lhs = _scalarMult(_base, s);
  final rhs = _add(_decodePoint(rPoint) ?? aPoint, _scalarMult(aPoint, k));
  if (_decodePoint(rPoint) == null) return false;
  return _bytesEqual(_encodePoint(lhs), _encodePoint(rhs));
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
