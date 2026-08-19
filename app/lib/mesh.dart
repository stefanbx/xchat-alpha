// Mesh reverse-tunnel CLIENT reach path — the phone half of relay/xc_tunnel.py.
//
// A NAT'd relay ("node") dials into a public entry ("hub") and becomes reachable at
//     https://<hub>/r/<token>/<subpath>
// where the routing token is an ephemeral, per-(entry, epoch) ed25519-blake2b PUBLIC key:
//     seed  = blake2b32( "xchat/mesh-tunnel/v1" | secret | entry_id | epoch )   // '|' == byte 0x7c
//     token = ed25519_blake2b_pubkey(seed)
// entry_id is the hub's scheme-less url; epoch = floor(unixtime / 3600). The rendezvous `secret`
// is shared out-of-band with the users allowed to reach this private node — it is deliberately NOT
// on the ledger (publishing it would republish a linkable relay↔entry topology). Holding the secret
// is what lets a client derive the token and address the node; the entry only ever sees the opaque
// token, never an account.
//
// Token derivation is byte-for-byte identical to the Python end (checked in tool/mesh_parity.dart
// against xc_tunnel.token_for), so a token this file mints routes to the node the Python client dials.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:nanodart/nanodart.dart' show Blake2b, NanoHelpers;
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto/ed25519_blake2b.dart' as webed;

class MeshReach {
  static const _kdfDomain = 'xchat/mesh-tunnel/v1';
  static const int epochS = 3600; // must match XC_TUNNEL_EPOCH_S on the relay
  static const _prefsSecret = 'xchat_mesh_secret';
  static const _prefsHubs = 'xchat_mesh_hubs';

  // The shared rendezvous secret and the entry hubs to reach the node through. Loaded from prefs.
  static String secret = '';
  static List<String> hubs = const [];

  static bool get enabled => secret.isNotEmpty && hubs.isNotEmpty;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    secret = sp.getString(_prefsSecret) ?? '';
    hubs = sp.getStringList(_prefsHubs) ?? const [];
  }

  static Future<void> save(String s, List<String> h) async {
    secret = s.trim();
    hubs = h
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList();
    final sp = await SharedPreferences.getInstance();
    if (secret.isEmpty) {
      await sp.remove(_prefsSecret);
    } else {
      await sp.setString(_prefsSecret, secret);
    }
    await sp.setStringList(_prefsHubs, hubs);
  }

  // Canonical entry id: scheme-less, no trailing slash — matches xc_common.url_norm.
  static String urlNorm(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    final i = u.indexOf('://');
    return i >= 0 ? u.substring(i + 3) : u;
  }

  static int epochNow([DateTime? now]) =>
      ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) ~/ epochS;

  // token = ed25519_blake2b_pubkey( blake2b32(domain|secret|entryId|epoch) ), hex.
  static String tokenFor(String secret, String entryId, int epoch) {
    final b = BytesBuilder()
      ..add(utf8.encode(_kdfDomain))
      ..add(const [0x7c])
      ..add(utf8.encode(secret))
      ..add(const [0x7c])
      ..add(utf8.encode(entryId))
      ..add(const [0x7c])
      ..add(utf8.encode('$epoch'));
    final seed = Blake2b.digest256([b.toBytes()]);
    final pub = webed.publicKeyFromSecret(Uint8List.fromList(seed));
    return NanoHelpers.byteToHex(pub).toLowerCase();
  }

  // The /r/<token> base urls to try for ONE hub, across the current epoch window {e-1, e, e+1} — so a
  // client whose clock is within one epoch of the node's always overlaps a token the node is serving.
  static List<String> reachBasesFor(String hub, {int? epoch}) {
    final base = hub.trim().replaceAll(RegExp(r'/+$'), '');
    final eid = urlNorm(hub);
    final e = epoch ?? epochNow();
    return [
      for (final ep in [e - 1, e, e + 1]) '$base/r/${tokenFor(secret, eid, ep)}'
    ];
  }

  // Every reach base across every configured hub, current window. Empty when not configured.
  static List<String> reachBases() {
    if (!enabled) return const [];
    return [for (final h in hubs) ...reachBasesFor(h)];
  }

  // ---- PUBLIC DISCOVERY (no secret) --------------------------------------------------------------
  // A public node opts into listing on its hub, so the hub can hand out its routing token. We just ask
  // each hub "who's attached?" (/mesh_nodes) and build the reach urls — no rendezvous secret involved.
  static List<String> discovered = []; // reach base urls learned from hubs (cached, current window)

  static Future<List<String>> discoverVia(List<String> hubUrls) async {
    final out = <String>[];
    for (final h in hubUrls) {
      final base = h.trim().replaceAll(RegExp(r'/+$'), '');
      if (!base.startsWith('http')) continue;
      try {
        final r = await http
            .get(Uri.parse('$base/mesh_nodes'))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) continue;
        final nodes = (jsonDecode(r.body)['nodes'] as List?) ?? const [];
        for (final t in nodes) {
          if (t is String && t.isNotEmpty) out.add('$base/r/$t');
        }
      } catch (_) {}
    }
    discovered = out;
    return out;
  }

  // Cached reached-node info ({via, account, type, ver}) from the last discovery — for display.
  static List<Map<String, dynamic>> discoveredInfo = [];
  static int _lastDiscover = 0; // ms epoch of last auto-discovery sweep
  static bool _discovering = false;

  // Auto-discover public nodes across EVERY hub the app already knows — the relay set it was handed
  // (plus any manually configured hubs). No hardcoded hub list: a hub that newly appears in that set is
  // swept automatically, and any public node attached to it shows up. Throttled so it can be called
  // freely from hot paths. A relay that isn't a hub just 404s /mesh_nodes and is skipped.
  static Future<void> autoDiscoverFrom(Iterable<String> candidateHubs, {int minGapMs = 45000}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_discovering || now - _lastDiscover < minGapMs) return;
    _discovering = true;
    try {
      final cands = <String>{...candidateHubs, ...hubs}
          .map((e) => e.trim())
          .where((e) => e.startsWith('http'))
          .toSet()
          .toList();
      await discoverVia(cands);
      discoveredInfo = await probeDiscovered();
      _lastDiscover = DateTime.now().millisecondsSinceEpoch;
    } finally {
      _discovering = false;
    }
  }

  // Reach each discovered node's /relays, deduped by account — for the diagnostic + confirmation.
  static Future<List<Map<String, dynamic>>> probeDiscovered() async {
    final seen = <String>{};
    final res = <Map<String, dynamic>>[];
    for (final base in discovered) {
      try {
        final r = await http
            .get(Uri.parse('$base/relays'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body) as Map<String, dynamic>;
          final acct = '${d['account']}';
          if (acct.isNotEmpty && seen.add(acct)) {
            res.add({'via': base, 'account': acct, 'type': d['type'], 'ver': d['ver']});
          }
        }
      } catch (_) {}
    }
    return res;
  }

  // Diagnostic: reach the node's /relays through the hubs; return the first that answers.
  static Future<Map<String, dynamic>?> probe() async {
    for (final base in reachBases()) {
      try {
        final r = await http
            .get(Uri.parse('$base/relays'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body) as Map<String, dynamic>;
          return {
            'via': base,
            'account': d['account'],
            'type': d['type'],
            'ver': d['ver'],
          };
        }
      } catch (_) {}
    }
    return null;
  }

  // Diagnostic: fetch a blob by cid through the tunnel; return its decoded utf8 text or null.
  static Future<String?> fetchBlobText(String cid) async {
    for (final base in reachBases()) {
      try {
        final r = await http
            .get(Uri.parse('$base/blob?cid=$cid'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final b64 = jsonDecode(r.body)['b64'];
          if (b64 is String && b64.isNotEmpty) {
            return utf8.decode(base64Decode(b64));
          }
        }
      } catch (_) {}
    }
    return null;
  }
}
