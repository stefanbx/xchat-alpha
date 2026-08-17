// INTEROP HARNESS — the app half, standing in for a phone.
//
// It imports the SHIPPED wallet (package:xchat/wallet.dart), not a copy of it, so what this signs is
// exactly what the app signs. Two modes:
//
//   dart run bin/interop_sign.dart battery <seedhex>
//       signs one canonical message per write path and prints them as JSON.
//       `test/interop_test.py` verifies each with the node's own Python verifier.
//
//   dart run bin/interop_sign.dart daemon <seedhex>
//       a line-oriented signer: read a message per line on stdin, write {"sig","pub"} per line.
//       `test/e2e_test.py` drives the real node through it, so the end-to-end run has genuine
//       on-device Dart signatures in it rather than a Python imitation of them.
import 'dart:convert';
import 'dart:io';
import 'package:xchat/wallet.dart';

void battery(NanoWallet w) {
  const ts = 1700000000;
  // one per write path the node verifies, with the canonical message spelled out so a drift on
  // either side shows up as a failing test rather than a silently rejected post
  final cases = <Map<String, String>>[
    {'name': 'head', 'msg': w.headMsg(5, 'bafycid', 9999999)},
    {'name': 'post_event', 'msg': w.postEventMsg('you.xno', 'post', 'hello|world', ts)},
    {'name': 'comment', 'msg': w.commentMsg('p1', ts, 'nice one', '')},
    {'name': 'comment_reply', 'msg': w.commentMsg('p1', ts, 'replying', 'c0')},
    {'name': 'follow', 'msg': w.followMsg(ts, ['nano_b', 'nano_a'])},
    {'name': 'poll', 'msg': w.pollMsg('poll1', '0', ts)},
    {'name': 'profile', 'msg': w.profileMsg(ts, 'Alice', 'my bio', '', '')},
    {'name': 'dm_key', 'msg': w.dmKeyMsg(ts, w.dmPub)},
  ];
  print(jsonEncode({
    'account': w.account,
    'pub': w.pub,
    'dm_pub': w.dmPub,
    'sigs': [
      for (final c in cases) {'name': c['name'], 'msg': c['msg'], ...w.signMsg(c['msg']!)}
    ],
  }));
}

void daemon(NanoWallet w) {
  // announce the identity first, then sign whatever arrives, a line at a time
  print(jsonEncode({'account': w.account, 'pub': w.pub, 'dm_pub': w.dmPub}));
  String? line;
  while ((line = stdin.readLineSync()) != null) {
    if (line!.isEmpty) continue;
    final req = jsonDecode(line) as Map<String, dynamic>;
    switch (req['op']) {
      case 'sign':
        print(jsonEncode(w.signMsg(req['msg'] as String)));
      case 'seal':
        print(jsonEncode({'ct': w.dmSeal(req['peer'] as String, req['text'] as String)}));
      case 'open':
        print(jsonEncode({'text': w.dmOpen(req['peer'] as String, req['ct'] as String)}));
      case 'caps_sig':                                 // sign the sealed-sender capability advertisement
        print(jsonEncode(w.signMsg(w.dmKeyCapsMsg(req['ts'] as int, req['caps'] as String))));
      case 'seal_sealed':                              // build a sealed-sender outer envelope {epk, ct}
        print(jsonEncode(w.dmSealSealed(req['peer'] as String, req['text'] as String)));
      case 'open_sealed':                              // open the outer seal → {f, k, i} or null
        print(jsonEncode({'outer': w.dmOpenSealedOuter(req['epk'] as String, req['ct'] as String)}));
      case 'caps':                                     // what this build advertises
        print(jsonEncode({'caps': NanoWallet.dmCaps}));
      case 'quit':
        return;
      default:
        print(jsonEncode({'error': 'unknown op ${req['op']}'}));
    }
  }
}

void main(List<String> args) {
  final mode = args.isNotEmpty ? args[0] : 'battery';
  final w = NanoWallet(args.length > 1 ? args[1] : '07' * 32);
  if (mode == 'daemon') {
    daemon(w);
  } else {
    battery(w);
  }
}
