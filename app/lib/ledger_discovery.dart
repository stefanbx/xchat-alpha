// App-side ledger discovery — find a live ӾChat endpoint straight from the XNO ledger, with no
// hardcoded server and no dependency on any ӾChat infrastructure. This is the piece that turns
// "censorship-resistant" into "hard to shut down": if every baked-in endpoint (kDefaultBase and the
// user's saved list) is dead, the app re-derives a working one from the Nano mainnet — a data source
// no single party can take offline.
//
// Scheme — mirrors backend/xc_common.py byte-for-byte:
//   * Relays/nodes "check in" by sending 1 raw of dust to a small set of KEYLESS rendezvous accounts.
//   * Each announces its own URL on its own chain, packed as ASCII into a 32-byte block `link`,
//     readable by anyone with a plain `block_info` RPC — no IPFS, no gateway, no directory owner.
//   * Discovery = scan each rendezvous' history for the accounts that checked in, then read each such
//     account's frontier link and decode it back to a URL.
//
// Everything here is a READ over public Nano RPC. No seed, no signing, no writes ever happen here.
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class LedgerDiscovery {
  // The keyless rendezvous accounts (seeds 0x3A/0x3B/0x3C in the backend). Union them for redundancy —
  // no single meeting point is a SPOF. Hardcoded so discovery needs zero prior network state.
  static const List<String> rendezvous = [
    'nano_1ir8af34tu66ed1gg5m8h69xmx41ww5p1azkctydzcdft8h7r7qapthojmb4',
    'nano_3jziw6phzrqf5zchyh7g7dc8t79bpnc5wsppbkxp3ynoud975g5kdc3fbb3b',
    'nano_1utd9eyhic9sdbybyi7tef7nk8uxzmtae31npzoqdrp97eicousdmbf141bx',
  ];

  // Their public keys (hex). A check-in block's `link` is one of these; we skip those blocks when
  // hunting for the URL-bearing one.
  static const Set<String> rendezvousPubs = {
    '430643422d6c8462c0e70e66790fd9f440e7076023f256bcbfa96dd19e5c16e8',
    'c7f0e12cffe2ed1fd4ff3cae2ad46d14e9b5143e66d64cbb60fa95dace51b872',
    '6f4b3b3cf828f95a7c9f40ba634b491b7dfcf4860414b7eb75e2c72b20aaef2b',
  };

  // Public mainnet RPC proxies (the same set the node falls back to). We only ever READ. The ones that
  // reliably serve `receivable`/`account_history` on arbitrary accounts are first; nano.to (which 500s
  // on `receivable`) is last. `_good` memoizes the last endpoint that worked so we stop paying a failed
  // round-trip on every call.
  static const List<String> publicRpcs = [
    'https://nanoslo.0x.no/proxy',
    'https://rainstorm.city/api',
    'https://node.somenano.com/proxy',
    'https://rpc.nano.to',
  ];
  static int _good = 0;

  // One RPC call, tried across the public endpoints (last-good first) until one answers with a usable
  // JSON object.
  static Future<Map<String, dynamic>?> _rpc(Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 6)}) async {
    final order = [_good, ...List.generate(publicRpcs.length, (i) => i).where((i) => i != _good)];
    for (final i in order) {
      try {
        final r = await http
            .post(Uri.parse(publicRpcs[i]),
                headers: const {
                  'content-type': 'application/json',
                  // public RPCs 403 the default UA — send a real one (matches the node).
                  'user-agent': 'xchat/ledger-discovery',
                },
                body: jsonEncode(body))
            .timeout(timeout);
        if (r.statusCode != 200) continue;
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic> && !d.containsKey('error')) {
          _good = i; // remember the winner
          return d;
        }
      } catch (_) {
        // try the next endpoint
      }
    }
    return null;
  }

  // hex link -> "https://host", or null. Mirrors backend link_to_url: bytes, strip trailing NULs, must
  // be printable ASCII containing a dot. Rejects internal/loopback hosts (an on-chain SSRF guard — a
  // hostile announce must not be able to point the app at 127.0.0.1 / a metadata IP / a LAN address).
  static String? linkToUrl(String linkHex) {
    try {
      if (linkHex.isEmpty || RegExp(r'^0+$').hasMatch(linkHex)) return null;
      final bytes = <int>[];
      for (var i = 0; i + 1 < linkHex.length; i += 2) {
        bytes.add(int.parse(linkHex.substring(i, i + 2), radix: 16));
      }
      var end = bytes.length; // strip trailing NUL padding
      while (end > 0 && bytes[end - 1] == 0) {
        end--;
      }
      final b = bytes.sublist(0, end);
      if (b.isEmpty || !b.every((c) => c > 32 && c < 127)) return null; // printable ASCII only
      final host = String.fromCharCodes(b);
      if (!host.contains('.') || _isInternalHost(host)) return null;
      return 'https://$host';
    } catch (_) {
      return null;
    }
  }

  static bool _isInternalHost(String host) {
    final h = host.split(':').first.toLowerCase();
    if (h == 'localhost' || h.endsWith('.local')) return true;
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (m != null) {
      final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      if (a == 127 || a == 10 || a == 0) return true; // loopback / private / this-network
      if (a == 192 && b == 168) return true;
      if (a == 169 && b == 254) return true; // link-local incl. cloud metadata 169.254.169.254
      if (a == 172 && b >= 16 && b <= 31) return true;
    }
    return false;
  }

  // The set of relay/node accounts that have checked in at any rendezvous. The rendezvous are KEYLESS,
  // so check-ins can never be "received" — they sit in `receivable` forever; that's the primary source.
  // (`account_history` is also read in case a rendezvous ever gets opened.) The three scans run at once.
  static Future<Set<String>> _announcedAccounts() async {
    final accts = <String>{};
    await Future.wait(rendezvous.map((rv) async {
      final results = await Future.wait([
        _rpc({
          'action': 'receivable',
          'account': rv,
          'count': '300',
          'source': 'true',
          'include_only_confirmed': 'false',
        }),
        _rpc({'action': 'account_history', 'account': rv, 'count': '300'}),
      ]);
      final blocks = results[0]?['blocks'];
      if (blocks is Map) {
        for (final v in blocks.values) {
          if (v is Map && v['source'] is String) accts.add(v['source'] as String);
        }
      }
      final hist = results[1]?['history'];
      if (hist is List) {
        for (final x in hist) {
          if (x is Map && x['type'] == 'receive' && x['account'] is String) {
            accts.add(x['account'] as String);
          }
        }
      }
    }));
    return accts;
  }

  // account -> the URL it announced. The URL is committed LAST, so the frontier link usually wins on the
  // first read; a couple of recent blocks are a fallback in case the frontier is a later check-in.
  static Future<String?> _accountUrl(String account) async {
    final ai = await _rpc({'action': 'account_info', 'account': account});
    final frontier = ai?['frontier'];
    final hashes = <String>{};
    if (frontier is String) hashes.add(frontier);
    final h = await _rpc({'action': 'account_history', 'account': account, 'count': '3'});
    final hist = h?['history'];
    if (hist is List) {
      for (final x in hist) {
        if (x is Map && x['hash'] is String) hashes.add(x['hash'] as String);
      }
    }
    if (hashes.isEmpty) return null;
    // read the candidate blocks concurrently; take the first that decodes to a real URL
    final infos = await Future.wait(
        hashes.map((hash) => _rpc({'action': 'block_info', 'json_block': 'true', 'hash': hash})));
    for (final bi in infos) {
      final contents = bi?['contents'];
      if (contents is Map && contents['link'] is String) {
        final link = contents['link'] as String;
        if (rendezvousPubs.contains(link.toLowerCase())) continue; // a check-in, not the URL
        final u = linkToUrl(link);
        if (u != null) return u;
      }
    }
    return null;
  }

  // Full scan: every announced URL currently readable off the ledger. Best-effort, parallel, and
  // deadline-bounded so a slow/rate-limited public RPC can never hang the app.
  static Future<List<String>> discoverUrls(
      {int maxAccounts = 16, Duration deadline = const Duration(seconds: 25)}) async {
    Future<List<String>> scan() async {
      final out = <String>{};
      final accts = (await _announcedAccounts()).take(maxAccounts).toList();
      final urls = await Future.wait(accts.map(_accountUrl));
      for (final u in urls) {
        if (u != null) out.add(u.replaceAll(RegExp(r'/+$'), ''));
      }
      return out.toList();
    }

    try {
      return await scan().timeout(deadline);
    } catch (_) {
      return const [];
    }
  }
}
