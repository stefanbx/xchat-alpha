// The sealed control envelope: how reactions, read receipts and whatever follows travel between two
// clients without a relay learning that anything happened beyond "a message existed".
//
// This format is PERMANENT the moment it ships — a peer on an old build will keep sending v1 forever
// — so the wire shape is pinned here rather than left to whatever the implementation happens to emit.
//
// The property that matters most is SUPPRESS-UNKNOWN: a client meeting a type it has never heard of
// must still recognise the envelope and hide the message. Without it, shipping any new control type
// later would print machine text into every older client's conversation.
//
//   cd app && flutter test test/dm_ctl_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart' show DmCtl;
import 'package:xchat/wallet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('wire format', () {
    test('is one line: tag, type, json — pinned, not whatever we happen to emit', () {
      final line = DmCtl.encode('react', {'m': 'abc123', 'e': '👍'});
      expect(line, 'xchat:ctl/1 react {"m":"abc123","e":"👍"}');
      expect(line.contains('\n'), isFalse);
    });

    test('round-trips through parse', () {
      final p = DmCtl.parse(DmCtl.encode('react', {'m': 'abc123', 'e': '👍'}));
      expect(p, isNotNull);
      expect(p!.type, 'react');
      expect(p.data['m'], 'abc123');
      expect(p.data['e'], '👍');
    });
  });

  group('suppress-unknown', () {
    test('a type this build has never heard of is still recognised as control', () {
      // The whole point: a future client ships `edit`, and THIS build hides it rather than printing
      // `xchat:ctl/1 edit {...}` at the reader.
      final future = DmCtl.encode('edit', {'m': 'abc', 'text': 'fixed typo'});
      expect(DmCtl.isControl(future), isTrue);
      expect(DmCtl.parse(future)!.type, 'edit');
    });

    test('a recognised envelope with unreadable payload is still hidden', () {
      // Reporting null here would fall back to rendering the raw line — the exact failure the
      // envelope exists to prevent. Better to hide a message we cannot interpret.
      const broken = 'xchat:ctl/1 react {this is not json';
      expect(DmCtl.isControl(broken), isTrue);
      expect(DmCtl.parse(broken)!.data, isEmpty);
    });
  });

  group('ordinary messages are never mistaken for control', () {
    for (final text in <String>[
      'hello',
      'xchat:ctl/1',                                   // tag with nothing after it
      'xchat:ctl/1 react',                             // type but no payload
      'look at xchat:ctl/1 react {"m":"x"}',           // mentioned mid-sentence, not at the start
      'xchat:ctl/2 react {"m":"x"}',                   // a different envelope version
      'xchat:img:bafyfoo',                             // the attachment marker
      '> quoted line\nmy reply',                       // a quote
    ]) {
      test('plain text stays plain: ${jsonEncode(text)}', () {
        expect(DmCtl.isControl(text), isFalse);
      });
    }

    test('a multi-line message is never control, even if line one looks like it', () {
      // Control messages are whole-message by definition. Allowing a prefix would mean a reaction
      // could arrive stapled to someone's sentence, and hiding it would hide their words too.
      expect(DmCtl.isControl('xchat:ctl/1 react {"m":"a"}\nand also hello'), isFalse);
    });
  });

  group('message ids', () {
    test('both sides derive the SAME id from the ciphertext they each hold', () {
      // Neither side can invent an id and no relay may assign one, so it comes from the one thing
      // sender and recipient hold identically: the sealed bytes.
      final a = NanoWallet('c1' * 32), b = NanoWallet('d2' * 32);
      final ct = a.dmSeal(b.dmPub, 'meet at six');
      expect(DmCtl.keyOf(ct), DmCtl.keyOf(ct));
      expect(DmCtl.keyOf(ct).length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(DmCtl.keyOf(ct)), isTrue);
    });

    test('different messages get different ids', () {
      final a = NanoWallet('c1' * 32), b = NanoWallet('d2' * 32);
      final one = a.dmSeal(b.dmPub, 'first');
      final two = a.dmSeal(b.dmPub, 'second');
      expect(DmCtl.keyOf(one), isNot(DmCtl.keyOf(two)));
    });

    test('the same text sealed twice gets different ids — the nonce differs', () {
      // Worth pinning: ids identify a MESSAGE, not a string. Two identical "ok"s are two messages
      // and a reaction to one must not land on the other.
      final a = NanoWallet('c1' * 32), b = NanoWallet('d2' * 32);
      expect(DmCtl.keyOf(a.dmSeal(b.dmPub, 'ok')),
          isNot(DmCtl.keyOf(a.dmSeal(b.dmPub, 'ok'))));
    });
  });
}
