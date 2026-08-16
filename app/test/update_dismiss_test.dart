// The update banner carries security fixes, so "dismiss" must not mean "never again".
//
// It used to store a bare version string and suppress that version forever: one tap on the × and the
// banner never returned. That is the wrong default for the one notification that can matter — a user
// postponing today is not asking to be kept in the dark. Dismissal now lasts a DAY.
//
// The boundary conditions are the whole point (same version vs different, inside vs outside the TTL,
// and the legacy values already sitting in people's prefs), so they get asserted rather than eyeballed.
//
//   cd app && flutter test test/update_dismiss_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/main.dart' show UpdateDismiss;

const _k = 'xchat_update_dismissed';
int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh install suppresses nothing', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await UpdateDismiss.suppressed('2.4.1'), isFalse);
  });

  test('dismissing hides that version now', () async {
    SharedPreferences.setMockInitialValues({});
    await UpdateDismiss.set('2.4.1');
    expect(await UpdateDismiss.suppressed('2.4.1'), isTrue);
  });

  test('a DIFFERENT version is always shown, even seconds after a dismissal', () async {
    SharedPreferences.setMockInitialValues({});
    await UpdateDismiss.set('2.4.1');
    // The case that matters: 2.4.2 ships an hour later with a fix. It must not inherit the silence.
    expect(await UpdateDismiss.suppressed('2.4.2'), isFalse);
  });

  test('the same version returns after 24h', () async {
    SharedPreferences.setMockInitialValues({'$_k': '2.4.1|${_now() - 24 * 3600 - 1}'});
    expect(await UpdateDismiss.suppressed('2.4.1'), isFalse);
  });

  test('...but stays hidden just inside 24h', () async {
    SharedPreferences.setMockInitialValues({'$_k': '2.4.1|${_now() - 24 * 3600 + 60}'});
    expect(await UpdateDismiss.suppressed('2.4.1'), isTrue);
  });

  test('a LEGACY bare value (dismissed under the old forever rule) is shown again', () async {
    // This is what is actually in the prefs of everyone who ever tapped ×. Reading it as
    // "dismissed at epoch 0" means expired, so they get told once more — which is the intent.
    SharedPreferences.setMockInitialValues({'$_k': '2.4.1'});
    expect(await UpdateDismiss.suppressed('2.4.1'), isFalse);
  });

  test('a clock that moved BACKWARDS does not hide the banner forever', () async {
    // A future timestamp (device clock corrected backwards, or a restored backup) would make `age`
    // negative. Suppressing on that would silence updates until the clock caught up.
    SharedPreferences.setMockInitialValues({'$_k': '2.4.1|${_now() + 90 * 24 * 3600}'});
    expect(await UpdateDismiss.suppressed('2.4.1'), isFalse);
  });

  test('garbage in prefs never suppresses', () async {
    SharedPreferences.setMockInitialValues({'$_k': '2.4.1|not-a-number'});
    expect(await UpdateDismiss.suppressed('2.4.1'), isFalse);
  });

  test('get() still reports the bare version, for callers that only want the name', () async {
    SharedPreferences.setMockInitialValues({});
    await UpdateDismiss.set('2.4.1');
    expect(await UpdateDismiss.get(), '2.4.1');
  });
}
