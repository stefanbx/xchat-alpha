// Prints the canonical signing preimage the APP builds for each signed type, as JSON.
// Used by test/preimage_interop_test.py to prove the Dart and Python preimages are byte-identical —
// they are two implementations of one wire format, and a silent divergence shows up only as valid
// signatures being rejected in production.
import 'dart:convert';
import '../lib/wallet.dart';

void main(List<String> args) {
  final w = NanoWallet(args[0]);
  const postId = 'u1786728999';
  const ts = 1786728999;
  print(jsonEncode({
    'account': w.account,
    'report': w.reportMsg(postId, ts),
    'reshare': w.reshareMsg(postId, ts),
    'delete': w.deleteMsg(postId, ts),
    'head': w.headMsg(13, 'bafybeigao5y5rreaw2ds6vlp7soudighqplfty7iahfv6zup67o4fn65ne', 1789113375),
  }));
}
