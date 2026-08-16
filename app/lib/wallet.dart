// On-device signing. The seed NEVER leaves the device: this class derives the Nano keypair and
// signs every event/block locally with nanodart (ed25519-blake2b), byte-compatible with the node's
// verifier. The node only relays already-signed payloads and reads the ledger — it holds no seed.
import 'dart:convert';
import 'dart:typed_data';
import 'package:nanodart/nanodart.dart';
import 'package:pinenacl/x25519.dart' as pnacl;
import 'crypto/ed25519_blake2b.dart' as webed;

// kIsWeb WITHOUT depending on Flutter. wallet.dart has to stay importable by a plain `dart run`,
// because bin/interop_sign.dart is exactly that — the signer behind test/interop_test.py and
// test/e2e_test.py, the tests that back the "your seed never leaves the device" claim. Importing
// package:flutter/foundation here drags in dart:ui and breaks them on the VM. This is the identical
// expression Flutter defines kIsWeb with, so the value matches on both platforms.
const bool _kIsWeb = bool.fromEnvironment('dart.library.js_util');

class NanoWallet {
  final String seed; // 64 hex — held only here, only on this device
  late final String priv;
  late final String pub;      // 32-byte public key, hex
  late final String account;  // nano_ address

  // The curve arithmetic — and ONLY the curve arithmetic — differs by platform. nanodart signs
  // through a TweetNaCl port built on Uint64List, which dart2js cannot compile 64-bit ints for, so in
  // a browser every derivation and signature throws. Web therefore goes through the BigInt
  // implementation in crypto/ed25519_blake2b.dart, which is checked byte-for-byte against nanodart
  // (test/ed25519_blake2b_test.dart) and against the node's Python verifier (test/crosscheck_nanopy.sh).
  // Android is deliberately left on nanodart: it is what every existing install has always signed
  // with, and this change must not be able to touch it.
  static Uint8List _b(String hex) => NanoHelpers.hexToBytes(hex);
  static String _h(Uint8List b) => NanoHelpers.byteToHex(b).toLowerCase();

  /// Sign a hex-encoded payload (a 32-byte block hash, or a canonical message already hex-encoded).
  String _signHex(String payloadHex) => _kIsWeb
      ? _h(webed.signDetached(_b(payloadHex), _b(priv), publicKey: _b(pub)))
      : NanoSignatures.signBlock(payloadHex, priv).toLowerCase();

  NanoWallet(this.seed) {
    priv = NanoKeys.seedToPrivate(seed, 0);   // Blake2b only (pointycastle Register64) — web-safe
    pub = _kIsWeb
        ? _h(webed.publicKeyFromSecret(_b(priv)))
        : NanoKeys.createPublicKey(priv).toLowerCase();
    account = NanoAccounts.createAccount(NanoAccountType.NANO, pub);
  }

  static String _hex(String s) =>
      utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Sign an arbitrary canonical message (head, comment, follow, poll, profile, dm-key).
  /// Returns {sig, pub} — matches the server-side signer byte-for-byte.
  Map<String, String> signMsg(String msg) => {'sig': _signHex(_hex(msg)), 'pub': pub};

  /// Sign a 32-byte Nano state-block hash (tips / send / representative change).
  String signBlockHash(String hash32Hex) => _signHex(hash32Hex);

  /// The 32-byte public key (hex) of any nano_ address — a send's `link`, and it validates the shape.
  String pubOf(String addr) => NanoAccounts.extractPublicKey(addr).toLowerCase();

  /// Build + sign a Nano STATE BLOCK entirely on-device (send / receive / open / change). The seed
  /// never leaves the phone: the block hash is computed and signed here; the node only adds delegated
  /// PoW and broadcasts it. `link` is a destination pubkey hex (send), a source block hash
  /// (receive/open), or 64 zeros (change). Returns the block ready for `process` (minus `work`).
  Map<String, dynamic> signStateBlock({
    required String previous,
    required String representative,
    required BigInt balance,
    required String link,
  }) {
    final hash = NanoBlocks.computeStateHash(
        NanoAccountType.NANO, account, previous, representative, balance, link);
    return {
      'type': 'state',
      'account': account,
      'previous': previous,
      'representative': representative,
      'balance': balance.toString(),
      'link': link,
      'signature': NanoSignatures.signBlock(hash, priv).toLowerCase(),
    };
  }

  /// A CHANNEL is a distinct publishing identity: its own keypair, deterministically derived from this
  /// seed so it's restorable on any device from the same seed, and followable like any account.
  /// channelSeed = blake2b256(seed || "xchat-channel:" + name). Returns a NanoWallet you sign with to
  /// publish/manage the channel.
  NanoWallet channelWallet(String name) {
    final cs = Blake2b.digest256([
      _bytesOfHex(seed),
      Uint8List.fromList(utf8.encode('xchat-channel:${name.trim().toLowerCase()}')),
    ]);
    return NanoWallet(_hexOfBytes(cs));
  }

  // ---- canonical message builders (must match the node's helpers exactly) ----
  // Unambiguous signing preimage — the exact mirror of the node's xc_common.sig_canon (issue #2):
  // a domain+type tag so a signature for one message type can't be replayed as another, and each
  // field length-prefixed by its UTF-8 byte count so a '|' inside free text can't shift boundaries
  // and collide two different tuples. Signed as UTF-8 bytes. HARD wire break: keep in lockstep with
  // the node; old-format signatures no longer verify.
  String sigCanon(String type, List<Object> fields) {
    var out = 'xchat/sig/v2/$type';
    for (final f in fields) {
      final s = f is String ? f : f.toString();
      out += '|${utf8.encode(s).length}:$s';
    }
    return out;
  }

  String headMsg(int seq, String cid, int expires) => sigCanon('head', [account, seq, cid, expires]);
  String postEventMsg(String handle, String kind, String text, int ts) =>
      sigCanon('post', [handle, kind, text, ts]);
  String commentMsg(String postId, int ts, String text, String parent) =>
      sigCanon('comment', [postId, account, ts, text, parent]);
  String followMsg(int ts, List<String> follows) {
    // dedupe + sort to match the node's canon (sorted(set(...))): a duplicate in the list would
    // otherwise make the app sign a preimage the node never reconstructs, and the write is rejected.
    final s = {...follows}.toList()..sort();
    return sigCanon('follow', [account, ts, s.join(',')]);
  }
  String pollMsg(String pollId, String option, int ts) => sigCanon('poll', [pollId, account, option, ts]);
  String profileMsg(int ts, String display, String bio, String avatar, String banner) =>
      sigCanon('profile', [account, ts, display, bio, avatar, banner]);
  String dmKeyMsg(int ts, String dmPub) => sigCanon('dmkey', [account, ts, dmPub]);
  // report/reshare are ALSO verified by the separately-deployed relay, which is why they stayed on
  // the legacy '|'-joined preimage after everything else moved (issue #7). Relays and the node now
  // accept BOTH preimages, so signing v2 here is safe: a relay that has been redeployed reads it as
  // v2, and one that has not still verifies nothing from this build until it updates.
  String reportMsg(String postId, int ts) => sigCanon('report', [account, postId, ts]);
  String deleteMsg(String postId, int ts) => sigCanon('delete', [account, postId, ts]);
  String reshareMsg(String postId, int ts) => sigCanon('reshare', [account, postId, ts]);

  // ---- encrypted DMs (on-device): a SEPARATE X25519 keypair derived from the seed, sealing with
  // NaCl crypto_box (pinenacl) — byte-compatible with the node's PyNaCl. The relays only ever see
  // ciphertext; decryption happens here, never on a server. ----
  static Uint8List _bytesOfHex(String s) =>
      Uint8List.fromList([for (int i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  static String _hexOfBytes(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  // X25519 secret = blake2b256(seed || "xchat-dm") — matches the node's derivation exactly.
  pnacl.PrivateKey get _dmKey {
    final dmSeed = Blake2b.digest256([_bytesOfHex(seed), Uint8List.fromList(utf8.encode('xchat-dm'))]);
    return pnacl.PrivateKey(Uint8List.fromList(dmSeed));
  }

  /// This device's DM public key (published in a signed record so peers can encrypt to us).
  String get dmPub => _hexOfBytes(_dmKey.publicKey);

  // A Box's shared secret is an X25519 scalar multiplication over (our key, their key), and it is
  // CONSTANT for the life of a conversation. Every seal/open built a fresh one, so a poll over 32
  // messages did 32 scalar multiplications — every 5 seconds in an open thread, plus again every 12s
  // for the home-screen badge, with the results discarded each time.
  //
  // Safe to cache because it is keyed BY PEER and skips no verification: opening with the wrong
  // peer's Box still fails the Poly1305 MAC and returns null. That distinction matters — caching the
  // decrypted PLAINTEXT in here instead, keyed by ciphertext alone, broke "a DM opens for its
  // recipient and nobody else" by handing the message to any caller. Plaintext caching belongs in the
  // layer that already knows which peer a ciphertext came from, not in the primitive.
  //
  // INSTANCE field, not static. A static map is keyed by the PEER only, so it silently hands one
  // wallet the Box built from a DIFFERENT wallet's private key — the second NanoWallet in a process
  // would decrypt with the first one's identity. wallet_test.dart caught it on the first run, same as
  // it caught the plaintext-cache attempt. Per instance, the key is unambiguous.
  final Map<String, pnacl.Box> _boxes = {};
  pnacl.Box _boxFor(String peerPkHex) => _boxes.putIfAbsent(
      peerPkHex,
      () => pnacl.Box(myPrivateKey: _dmKey, theirPublicKey: pnacl.PublicKey(_bytesOfHex(peerPkHex))));

  /// Seal a plaintext for a peer's DM public key → base64(nonce+ciphertext). The seed never leaves.
  String dmSeal(String peerPkHex, String text) {
    return base64.encode(_boxFor(peerPkHex).encrypt(Uint8List.fromList(utf8.encode(text))));
  }

  /// Open a base64(nonce+ciphertext) from/for a peer's DM public key → plaintext, or null if not ours.
  String? dmOpen(String peerPkHex, String b64) {
    try {
      return utf8.decode(_boxFor(peerPkHex).decrypt(pnacl.EncryptedMessage.fromList(base64.decode(b64))));
    } catch (_) {
      return null;
    }
  }

  // ---- DM attachments ----
  // Same box, raw bytes in and out. An attachment is stored as an ordinary blob on a relay, so if the
  // bytes went up as-is, "the relay only ever sees ciphertext" would hold for the words of a DM and be
  // false for its photos — the one part of a private message most worth reading. Sealing to RAW bytes
  // rather than base64 also matters: blob_put base64s whatever it is handed, so returning base64 here
  // would encode twice and put ~1.8x the bytes of the image on the wire.

  /// Seal raw bytes for a peer → raw (nonce+ciphertext) bytes, ready to store as a blob.
  Uint8List dmSealBytes(String peerPkHex, Uint8List bytes) {
    return Uint8List.fromList(_boxFor(peerPkHex).encrypt(bytes));
  }

  /// Open raw (nonce+ciphertext) bytes from/for a peer → the original bytes, or null if not ours.
  Uint8List? dmOpenBytes(String peerPkHex, Uint8List sealed) {
    try {
      return Uint8List.fromList(_boxFor(peerPkHex).decrypt(pnacl.EncryptedMessage.fromList(sealed)));
    } catch (_) {
      return null;
    }
  }
}
