// The funding-privacy warning: the single highest-value anonymity feature, because it prevents the
// mistake that undoes pseudonymity rather than mitigating it after the fact.
//
// An ӾChat identity is a Nano account, and the ledger is public and permanent. The one action that
// ties that account to a real name is FUNDING it from a KYC exchange. So the app says so, twice, at
// the two moments it matters: once at wallet creation (setting the model before any funds arrive) and
// again on the receive sheet every time an address is shown (the actual funding decision point). See
// docs/ANONYMITY.md §1 "Identity is money".
//
// This test does two things:
//   1. Renders the REAL onboarding backup step at phone size and asserts the ledger note is shown and
//      the screen does not overflow — a Column with a Spacer is exactly the layout that silently
//      overflows when a line is added, and an overflow in onboarding is the first thing a new user sees.
//   2. Guards the warning COPY in the source, so the note and its full explanation cannot be quietly
//      deleted or watered down to the point of not naming the actual risk (a KYC exchange, a real name).
//
//   cd app && flutter test test/funding_warning_test.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the onboarding backup step shows the public-ledger note and does not overflow',
      (tester) async {
    // A real phone is tall; the default 800x600 test surface is not, and a Column+Spacer would report
    // a false overflow there. Size the surface like a phone so the check reflects a real device.
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(home: OnboardingScreen(onDone: (_) async {})));
    await tester.pumpAndSettle();

    // Advance from the welcome step to the backup step (this generates a seed and shows the backup UI).
    await tester.tap(find.text('Create a new wallet'));
    await tester.pumpAndSettle();

    // The backup step is up (its heading proves it), and our ledger note rides along with it.
    expect(find.text('Back up your recovery seed'), findsOneWidget);
    expect(find.textContaining('public on the Nano ledger'), findsOneWidget,
        reason: 'the funding-privacy note must appear at wallet creation');

    // The layout must not overflow — RenderFlex overflow throws in test mode and takeException catches it.
    expect(tester.takeException(), isNull,
        reason: 'adding the note must not push the backup Column past the screen');
  });

  test('the funding-privacy copy names the real risk and cannot be silently gutted', () {
    // Locate lib/main.dart relative to the test working directory (app/).
    final src = File('lib/main.dart').readAsStringSync();

    // The short note on the receive sheet — shown at every funding, the decision point.
    expect(src.contains('Public ledger: funding this account from a KYC exchange can link it to your real name.'),
        isTrue, reason: 'the receive-sheet funding note is missing or reworded away from the real risk');

    // The full explanation sheet must still say the three things that make it honest and actionable:
    // the ledger is public/permanent, KYC-exchange funding ties it to a legal name, and the remedy.
    final dialog = _between(src, 'void _showFundingPrivacy()', 'void _showBackupSheet()');
    for (final needle in [
      'public and permanent',       // the ledger is forever
      'KYC exchange',               // the specific funding mistake
      'legal name',                 // what it links to
      'stay pseudonymous',          // the honest framing + remedy
      'the money is not',           // encryption covers posts/DMs, not the money
    ]) {
      expect(dialog.contains(needle), isTrue,
          reason: 'the funding-privacy explanation no longer says "$needle"');
    }
  });
}

/// The slice of source between two markers, so the copy assertions read the dialog and not the
/// whole file (a stray match elsewhere would otherwise hide a gutted dialog).
String _between(String src, String start, String end) {
  final a = src.indexOf(start);
  final b = src.indexOf(end, a + start.length);
  return (a >= 0 && b > a) ? src.substring(a, b) : '';
}
