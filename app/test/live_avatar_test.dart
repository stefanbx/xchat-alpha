// The code-drawn "live" avatars and the keyholder reservation of the "key" style.
//   cd app && flutter test test/live_avatar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart';

void main() {
  group('liveStyleFor — "key" is reserved to the keyholder', () {
    test('keyholder keeps the key', () {
      expect(liveStyleFor('key', kKeyholderAccount), 'key');
    });
    test('anyone else\'s "key" downgrades to orbit on render', () {
      expect(liveStyleFor('key', 'nano_3someoneelseaccountxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), 'orbit');
      expect(liveStyleFor('key', ''), 'orbit');
    });
    test('non-key styles are never touched, for anyone', () {
      for (final s in ['orbit', 'coin', 'node', 'blob', 'ghost', 'googly']) {
        expect(liveStyleFor(s, 'nano_whoever'), s);
        expect(liveStyleFor(s, kKeyholderAccount), s);
      }
    });
  });

  testWidgets('every live-avatar style renders without throwing', (t) async {
    for (final style in ['orbit', 'coin', 'node', 'blob', 'ghost', 'googly', 'key']) {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: LiveAvatar(style: style, radius: 24))),
      ));
      await t.pump(const Duration(milliseconds: 100));   // advance the animation controller a frame
      expect(find.byType(LiveAvatar), findsOneWidget,
          reason: 'style "$style" should build a LiveAvatar');
      expect(find.byType(CustomPaint), findsWidgets,
          reason: 'style "$style" should paint');
      expect(t.takeException(), isNull, reason: 'style "$style" must not throw while painting');
    }
  });

  testWidgets('an unknown style falls back and still paints (orbit)', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: LiveAvatar(style: 'nonexistent', radius: 20))),
    ));
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
