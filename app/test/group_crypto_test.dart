// Group messages: content sealed once under a fresh key, that key delivered per member inside an
// ordinary 1:1 DM.
//
// WHY NOT A WRAP MAP. The obvious design attaches one shared ciphertext to a map of "content key,
// wrapped to each member". It is more compact, and it is unsound on its own: every member has to
// learn the content key to read anything, and once they have it they can seal different words under
// the same key while copying the sender's wraps verbatim — wraps they cannot forge, but can paste.
// Every recipient then opens a genuine wrap from the real sender and reads the attacker's message
// under their name. Closing that needs a separate signature over the ciphertext.
//
// Putting the key inside a crypto_box from sender to member removes the problem instead of patching
// it: nobody but the sender can produce that envelope, so the MAC that already protects a 1:1 DM
// settles authorship here too. The first two tests below are the ones that pin this — the borrowed
// key opens nothing, because no two messages share one.
//
//   cd app && flutter test test/group_crypto_test.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart' show DmCtl, GroupChat, GroupMsg;
import 'package:xchat/wallet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final alice = NanoWallet('a1' * 32);
  final bob = NanoWallet('b2' * 32);
  final carol = NanoWallet('c3' * 32);
  final mallory = NanoWallet('d4' * 32);

  group('content sealing', () {
    test('round-trips for anyone holding the key', () {
      final s = alice.groupTextSeal('dinner at eight');
      expect(alice.groupTextOpen(s.key, s.ct), 'dinner at eight');
      expect(bob.groupTextOpen(s.key, s.ct), 'dinner at eight');
    });

    test('the key is the ONLY thing that opens it', () {
      final s = alice.groupTextSeal('members only');
      final other = alice.groupTextSeal('x');
      expect(bob.groupTextOpen(other.key, s.ct), isNull);
      expect(bob.groupTextOpen('00' * 32, s.ct), isNull);
    });

    test('the ciphertext reveals nothing on its own', () {
      final s = alice.groupTextSeal('the numbers are 4 8 15 16 23 42');
      expect(s.ct.contains('numbers'), isFalse);
      expect(utf8.decode(base64.decode(s.ct), allowMalformed: true).contains('numbers'), isFalse);
    });

    test('every message gets a FRESH key, so a key is never a group secret', () {
      // The heart of it. If two messages shared a key, a member holding one could re-seal the other
      // and the borrowed-key attack would be back.
      final a = alice.groupTextSeal('first');
      final b = alice.groupTextSeal('second');
      expect(a.key, isNot(b.key));
      expect(alice.groupTextOpen(a.key, b.ct), isNull);
      expect(alice.groupTextOpen(b.key, a.ct), isNull);
    });

    test('the same text sealed twice differs', () {
      expect(alice.groupTextSeal('ok').ct, isNot(alice.groupTextSeal('ok').ct));
    });

    test('a key is 32 bytes of hex', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(alice.groupTextSeal('x').key), isTrue);
    });
  });

  group('authorship comes from the envelope the key travels in', () {
    test('only the sender can produce the DM carrying the key', () {
      // The key + cid ride inside an ordinary crypto_box. Mallory can compose whatever she likes,
      // but she cannot make it open as alice — the same property a 1:1 DM already relies on.
      final s = alice.groupTextSeal('pay the invoice tomorrow');
      final env = GroupMsg(gid: 'g1', name: 'friends', cid: 'bafy1', key: s.key,
              members: [alice.account, bob.account, carol.account]).encode();
      final sealed = alice.dmSeal(bob.dmPub, env);

      expect(bob.dmOpen(alice.dmPub, sealed), env);           // genuinely from alice
      expect(bob.dmOpen(mallory.dmPub, sealed), isNull);      // not from mallory, and it shows

      final forged = mallory.dmSeal(bob.dmPub, env);
      expect(bob.dmOpen(alice.dmPub, forged), isNull,
          reason: 'a forged envelope must not open as alice');
    });

    test("a member cannot re-use another message's key to impersonate", () {
      // Carol legitimately holds the key to the message she received. That key opens exactly that
      // message and nothing else, and she still cannot produce an envelope from alice.
      final real = alice.groupTextSeal('pay the invoice tomorrow');
      final carolForgery = carol.groupTextSeal('pay the invoice to carol instead');
      expect(bob.groupTextOpen(real.key, carolForgery.ct), isNull,
          reason: "carol's content does not open under alice's key — no shared key, no swap");
      final env = GroupMsg(gid: 'g1', name: 'f', cid: 'bafy2', key: carolForgery.key,
              members: [alice.account, bob.account]).encode();
      expect(bob.dmOpen(alice.dmPub, carol.dmSeal(bob.dmPub, env)), isNull,
          reason: 'and she cannot deliver her key as alice');
    });

    test('a non-member never receives an envelope at all', () {
      // Membership is enforced by who is sent the key. Removal is not retroactive — it means the
      // next message's key does not go to them — and that is what "remove from group" means here.
      final s = alice.groupTextSeal('after carol left');
      final forBob = alice.dmSeal(bob.dmPub, GroupMsg(
          gid: 'g1', name: 'f', cid: 'bafy3', key: s.key,
          members: [alice.account, bob.account]).encode());
      expect(carol.dmOpen(alice.dmPub, forBob), isNull);
    });
  });

  group('the envelope on the wire', () {
    test('is one line, tagged, and round-trips', () {
      final m = GroupMsg(gid: 'abc', name: 'friends', cid: 'bafy', key: 'ff' * 32,
          members: ['nano_1a', 'nano_1b']);
      final line = m.encode();
      expect(line.startsWith('xchat:grp/1 '), isTrue);
      expect(line.contains('\n'), isFalse);
      final p = GroupMsg.parse(line)!;
      expect(p.gid, 'abc');
      expect(p.name, 'friends');
      expect(p.cid, 'bafy');
      expect(p.key, 'ff' * 32);
      expect(p.members, ['nano_1a', 'nano_1b']);
    });

    test('ordinary text is never mistaken for a group message', () {
      for (final t in <String>[
        'hello',
        'xchat:grp/1',                                  // tag with nothing after it
        'look at xchat:grp/1 {"g":"x"}',                // mid-sentence, not at the start
        'xchat:grp/2 {"g":"x"}',                        // a different envelope version
        'xchat:ctl/1 read {"u":1}',                     // the control envelope
        'xchat:img:bafyfoo',                            // the attachment marker
        'xchat:grp/1 {"g":"a"}\nand hello',             // multi-line
      ]) {
        expect(GroupMsg.isGroup(t), isFalse, reason: 'misread as a group message: $t');
      }
    });

    test('an envelope missing what it needs is refused, not half-acted-on', () {
      // Without a gid there is no group to file it under; without a cid or key there is nothing to
      // show. Returning a partial object would put an empty bubble in a thread.
      expect(GroupMsg.parse('xchat:grp/1 {"n":"friends"}'), isNull);
      expect(GroupMsg.parse('xchat:grp/1 {"g":"a","c":"bafy"}'), isNull);
      expect(GroupMsg.parse('xchat:grp/1 {"g":"a","k":"ff"}'), isNull);
      expect(GroupMsg.parse('xchat:grp/1 not json'), isNull);
    });

    test('a missing member list parses as empty rather than throwing', () {
      final p = GroupMsg.parse('xchat:grp/1 {"g":"a","c":"b","k":"c"}');
      expect(p, isNotNull);
      expect(p!.members, isEmpty);
    });

    test('an envelope survives a full seal/open round trip', () {
      final m = GroupMsg(gid: 'g', name: 'the group', cid: 'bafy', key: 'ab' * 32,
          members: [alice.account, bob.account]);
      final opened = bob.dmOpen(alice.dmPub, alice.dmSeal(bob.dmPub, m.encode()));
      expect(GroupMsg.parse(opened!)!.gid, 'g');
    });
  });

  group('group ids', () {
    test('are derived, so anyone can recompute one', () {
      expect(NanoWallet.groupId(alice.account, 'friends', 100),
          NanoWallet.groupId(alice.account, 'friends', 100));
    });

    test('differ by creator, name and creation time', () {
      final base = NanoWallet.groupId(alice.account, 'friends', 100);
      expect(base, isNot(NanoWallet.groupId(bob.account, 'friends', 100)));
      expect(base, isNot(NanoWallet.groupId(alice.account, 'family', 100)));
      expect(base, isNot(NanoWallet.groupId(alice.account, 'friends', 101)));
    });

    test('are a fixed-length hex string', () {
      final g = NanoWallet.groupId(alice.account, 'x', 1);
      expect(g.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(g), isTrue);
    });
  });

  group('attachments', () {
    test('bytes round-trip under the key, and not without it', () {
      final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 256));
      final s = alice.groupContentSeal(bytes);
      expect(alice.groupContentOpen(s.key, s.ct), bytes);
      expect(alice.groupContentOpen('11' * 32, s.ct), isNull);
    });

    test('the sealed blob is raw bytes, not base64', () {
      // blob_put base64s whatever it is handed, so returning base64 here would encode twice and put
      // ~1.8x the bytes of a photo on the wire — the trap dmSealBytes already exists to avoid.
      final s = alice.groupContentSeal(Uint8List.fromList(List<int>.filled(1000, 7)));
      expect(s.ct.length, lessThan(1100));
    });

    test('ONE copy of the content, however many members', () {
      // The whole reason the key is delivered separately: a photo to thirty people is one photo on
      // the relays plus thirty small envelopes, not thirty photos.
      final s = alice.groupContentSeal(Uint8List.fromList(List<int>.filled(50000, 3)));
      final env = GroupMsg(gid: 'g', name: 'n', cid: 'bafy', key: s.key,
          members: List.generate(30, (i) => 'nano_1member$i')).encode();
      expect(s.ct.length, greaterThan(50000));
      expect(env.length, lessThan(1200), reason: 'the per-member envelope must stay small');
    });
  });

  _extractTests();

  group('bad input is refused, not thrown', () {
    test('a corrupt ciphertext yields null', () {
      expect(alice.groupTextOpen('ff' * 32, 'not-base64-!!'), isNull);
    });
    test('a corrupt key yields null', () {
      final s = alice.groupTextSeal('x');
      expect(alice.groupTextOpen('nothex', s.ct), isNull);
      expect(alice.groupTextOpen('ff', s.ct), isNull);
    });
  });
}

// ---- building the group list out of the DMs that already arrived --------------------------------

void _extractTests() {
  Map<String, dynamic> env(String gid, String name, String cid, List<String> members,
          {int ts = 100, bool outgoing = false}) =>
      {
        'text': GroupMsg(gid: gid, name: name, cid: cid, key: 'ff' * 32, members: members).encode(),
        'ts': ts,
        'outgoing': outgoing,
      };

  group('GroupChat.extract', () {
    test('a group appears from its messages alone — nothing else is stored', () {
      final g = GroupChat.extract([
        {'peer': 'nano_1alice', 'messages': [env('g1', 'friends', 'c1', ['nano_1alice', 'nano_1me'])]}
      ]);
      expect(g.length, 1);
      expect(g.first.gid, 'g1');
      expect(g.first.name, 'friends');
      expect(g.first.members, ['nano_1alice', 'nano_1me']);
      expect(g.first.msgs.length, 1);
    });

    test('THE SAME message arriving through several conversations counts once', () {
      // This is the one that bites. A message we SENT is delivered once per recipient, so our own
      // copy of it turns up in every one of those conversations. Without deduping by cid, a group of
      // five shows every outgoing message five times.
      final e = env('g1', 'f', 'samecid', ['a', 'b', 'c'], outgoing: true);
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [e]},
        {'peer': 'nano_1b', 'messages': [e]},
        {'peer': 'nano_1c', 'messages': [e]},
      ]);
      expect(g.first.msgs.length, 1);
    });

    test('different messages are kept, and ordered oldest first', () {
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [
          env('g1', 'f', 'c2', ['a'], ts: 200),
          env('g1', 'f', 'c1', ['a'], ts: 100),
          env('g1', 'f', 'c3', ['a'], ts: 300),
        ]}
      ]);
      expect(g.first.msgs.map((m) => m.cid).toList(), ['c1', 'c2', 'c3']);
    });

    test('the NEWEST envelope decides the name and the membership', () {
      // Last-writer-wins, stated in one place and tested in another. An older envelope must not be
      // able to resurrect a member who was removed since.
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [
          env('g1', 'old name', 'c1', ['a', 'b', 'c'], ts: 100),
          env('g1', 'new name', 'c2', ['a', 'b'], ts: 200),
        ]}
      ]);
      expect(g.first.name, 'new name');
      expect(g.first.members, ['a', 'b']);
    });

    test('an older envelope arriving LATE does not overwrite a newer one', () {
      // Relays gossip, so order of arrival is not order of sending. Deciding by ts rather than by
      // position is what makes that harmless.
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [
          env('g1', 'new name', 'c2', ['a', 'b'], ts: 200),
          env('g1', 'old name', 'c1', ['a', 'b', 'c'], ts: 100),
        ]}
      ]);
      expect(g.first.name, 'new name');
      expect(g.first.members, ['a', 'b']);
    });

    test('several groups are separated, newest first', () {
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [
          env('gOld', 'old', 'c1', ['a'], ts: 100),
          env('gNew', 'new', 'c2', ['a'], ts: 900),
        ]}
      ]);
      expect(g.map((x) => x.gid).toList(), ['gNew', 'gOld']);
    });

    test('ordinary DMs contribute nothing', () {
      final g = GroupChat.extract([
        {'peer': 'nano_1a', 'messages': [
          {'text': 'hello there', 'ts': 1, 'outgoing': false},
          {'text': DmCtl.encode('read', {'u': 1}), 'ts': 2, 'outgoing': true},
          {'text': 'xchat:img:bafyfoo', 'ts': 3, 'outgoing': false},
        ]}
      ]);
      expect(g, isEmpty);
    });

    test('an outgoing message is attributed to us, an incoming one to its sender', () {
      final g = GroupChat.extract([
        {'peer': 'nano_1alice', 'messages': [
          env('g1', 'f', 'c1', ['a'], ts: 100, outgoing: true),
          env('g1', 'f', 'c2', ['a'], ts: 200),
        ]}
      ]);
      expect(g.first.msgs[0].from, '');                 // '' means us
      expect(g.first.msgs[1].from, 'nano_1alice');
    });

    test('an empty inbox yields no groups rather than throwing', () {
      expect(GroupChat.extract([]), isEmpty);
      expect(GroupChat.extract([{'peer': 'x'}]), isEmpty);
    });
  });
}
