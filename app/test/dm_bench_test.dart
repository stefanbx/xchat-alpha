// Not a correctness test — a measurement, so the claim in docs/DM-PLAN.md ("time a poll with a
// 500-message history before and after") is checked rather than asserted.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/main.dart' show DmStore;
import 'package:xchat/wallet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a warm poll costs far less than re-decrypting history', () async {
    SharedPreferences.setMockInitialValues({});
    final a = NanoWallet('aa' * 32), b = NanoWallet('bb' * 32);
    const n = 500;
    final sealed = [for (var i = 0; i < n; i++) a.dmSeal(b.dmPub, 'message $i ${'x' * 200}')];

    await DmStore.clear(b.account);
    await DmStore.load(b);

    final cold = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final ct = sealed[i];
      if (DmStore.get(ct) == null) {
        DmStore.put(ct, b.dmOpen(a.dmPub, ct)!, i,
            from: a.account, outgoing: false, peer: a.account, peerPk: a.dmPub);
      }
    }
    cold.stop();
    await DmStore.flush(b);

    final warm = Stopwatch()..start();
    var hits = 0;
    for (final ct in sealed) {
      if (DmStore.get(ct) != null) hits++; else b.dmOpen(a.dmPub, ct);
    }
    warm.stop();

    print('  COLD (first poll, all $n decrypted): ${cold.elapsedMilliseconds} ms');
    print('  WARM (every later poll, $hits served from the store): ${warm.elapsedMilliseconds} ms');
    expect(hits, n);
    expect(warm.elapsedMilliseconds, lessThan(cold.elapsedMilliseconds));
  });
}
