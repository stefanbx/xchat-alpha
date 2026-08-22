// On-device signing. The seed NEVER leaves the device: this class derives the Nano keypair and
// signs every event/block locally with nanodart (ed25519-blake2b), byte-compatible with the node's
// verifier. The node only relays already-signed payloads and reads the ledger — it holds no seed.
import 'dart:convert';
import 'dart:math' as math;
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
  /// Capability advertisement, signed SEPARATELY from the dm_pk binding so it is additive: an old
  /// verifier checks dm_pk with the unchanged `dmkey` preimage and ignores this, while a new sender
  /// verifies this to trust that the recipient can read a sealed-sender record. Signing it (rather than
  /// leaving a bare flag) is what stops a hostile node from silently stripping the flag to force a
  /// sender back to the cleartext-`from` format — the exact node we are hiding from.
  String dmKeyCapsMsg(int ts, String caps) => sigCanon('dmkeycaps', [account, ts, caps]);
  /// Proof that we own a mailbox, for reading it. Bound to a timestamp so a captured signature is a
  /// bearer token for minutes rather than forever.
  String dmInboxMsg(int ts) => sigCanon('dminbox', [account, ts]);
  // report/reshare are ALSO verified by the separately-deployed relay, which is why they stayed on
  // the legacy '|'-joined preimage after everything else moved (issue #7). Relays and the node now
  // accept BOTH preimages, so signing v2 here is safe: a relay that has been redeployed reads it as
  // v2, and one that has not still verifies nothing from this build until it updates.
  String reportMsg(String postId, int ts) => sigCanon('report', [account, postId, ts]);
  String deleteMsg(String postId, int ts) => sigCanon('delete', [account, postId, ts]);
  String editPostMsg(String postId, String text, int ts) => sigCanon('editpost', [account, postId, text, ts]);
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

  // ---- sealed sender (double seal) ----
  // A relay currently sees `from` on every DM, so anyone pulling a mailbox can read the whole social
  // graph. Sealed sender hides the sender: the record carries only an EPHEMERAL public key and
  // ciphertext, and the true identity moves INSIDE the sealed payload.
  //
  //   inner = box(text)          under OUR REAL dm key → the recipient, opened with our published
  //                              dm_pk; opening under that key is the proof of authorship (the MAC).
  //   outer = box({from, from_pk, inner}) under a THROWAWAY ephemeral key → the recipient. The relay
  //                              sees the ephemeral key, never ours, so it cannot tie the record to us.
  //
  // Both layers seal to the SAME recipient dm_pk with crypto we already have; only the outer key is
  // per-message and disposable. The recipient opens the outer with (their dm key × epk) — which is
  // exactly `dmOpen(epk, ct)` — then opens the inner with (their dm key × our REAL dm_pk), which it
  // must confirm is the sender's ledger-published key before trusting the `from` (done in the Api layer).
  static const String dmCaps = 's1';                   // what we advertise + what a sealed record declares

  /// Build a sealed-sender envelope for a peer's dm_pk. Returns {epk, ct} for a v2 DM record.
  Map<String, String> dmSealSealed(String peerPkHex, String text) {
    final inner = dmSeal(peerPkHex, text);             // authenticated by our real dm key (authorship)
    final payload = jsonEncode({'f': account, 'k': dmPub, 'i': inner});
    final eph = pnacl.PrivateKey.generate();           // throwaway: the relay only ever sees eph.public
    final outer = pnacl.Box(myPrivateKey: eph, theirPublicKey: pnacl.PublicKey(_bytesOfHex(peerPkHex)));
    return {
      'epk': _hexOfBytes(eph.publicKey),
      'ct': base64.encode(outer.encrypt(Uint8List.fromList(utf8.encode(payload)))),
    };
  }

  /// A sealed-sender copy of an OUTGOING message, addressed to OURSELF. A normal v2 record hides `from`
  /// and is addressed to the peer, so it never appears in our own mailbox — which means a fresh device
  /// (seed restore, second phone) can recover messages we RECEIVED but not ones we SENT. This mirror,
  /// addressed to `to == account`, comes back in our own read, so our sent half syncs too. It carries
  /// the real recipient in `p`/`pk` so the decode stores it as outgoing to that peer, and the inner is
  /// sealed to our OWN dm key so any of our devices can open it. Authorship is still the MAC: only the
  /// holder of our dm key can produce an inner that opens under it, so a forged self-copy cannot open.
  Map<String, String> dmSealSealedSelf(String peerAccount, String peerPkHex, String text) {
    final inner = dmSeal(dmPub, text);                 // sealed to OURSELF — openable on any of our devices
    final payload = jsonEncode({'f': account, 'k': dmPub, 'i': inner, 'p': peerAccount, 'pk': peerPkHex});
    final eph = pnacl.PrivateKey.generate();
    final outer = pnacl.Box(myPrivateKey: eph, theirPublicKey: pnacl.PublicKey(_bytesOfHex(dmPub)));
    return {
      'epk': _hexOfBytes(eph.publicKey),
      'ct': base64.encode(outer.encrypt(Uint8List.fromList(utf8.encode(payload)))),
    };
  }

  /// Open a sealed-sender envelope with our own dm key. Returns the decoded payload
  /// {f: from, k: from_pk_claimed, i: inner_ct}, or null if the outer seal is not addressed to us.
  /// The caller MUST verify `k` against the sender's ledger dm_pk, then open `i` with dmOpen(realPk, i).
  Map<String, dynamic>? dmOpenSealedOuter(String epkHex, String ct) {
    final plain = dmOpen(epkHex, ct);                  // outer: our dm key × the ephemeral key
    if (plain == null) return null;
    try {
      final o = jsonDecode(plain);
      return o is Map<String, dynamic> ? o : null;
    } catch (_) {
      return null;
    }
  }

  // ---- blind mailbox read (breaks IP<->account correlation) ----
  // A mailbox read names the account that owns it, so whoever serves it learns "this IP reads that
  // account's DMs". Sealed sender hid the SENDER from the relay, but not this: the recipient must still
  // name its own mailbox. The fix is a one-hop onion. The client seals the read request to a chosen
  // relay's key and hands the blob to its node, which blind-forwards it. The node sees the client IP
  // but not the account (it is inside the seal); the relay sees the account but only the node's IP. No
  // single operator holds the pair — provided the client's node and that relay are run by different
  // people. The reply comes back sealed to the SAME ephemeral key, so the node cannot read it either.
  // See docs/ANONYMITY.md §4 and xc_relayd's /dm_sealed_read.

  /// Verify a relay's signed read-key record against the account we discovered for that relay OFF THE
  /// LEDGER, and return the read_pk to seal to (or null). Binding read_pk to the ledger identity is
  /// what stops a MITM node from substituting its OWN key to unwrap the account: a swapped key carries
  /// no signature from the relay's account, so this returns null and the caller falls back to a normal
  /// read. This is the first on-device signature check in the app — until now every signature was
  /// verified server-side, but the whole point here is NOT to have to trust the server.
  String? relayReadPk(Map<String, dynamic> rec, String ledgerAccount) {
    try {
      final acct = '${rec['account']}', pub = '${rec['pub']}', readPk = '${rec['read_pk']}';
      final sig = '${rec['sig']}';
      if (acct.isEmpty || acct != ledgerAccount) return null;     // must be the relay's ledger identity
      if (readPk.length != 64) return null;
      if (NanoAccounts.createAccount(NanoAccountType.NANO, pub) != acct) return null;  // pub binds to acct
      // ts is signed as a STRING on the relay (str(READ_TS)); '${rec['ts']}' reproduces it exactly.
      final msg = sigCanon('relaykey', [acct, readPk, '${rec['ts']}']);
      return verifySig(pub, msg, sig) ? readPk : null;
    } catch (_) {
      return null;
    }
  }

  /// Ed25519-Blake2b verify of a canonical message, mirroring signMsg. Signing signs the raw UTF-8
  /// bytes of the message (signMsg → _signHex(_hex(msg)) is exactly a signature over utf8(msg)), so
  /// verification is over those same bytes.
  ///
  /// Uses the local BigInt backend on EVERY platform, not the signing split. nanodart signs correctly
  /// but its TweetNaCl VERIFY path is broken for Nano's blake2b (cryptoHashOff takes the message length
  /// as the digest size), so a valid signature fails there — the app never noticed because until now it
  /// only ever signed. The BigInt verifyDetached is the same code the web build signs and verifies with,
  /// exercised by test/ed25519_blake2b_test.dart. Verification runs rarely (a relay key per read
  /// session), so the BigInt path's cost does not matter.
  static bool verifySig(String pubHex, String msg, String sigHex) {
    try {
      return webed.verifyDetached(
          Uint8List.fromList(utf8.encode(msg)), _bytesOfHex(sigHex), _bytesOfHex(pubHex));
    } catch (_) {
      return false;
    }
  }

  /// Seal a mailbox-read request to a relay's verified read key. `request` is {account, ts, sig, pub,
  /// since} — the same ownership proof the cleartext read carries, now sealed so the forwarding node
  /// never sees it. Returns a handle with the wire fields {epk, ct} and the box that opens the reply.
  BlindRead sealMailboxRead(String relayReadPkHex, Map<String, dynamic> request) {
    final eph = pnacl.PrivateKey.generate();                      // throwaway; the node sees only eph.public
    final box = pnacl.Box(
        myPrivateKey: eph, theirPublicKey: pnacl.PublicKey(_bytesOfHex(relayReadPkHex)));
    final ct = base64.encode(box.encrypt(Uint8List.fromList(utf8.encode(jsonEncode(request)))));
    return BlindRead(_hexOfBytes(eph.publicKey), ct, box);
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

  // ---- GROUP messages ----
  //
  // A group message is sealed ONCE under a fresh random key and stored as a single blob; that key is
  // then delivered to each member inside an ORDINARY 1:1 DM. So a photo sent to thirty people is one
  // photo on the relays plus thirty envelopes of a few hundred bytes.
  //
  // Delivering the key this way rather than as a wrap map attached to a shared record is what makes
  // the whole feature small: the per-member envelope IS the existing DM path, so groups inherit
  // delivery, push, the encrypted on-device store, ordering, attachments and the control envelope
  // without any of them learning that groups exist.
  //
  // IT IS ALSO WHAT MAKES IT SOUND, and that is the part worth spelling out. An earlier design put
  // the content key in a wrap map beside a shared ciphertext. Every member necessarily learns that
  // key — so any of them could keep the wraps they cannot forge, swap the ciphertext for something
  // else sealed under the same key, and have every recipient decrypt an attacker's words under the
  // real sender's name. Fixing that needs a signature over the ciphertext. Here the key and the
  // content id travel INSIDE a crypto_box from sender to member, which nobody else can produce, so
  // authorship is settled by the same MAC that already protects a 1:1 DM. No extra signature, and
  // one less thing to get wrong. See app/test/group_crypto_test.dart.
  static final math.Random _rng = math.Random.secure();

  /// Seal group content under a fresh key. Returns the sealed bytes and the key as hex, for the
  /// caller to deliver to each member privately.
  ({Uint8List ct, String key}) groupContentSeal(Uint8List bytes) {
    final k = Uint8List.fromList(List<int>.generate(32, (_) => _rng.nextInt(256)));
    return (ct: Uint8List.fromList(pnacl.SecretBox(k).encrypt(bytes)), key: _hexOfBytes(k));
  }

  /// Open group content given the key from our own envelope. Null rather than throwing: a corrupt
  /// blob must not break a poll.
  Uint8List? groupContentOpen(String keyHex, Uint8List ct) {
    try {
      return Uint8List.fromList(
          pnacl.SecretBox(_bytesOfHex(keyHex)).decrypt(pnacl.EncryptedMessage.fromList(ct)));
    } catch (_) {
      return null;
    }
  }

  /// Text convenience over the same two calls.
  ({String ct, String key}) groupTextSeal(String text) {
    final s = groupContentSeal(Uint8List.fromList(utf8.encode(text)));
    return (ct: base64.encode(s.ct), key: s.key);
  }

  String? groupTextOpen(String keyHex, String ctB64) {
    try {
      final b = groupContentOpen(keyHex, base64.decode(ctB64));
      return b == null ? null : utf8.decode(b);
    } catch (_) {
      return null;
    }
  }

  /// A group's id: derived, so anyone can recompute it and nobody can claim someone else's.
  static String groupId(String creator, String name, int createdTs) => _hexOfBytes(Blake2b.digest256([
        Uint8List.fromList(utf8.encode('xchat-group:$creator:${name.trim()}:$createdTs')),
      ])).substring(0, 32);
}

/// A blind mailbox read in flight: the wire fields to send through the node, plus the box (kept
/// on-device, never transmitted) that opens the relay's sealed reply. crypto_box is symmetric in the
/// shared secret, so the very same (ephemeral secret × relay read key) box that sealed the request
/// opens the reply — no second key exchange, and the node holds neither half.
class BlindRead {
  final String epk; // ephemeral public key (hex) — travels to the relay so it can derive the shared box
  final String ct;  // the sealed request (base64): {account, ts, sig, pub, since}, which the node cannot read
  final pnacl.Box _box;
  BlindRead(this.epk, this.ct, this._box);

  /// Open the relay's sealed reply (base64) → decoded JSON, or null if it is not for us / is corrupt.
  Map<String, dynamic>? openReply(String replyCtB64) {
    try {
      final p = utf8.decode(_box.decrypt(pnacl.EncryptedMessage.fromList(base64.decode(replyCtB64))));
      final o = jsonDecode(p);
      return o is Map<String, dynamic> ? o : null;
    } catch (_) {
      return null;
    }
  }
}
