// Blind mailbox read: the request that names our mailbox must be readable ONLY by the relay we chose
// (never the node that forwards it), and we must seal to a relay key ONLY after proving that key is
// signed by the relay's ledger account (so a MITM node cannot substitute its own key to unwrap us).
//
// This drives the REAL wallet crypto (pinenacl crypto_box + the on-device ed25519-blake2b verify the
// app ships) and pins the three properties the fix rests on:
//
//   1. Round trip — the relay opens the sealed request with (its read key × our ephemeral key), and we
//      open its reply under the same shared box. crypto_box is symmetric in the shared secret, so one
//      ephemeral key serves both directions and the forwarding node holds neither half.
//   2. Authenticated key — a read key verifies only when its signature binds it to the ledger account
//      we expected; a key swapped by a node fails, and a key checked against the wrong account fails.
//   3. No leak — the sealed request carries no cleartext account for the node to read.
//
//   cd app && flutter test test/blind_read_test.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart' as pnacl;
import 'package:xchat/wallet.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _bytes(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  final bob = NanoWallet('b2' * 32); // the reader whose IP<->account link we are breaking

  test('a blind read seals to the relay and the reply comes back under the same key', () {
    // Stand in for the relay's X25519 read keypair.
    final relayPriv = pnacl.PrivateKey.generate();
    final relayPk = _hex(relayPriv.publicKey.toList());

    final read = bob.sealMailboxRead(relayPk,
        {'account': bob.account, 'ts': 123, 'sig': 'proof', 'pub': bob.pub, 'since': 0});

    // The node only ever sees {epk, ct}. Neither carries the account in the clear.
    expect(read.ct.contains(bob.account), isFalse);
    expect(read.epk, isNot(equals(relayPk)));

    // The relay opens the request with (its read key × the ephemeral key).
    final box = pnacl.Box(myPrivateKey: relayPriv, theirPublicKey: pnacl.PublicKey(_bytes(read.epk)));
    final req = jsonDecode(utf8.decode(box.decrypt(pnacl.EncryptedMessage.fromList(base64.decode(read.ct)))));
    expect(req['account'], bob.account, reason: 'only the chosen relay can read who owns the mailbox');
    expect(req['sig'], 'proof');

    // The relay seals its reply under the SAME shared box; only bob can open it (not the node).
    final replyCt = base64.encode(box.encrypt(Uint8List.fromList(
        utf8.encode(jsonEncode({'account': bob.account, 'dms': [{'ts': 1, 'v': 2}]})))));
    final reply = read.openReply(replyCt);
    expect(reply, isNotNull);
    expect(reply!['account'], bob.account);
    expect((reply['dms'] as List).length, 1);
  });

  test('a relay read key verifies only under a signature from its ledger account', () {
    final relayId = NanoWallet('cc' * 32); // stands in for the relay's ledger identity
    final relayPriv = pnacl.PrivateKey.generate();
    final readPk = _hex(relayPriv.publicKey.toList());
    const ts = 1700000000;
    final sig = relayId.signMsg(relayId.sigCanon('relaykey', [relayId.account, readPk, '$ts']));
    final rec = {'account': relayId.account, 'pub': sig['pub'], 'read_pk': readPk, 'ts': ts, 'sig': sig['sig']};

    expect(bob.relayReadPk(rec, relayId.account), readPk,
        reason: 'a correctly signed key, checked against its ledger account, verifies');

    // MITM: a node swaps read_pk but cannot re-sign as the relay account.
    final swapped = {...rec, 'read_pk': '00${readPk.substring(2)}'};
    expect(bob.relayReadPk(swapped, relayId.account), isNull, reason: 'a swapped key fails the signature');

    // Right signature, WRONG expected account → rejected. This is what stops the node from pointing us
    // at a relay it controls: the account must be the one the ledger says owns the relay.
    expect(bob.relayReadPk(rec, bob.account), isNull, reason: 'the key must be bound to the expected account');
  });
}
