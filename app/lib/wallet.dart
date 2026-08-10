// On-device signing. The seed NEVER leaves the device: this class derives the Nano keypair and
// signs every event/block locally with nanodart (ed25519-blake2b), byte-compatible with the node's
// verifier. The node only relays already-signed payloads and reads the ledger — it holds no seed.
import 'dart:convert';
import 'dart:typed_data';
import 'package:nanodart/nanodart.dart';
import 'package:pinenacl/x25519.dart' as pnacl;

class NanoWallet {
  final String seed; // 64 hex — held only here, only on this device
  late final String priv;
  late final String pub;      // 32-byte public key, hex
  late final String account;  // nano_ address

  NanoWallet(this.seed) {
    priv = NanoKeys.seedToPrivate(seed, 0);
    pub = NanoKeys.createPublicKey(priv).toLowerCase();
    account = NanoAccounts.createAccount(NanoAccountType.NANO, pub);
  }

  static String _hex(String s) =>
      utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Sign an arbitrary canonical message (head, comment, follow, poll, profile, dm-key).
  /// Returns {sig, pub} — matches the server-side signer byte-for-byte.
  Map<String, String> signMsg(String msg) =>
      {'sig': NanoSignatures.signBlock(_hex(msg), priv).toLowerCase(), 'pub': pub};

  /// Sign a 32-byte Nano state-block hash (tips / send / representative change).
  String signBlockHash(String hash32Hex) =>
      NanoSignatures.signBlock(hash32Hex, priv).toLowerCase();

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

  // ---- canonical message builders (must match the node's helpers exactly) ----
  String headMsg(int seq, String cid, int expires) => '$account|$seq|$cid|$expires';
  String postEventMsg(String handle, String kind, String text, int ts) => '$handle|$kind|$text|$ts';
  String commentMsg(String postId, int ts, String text, String parent) =>
      '$postId|$account|$ts|$text|$parent';
  String followMsg(int ts, List<String> follows) {
    final s = [...follows]..sort();
    return '$account|$ts|${s.join(',')}';
  }
  String pollMsg(String pollId, String option, int ts) => '$pollId|$account|$option|$ts';
  String profileMsg(int ts, String display, String bio, String avatar, String banner) =>
      '$account|$ts|$display|$bio|$avatar|$banner';
  String dmKeyMsg(int ts, String dmPub) => '$account|$ts|$dmPub';

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

  /// Seal a plaintext for a peer's DM public key → base64(nonce+ciphertext). The seed never leaves.
  String dmSeal(String peerPkHex, String text) {
    final box = pnacl.Box(myPrivateKey: _dmKey, theirPublicKey: pnacl.PublicKey(_bytesOfHex(peerPkHex)));
    return base64.encode(box.encrypt(Uint8List.fromList(utf8.encode(text))));
  }

  /// Open a base64(nonce+ciphertext) from/for a peer's DM public key → plaintext, or null if not ours.
  String? dmOpen(String peerPkHex, String b64) {
    try {
      final box = pnacl.Box(myPrivateKey: _dmKey, theirPublicKey: pnacl.PublicKey(_bytesOfHex(peerPkHex)));
      return utf8.decode(box.decrypt(pnacl.EncryptedMessage.fromList(base64.decode(b64))));
    } catch (_) {
      return null;
    }
  }
}
