// Sealed sender: the relay must not learn who sent a DM, yet the recipient must still know — and be
// unable to be fooled about — who wrote it.
//
// The wire record hides `from`: it carries only a throwaway ephemeral public key and a double-sealed
// ciphertext. This test drives the REAL wallet crypto (pinenacl crypto_box, the same primitive the app
// ships) and pins the four properties the design rests on:
//
//   1. Round trip — the recipient opens the outer seal with (their dm key × the ephemeral key), reads
//      the sender identity from inside, and opens the inner seal under the sender's real dm key.
//   2. Authorship — the inner seal only opens under the sender's REAL dm key, so a valid open IS the
//      proof of who wrote it (the crypto_box MAC).
//   3. Eavesdropper — a third party (a relay, a stranger pulling the mailbox) cannot open the outer
//      seal at all; all it holds is an ephemeral key that reveals nothing about the sender.
//   4. Forgery — a sender who lies about their identity is caught: an inner seal made under the wrong
//      key does not open under the claimed key, so the impersonation fails the MAC.
//
//   cd app && flutter test test/sealed_sender_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/wallet.dart';

void main() {
  final alice = NanoWallet('a1' * 32);     // the sender
  final bob = NanoWallet('b2' * 32);       // the recipient
  final eve = NanoWallet('e3' * 32);       // a relay / eavesdropper who must learn nothing

  test('the recipient opens a sealed envelope and recovers the authenticated sender + message', () {
    final env = alice.dmSealSealed(bob.dmPub, 'dinner at eight?');
    expect(env['epk'], isNotNull);
    expect(env['ct'], isNotNull);
    // The ephemeral key is NOT alice's identity key — that is the whole point.
    expect(env['epk'], isNot(equals(alice.dmPub)));

    // 1. Outer: bob opens with his dm key × the ephemeral key.
    final outer = bob.dmOpenSealedOuter(env['epk']!, env['ct']!);
    expect(outer, isNotNull);
    expect(outer!['f'], alice.account, reason: 'the sender identity is carried inside the seal');
    expect(outer['k'], alice.dmPub, reason: 'and the dm key to authenticate them under');

    // 2. Inner: opening under alice\'s real dm key succeeds → that IS the authorship proof.
    final plain = bob.dmOpen('${outer['k']}', '${outer['i']}');
    expect(plain, 'dinner at eight?');
  });

  test('an eavesdropper (relay/stranger) cannot open the outer seal', () {
    final env = alice.dmSealSealed(bob.dmPub, 'a private plan');
    // Eve holds exactly what the relay stores: epk + ct. She is not the recipient.
    final outer = eve.dmOpenSealedOuter(env['epk']!, env['ct']!);
    expect(outer, isNull, reason: 'only the recipient dm key can open the outer seal');
    // And the record carries no plaintext sender field for her to read either.
    // (The whole envelope is opaque without bob\'s key.)
  });

  test('a forged sender is rejected: the inner seal will not open under the claimed identity', () {
    // Eve impersonates alice. She can put f=alice, k=alice.dmPub in the outer payload (it is just a
    // claim), but she cannot produce an inner seal that opens under ALICE's key — she lacks alice's dm
    // secret. The best she can do is seal the inner under her OWN key. dmInbox's authorship check is
    // exactly: open the inner under the claimed key; if it does not open, drop it. This pins that check.
    final innerUnderEve = eve.dmSeal(bob.dmPub, 'transfer the funds');   // really authored by eve

    // Opening under the CLAIMED author (alice) fails the MAC → the impersonation is caught and dropped.
    expect(bob.dmOpen(alice.dmPub, innerUnderEve), isNull,
        reason: 'the inner MAC binds the message to the real author, not to whoever is claimed');
    // Opening under eve's REAL key would succeed — the seal is valid, it is simply eve's, not alice's.
    expect(bob.dmOpen(eve.dmPub, innerUnderEve), 'transfer the funds');
  });

  test('a sealed send is mirrored to a self-copy only the SENDER can open, tagged with the real peer', () {
    // A normal sealed record is addressed to the peer and hides `from`, so it never comes back in the
    // SENDER's own mailbox — a fresh device (seed restore, second phone) could recover received messages
    // but not sent ones. The self-copy is addressed to alice's OWN dm key and carries the recipient, so
    // her sent half syncs too and renders as outgoing to bob.
    final self = alice.dmSealSealedSelf(bob.account, bob.dmPub, 'see you at noon');

    // Alice — on ANY device holding her seed — opens her own self-copy.
    final outer = alice.dmOpenSealedOuter(self['epk']!, self['ct']!);
    expect(outer, isNotNull);
    expect(outer!['f'], alice.account, reason: 'authorship is alice (the MAC proves only she made it)');
    expect(outer['p'], bob.account, reason: 'the real recipient — so the decode stores it as outgoing to bob');
    expect(outer['pk'], bob.dmPub);
    // The inner is sealed to alice HERSELF, so she opens it under her own dm key and recovers the text.
    expect(alice.dmOpen(alice.dmPub, '${outer['i']}'), 'see you at noon');

    // Bob — the named peer — CANNOT open the self-copy; it was addressed to alice, never to him.
    expect(bob.dmOpenSealedOuter(self['epk']!, self['ct']!), isNull,
        reason: 'the self-copy is sealed to alice, not bob — the relay/eavesdropper learns nothing');
    // And a forger cannot fabricate a self-copy that opens under alice's key (they lack her dm secret),
    // so authorship still holds: eve sealing an "inner" to alice does not open under alice's own key.
    final forgedInner = eve.dmSeal(alice.dmPub, 'spoofed sent message');
    expect(alice.dmOpen(alice.dmPub, forgedInner), isNull,
        reason: 'inner sealed by eve does not open under alice-to-alice — a forged self-copy is dropped');
  });
}
