// Cross-language canonical-form check (issue #2). Emits the REAL wallet.dart builder outputs as JSON
// so the Python node verifier can recompute the same preimage and confirm byte-for-byte agreement.
// Run: ~/flutter/bin/dart run tool/sigcheck.dart
import 'dart:convert';
import 'package:xchat/wallet.dart';

void main() {
  // any valid 64-hex seed; account is derived deterministically and echoed for the Python side
  final w = NanoWallet('0' * 63 + '1');
  // adversarial inputs: pipe inside free text, emoji (multi-byte UTF-8), empty fields
  final out = {
    'account': w.account,
    'dmPub': w.dmPub,
    'post': w.postEventMsg('bob|evil.xno', 'post', 'hi|kind|there 🚀', 1691000000),
    'head': w.headMsg(7, 'bafyCID', 1699999999),
    'delete': w.deleteMsg('u1691000000', 1691000005),
    'comment': w.commentMsg('u1|2', 1691000010, 'nice|post 😄', ''),
    'follow': w.followMsg(1691000020, ['z.xno', 'a.xno', 'a.xno']),
    'poll': w.pollMsg('poll|1', '2', 1691000030),
    'profile': w.profileMsg(1691000040, 'Alice|A', 'bio with | pipe', '', 'banner🎉'),
    'dmkey': w.dmKeyMsg(1691000050, w.dmPub),
  };
  // full round trip: sign the post canonical on-device exactly as the app does, so Python can verify it
  final signed = w.signMsg(w.postEventMsg('bob|evil.xno', 'post', 'hi|kind|there 🚀', 1691000000));
  out['_sig'] = signed['sig']!;
  out['_pub'] = signed['pub']!;
  print(jsonEncode(out));
}
