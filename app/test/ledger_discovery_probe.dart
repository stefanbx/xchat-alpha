// Live-network probe (not a hermetic unit test): runs the real discovery against Nano mainnet.
import 'package:xchat/ledger_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('linkToUrl decodes ASCII, rejects checkins/internal/zero', () {
    // 'xchat-relay-1.fly.dev' packed ASCII (from the live block link)
    expect(LedgerDiscovery.linkToUrl('78636861742d72656c61792d312e666c792e6465760000000000000000000000'),
        'https://xchat-relay-1.fly.dev');
    expect(LedgerDiscovery.linkToUrl('0' * 64), isNull);            // zero link
    // an internal host must be rejected even if validly ASCII-packed
    final internal = '3132372e302e302e313a38300000000000000000000000000000000000000000'; // 127.0.0.1:80
    expect(LedgerDiscovery.linkToUrl(internal), isNull);
  });
  // Hits Nano mainnet over public RPC — opt-in so CI never flakes on a third-party endpoint.
  // Run with: flutter test --dart-define=LIVE=1 test/ledger_discovery_probe.dart
  test('live: discoverUrls runs and returns https URLs (best-effort)', () async {
    final urls = await LedgerDiscovery.discoverUrls();
    // ignore: avoid_print
    print('LIVE discovered: $urls');
    for (final u in urls) {
      expect(u.startsWith('https://'), true);
    }
  },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: const bool.fromEnvironment('LIVE') ? false : 'set --dart-define=LIVE=1 to run');
}
