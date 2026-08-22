// Ӿ Chat — a censorship-free X. The "Ӿ" is the XNO (Nano) symbol.
// Identity = a Nano keypair. Feed = read from the ledger. Tips = feeless Nano.
// Backend = the Keel engine (same censorship-free stack as KeelTube).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nanodart/nanodart.dart' show Blake2b, NanoHelpers;   // Blake2b for DmCtl.keyOf
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:url_launcher/url_launcher.dart';
import 'body.dart';
import 'wallet.dart';
import 'mesh.dart';
import 'ledger_discovery.dart';

// The engine/relay endpoint. Default: the Android emulator reaches the host loopback at
// 10.0.2.2. Runtime-configurable (Settings → Connection) so the app can point at a hosted
// relay (e.g. a Fly.io node) — that's how a physical phone + an emulator share one network.
const String kDefaultBase = 'https://xchat-alpha-node.fly.dev'; // hosted alpha node (run your own + repoint in Settings)
String kBase = kDefaultBase;

// Preferred endpoint for delegated proof-of-work (tip settlement, sends). A node that advertises
// `work: local` in /api/status runs an on-box (often GPU) work server that does PoW in ~a second, vs the
// public work-RPC lottery a plain node falls back to. null => none known, use kBase. Resolved in the
// background; block_process falls back to kBase automatically if this node is unreachable (home nodes sleep).
String? kWorkBase;

// SEVERAL independent default endpoints, across DIFFERENT providers, so a fresh install isn't single-homed
// even before ledger discovery runs: if the primary's host is taken down, the app can still fail over to a
// baked-in alternative on its very first launch. Today: the Fly node + a Cloudflare-Worker-fronted node
// (distinct ingress + compute), with the XNO-ledger scan as the ultimate, unstoppable fallback beyond these.
const List<String> kBootstrapEndpoints = [
  kDefaultBase,                              // Fly ingress + Fly compute
  'https://xc.butucea-stefan.workers.dev',   // Cloudflare Worker ingress -> independent home node
];

// Node endpoints tried in order, with FAILOVER. The app REMEMBERS the last-good one (persisted) and
// uses it directly — no rescan every launch. It only re-probes the list when the current endpoint fails,
// then switches to a healthy one. Seed extra endpoints here or via Settings; a 2nd node makes this real.
List<String> kEndpoints = List.of(kBootstrapEndpoints);

Future<void> _loadEndpoints() async {
  final sp = await SharedPreferences.getInstance();
  final seen = <String>{};
  final list = <String>[];
  for (final e in [
    sp.getString('xchat_endpoint') ?? '',            // legacy single-endpoint pref (last-good)
    ...?sp.getStringList('xchat_endpoints'),
    ...kBootstrapEndpoints,                           // baked-in defaults across providers (fall-through)
  ]) {
    if (e.isNotEmpty && seen.add(e)) list.add(e);
  }
  // On the web, prefer the origin that served the page — same-origin means no CORS preflight, and a
  // laptop pointed at its own node should talk to its own node. A RELAY-only host has no /api at all,
  // so adopt the origin only if it actually answers; otherwise fall through to the remembered list.
  if (kIsWeb) {
    final origin = Uri.base.origin;
    if (origin.startsWith('http') && await _endpointHealthy(origin)) {
      list.remove(origin);
      list.insert(0, origin);
    }
  }
  kEndpoints = list;
  kBase = kEndpoints.first;                            // trust the cached last-good endpoint; no probe here
}

Future<bool> _endpointHealthy(String base) async {
  try {
    final r = await http.get(Uri.parse('$base/api/status')).timeout(const Duration(seconds: 6));
    final d = jsonDecode(r.body);
    return d is Map && d['online'] == true;
  } catch (_) {
    return false;
  }
}

// Probe the list, switch kBase to the first healthy endpoint, move it to the front, persist. Called only
// when the current endpoint FAILED — so a healthy node is never re-probed on the happy path.
Future<bool> resolveEndpoint() async {
  for (final e in kEndpoints) {
    if (await _endpointHealthy(e)) {
      kBase = e;
      kEndpoints.remove(e);
      kEndpoints.insert(0, e);
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('xchat_endpoints', kEndpoints);
      await sp.setString('xchat_endpoint', e);
      return true;
    }
  }
  // Every known endpoint is dead. Self-heal from the XNO ledger — the censorship-resistant bootstrap:
  // no hardcoded server can strand the app if a live one is still announced on-chain.
  return healEndpointsFromLedger();
}

// Re-derive a live endpoint straight from the Nano ledger and fold it into the persisted failover list.
// `switchBase` = true when the current endpoint is dead (lead with the freshly-found live one and adopt
// it now); false for a background top-up (just enrich the fallback list, never move off a healthy node).
Future<bool> healEndpointsFromLedger({bool switchBase = true}) async {
  try {
    final urls = await LedgerDiscovery.discoverUrls();
    final healthy = <String>[];
    for (final u in urls) {
      if (await _endpointHealthy(u)) healthy.add(u); // only keep URLs that actually serve /api
    }
    if (healthy.isEmpty) return false;
    final seen = <String>{};
    final merged = <String>[];
    final ordered = switchBase ? [...healthy, ...kEndpoints] : [...kEndpoints, ...healthy];
    for (final e in ordered) {
      if (seen.add(e)) merged.add(e);
    }
    kEndpoints = merged;
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('xchat_endpoints', kEndpoints);
    if (switchBase) {
      kBase = kEndpoints.first;
      await sp.setString('xchat_endpoint', kBase);
    }
    return true;
  } catch (_) {
    return false;
  }
}

// Pick the fastest proof-of-work node among the known endpoints: one that advertises `work: local`
// (an on-box/GPU work server). Best-effort and cheap; sets kWorkBase (or clears it to fall back to
// kBase when none advertise local). block_process then routes PoW there so tips settle in ~a second.
Future<void> resolveWorkBase() async {
  for (final e in kEndpoints) {
    try {
      final r = await http.get(Uri.parse('$e/api/status')).timeout(const Duration(seconds: 5));
      final d = jsonDecode(r.body);
      if (d is Map && d['online'] == true && d['work'] == 'local') {
        kWorkBase = e;
        return;
      }
    } catch (_) {}
  }
  kWorkBase = null; // none advertise local → use the default endpoint for PoW
}

// On-device signer, built from the local seed. Every write the app publishes (follows, comments,
// polls, profile, …) is signed HERE and only the signed record is sent — the node never sees the
// seed. Set as soon as the seed is known (RootGate), used by the Api layer below.
NanoWallet? gWallet;
const String kGw = 'http://10.0.2.2:8080/ipfs/';
const String kAppVersion = '2.5.6'; // this build; the update checker compares against the signed release.
// 2.3.0: HARD signing-format break (issue #2) — domain-tagged, length-prefixed signature preimage
// (see NanoWallet.sigCanon / node xc_common.sig_canon). Signatures from 2.2.x no longer verify, so
// heads/comments/follows/profiles/polls/dm-keys must be re-published from this build onward.
// Keep in lockstep with pubspec `version:`. Small ALPHA patch steps (2.2.0 → 2.2.1 → 2.2.2 …), anchored at
// 2.2.x: the version doubles as the update-check comparison and the phone already installed 2.2.0, so going
// below it would strand that install. (The 2.x floor is a one-time legacy of superseding the ~v2.1.0 lineage.)
// Alpha safety cap: the in-app wallet is meant to hold only a small tip float, not savings — so the
// worst a bad app build could ever steal is small. Keep real funds in your own wallet.
const double kWalletCapXno = 2.0;
const int kHeadTtl = 2592000; // 30-day backstop; the relay keeps a head until memory pressure (value-evicted)
const Color kAccent = Color(0xFF3E9BFF); // Nano blue
const Color kBg = Color(0xFF000000);
const Color kCard = Color(0xFF0A0A0A);
const Color kLine = Color(0xFF1B1B1D);
const Color kText = Color(0xFFE7E9EA);
const Color kDim = Color(0xFF71767B);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadEndpoints();                              // persisted last-good endpoint + failover list
  await MeshReach.load();                              // rendezvous secret + hubs for reaching a NAT'd node
  runApp(const XChatApp());
}

class XChatApp extends StatelessWidget {
  const XChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ӿ Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kBg),
        // No explicit fontFamily: pinning one family exclusively suppressed Flutter's glyph FALLBACK,
        // so emoji (and the Cyrillic Ӿ) rendered blank. The platform default is still Roboto but keeps
        // the full fallback chain (Noto Color Emoji + Cyrillic), so emoji and Ӿ now render. [verify on build]
        // Snackbars override their bg to the near-black kCard, but M3's default content text assumes the
        // light inverse-surface — so the text came out dark-on-dark. Pin light text on the dark surface.
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: kCard,
          contentTextStyle: TextStyle(color: kText, fontSize: 14),
        ),
      ),
      home: const RootGate(),
    );
  }
}

// ---- wallet: the seed IS the identity; stored on-device, the only backup ----
//
// It lives in the PLATFORM KEYSTORE (Android EncryptedSharedPreferences / iOS Keychain), not in
// ordinary preferences. It used to be plain SharedPreferences, which is a world-readable-to-root
// XML file: the seed never crossed the network, but anything with access to the app's data
// directory could lift the whole identity out of it.
//
// Anyone who installed an earlier build still has a seed in the old place, so `get` MIGRATES it on
// first read — copy into the keystore, then delete the plaintext copy. Skipping that step would
// silently log every existing user out of an account only their seed can recover.
class WalletStore {
  static const _k = 'xchat_seed';
  // Android: EncryptedSharedPreferences, with the master key held in the Keystore. iOS: Keychain.
  static const _secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  // A BROWSER HAS NO KEYSTORE. flutter_secure_storage's web backend is IndexedDB with the wrapping
  // key stored right next to the data, so routing web through it would buy nothing and imply hardware
  // protection that does not exist — and it throws outright where crypto.subtle is unavailable. Use
  // the ordinary store on web and say so in the UI (see the warning on the onboarding screen), so the
  // weaker guarantee is a thing the user is told, not a thing the code quietly pretends away.
  static Future<String?> get() async {
    final prefs = await SharedPreferences.getInstance();
    if (kIsWeb) return prefs.getString(_k);
    final s = await _secure.read(key: _k);
    if (s != null && s.isNotEmpty) return s;
    final legacy = prefs.getString(_k);
    if (legacy == null || legacy.isEmpty) return null;
    await _secure.write(key: _k, value: legacy);
    await prefs.remove(_k);                       // only after the keystore copy is committed
    return legacy;
  }

  static Future<void> save(String s) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(_k, s);
      return;
    }
    await _secure.write(key: _k, value: s);
  }

  static Future<void> clear() async {
    if (!kIsWeb) await _secure.delete(key: _k);
    await (await SharedPreferences.getInstance()).remove(_k);
  }
}

String genSeed() {
  final r = math.Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// n random bytes as hex. Used for a sealed DM's message id, which must be unpredictable (it is the
/// relay's dedup key now that `from` is hidden) and unlinkable to the sender.
String randHex(int nBytes) {
  final r = math.Random.secure();
  return List.generate(nBytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

// who you follow (local; small enough to also publish to relays for portability later)
class FollowStore {
  static const _k = 'xchat_follows';
  static Future<Set<String>> get() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[]).toSet();
  static Future<void> save(Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, s.toList());
}

// app settings: default tip, tip-split %, notification toggles — persisted on-device
class Settings {
  double defaultTip;
  int relaySplit;    // % of a tip that rewards the relay serving the media
  int reposterSplit; // % of a tip that rewards whoever reposted it
  bool notifyLike, notifyComment, notifyTip, notifyDm;
  bool readReceipts;   // tell the other side when you have read their messages
  bool showPresence;   // publish "online now" via the FAST head heartbeat — OPT-IN; off keeps you private
  bool autoReceive;   // claim incoming XNO without being asked — what every Nano wallet does
  int forYouFreshness;      // For You ranking: 0 = popular, 1 = balanced, 2 = latest
  bool forYouBoostFollows;  // boost posts from people you follow
  bool autoSweep;           // auto-forward balance above the safety cap to a savings address
  String sweepAddr;         // the external savings address (this app holds no key for it)
  int feedCacheSize;        // max posts kept on-device; the feed loads from here + fetches only new
  Settings({
    this.defaultTip = 0.01,
    this.relaySplit = 10,
    this.reposterSplit = 5,
    this.notifyLike = true,
    this.notifyComment = true,
    this.notifyTip = true,
    this.notifyDm = true,
    this.autoReceive = true,
    this.readReceipts = true,
    this.showPresence = false,
    this.forYouFreshness = 1,
    this.forYouBoostFollows = true,
    this.autoSweep = false,
    this.sweepAddr = '',
    this.feedCacheSize = 300,
  });
  int get creatorSplit => 100 - relaySplit - reposterSplit;
}

class SettingsStore {
  static const _k = 'xchat_settings';
  static Future<Settings> get() async {
    final s = (await SharedPreferences.getInstance()).getString(_k);
    if (s == null) return Settings();
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return Settings(
        defaultTip: (m['defaultTip'] as num?)?.toDouble() ?? 0.01,
        relaySplit: (m['relaySplit'] as num?)?.toInt() ?? 10,
        reposterSplit: (m['reposterSplit'] as num?)?.toInt() ?? 5,
        notifyLike: m['notifyLike'] ?? true,
        notifyComment: m['notifyComment'] ?? true,
        notifyTip: m['notifyTip'] ?? true,
        notifyDm: m['notifyDm'] ?? true,
        autoReceive: m['autoReceive'] ?? true,
        readReceipts: m['readReceipts'] ?? true,
        showPresence: m['showPresence'] ?? false,
        forYouFreshness: (m['forYouFreshness'] as num?)?.toInt() ?? 1,
        forYouBoostFollows: m['forYouBoostFollows'] ?? true,
        autoSweep: m['autoSweep'] ?? false,
        sweepAddr: m['sweepAddr'] ?? '',
        feedCacheSize: (m['feedCacheSize'] as num?)?.toInt() ?? 300,
      );
    } catch (_) {
      return Settings();
    }
  }

  static Future<void> save(Settings s) async {
    await (await SharedPreferences.getInstance()).setString(
        _k,
        jsonEncode({
          'defaultTip': s.defaultTip,
          'relaySplit': s.relaySplit,
          'reposterSplit': s.reposterSplit,
          'notifyLike': s.notifyLike,
          'notifyComment': s.notifyComment,
          'notifyTip': s.notifyTip,
          'notifyDm': s.notifyDm,
          'autoReceive': s.autoReceive,
          'readReceipts': s.readReceipts,
          'showPresence': s.showPresence,
          'forYouFreshness': s.forYouFreshness,
          'forYouBoostFollows': s.forYouBoostFollows,
          'autoSweep': s.autoSweep,
          'sweepAddr': s.sweepAddr,
          'feedCacheSize': s.feedCacheSize,
        }));
  }
}

// per-viewer moderation you control yourself: mute (hide silently) and block (hide + drop
// their DMs + unfollow). Purely client-side — on a public signed network there is no server to
// enforce a block, so these filter YOUR view, like the reputation-weighted hide. Reversible.
class MuteStore {
  static const _k = 'xchat_muted';
  static Future<Set<String>> get() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[]).toSet();
  static Future<void> save(Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, s.toList());
}

class BlockStore {
  static const _k = 'xchat_blocked';
  static Future<Set<String>> get() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[]).toSet();
  static Future<void> save(Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, s.toList());
}

// Hidden words (Threads-style): a private, on-device list of words/phrases. Any feed post whose text
// contains one is filtered out for this viewer only — nothing is published.
class MutedWordsStore {
  static const _k = 'xchat_muted_words';
  static Future<List<String>> get() async =>
      (await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[];
  static Future<void> save(List<String> w) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, w);
}

// private, on-device bookmarks — a list of saved post ids. Client-side only (like X bookmarks,
// which are private); nothing is published, so your reading list stays yours.
class BookmarkStore {
  static const _k = 'xchat_bookmarks';
  static Future<Set<String>> get() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[]).toSet();
  static Future<void> save(Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, s.toList());
}

// On-device record of every settled tip — what ACTUALLY moved on-chain, per leg (creator / relay /
// reposter), each with its Nano block hash. This is the TIPPER's own receipt trail: the network only
// notifies the recipient, so without this the sender had no way to see, or independently verify, what
// they paid. Newest first, capped; each entry a small JSON blob.
class TxLogStore {
  static const _k = 'xchat_txlog';
  static const _cap = 300;
  static Future<List<Map<String, dynamic>>> get() async {
    final raw = (await SharedPreferences.getInstance()).getStringList(_k) ?? const <String>[];
    return raw
        .map((s) { try { return Map<String, dynamic>.from(jsonDecode(s)); } catch (_) { return <String, dynamic>{}; } })
        .where((m) => m.isNotEmpty)
        .toList();
  }
  static Future<void> add(Map<String, dynamic> tx) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_k) ?? <String>[];
    raw.insert(0, jsonEncode(tx));
    if (raw.length > _cap) raw.removeRange(_cap, raw.length);
    await sp.setStringList(_k, raw);
  }
}

// Per-device engagement memory: which posts THIS device has liked / reposted / counted as viewed.
// Persisted so a view or like is registered ONCE per device, ever — not re-sent on every app launch.
// Without this, _liked/_viewed lived only in RAM: each restart re-counted an impression for every post
// scrolled past and let the user re-like, so the public counters ballooned (3 users → dozens of "views").
class EngageStore {
  static Future<Set<String>> _get(String k) async =>
      ((await SharedPreferences.getInstance()).getStringList(k) ?? const <String>[]).toSet();
  static Future<void> _save(String k, Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(k, s.toList());
  static Future<Set<String>> liked() => _get('xchat_liked');
  static Future<void> saveLiked(Set<String> s) => _save('xchat_liked', s);
  static Future<Set<String>> likedComments() => _get('xchat_liked_comments');   // per-device: like a comment once
  static Future<void> saveLikedComments(Set<String> s) => _save('xchat_liked_comments', s);
  static Future<Set<String>> reposted() => _get('xchat_reposted');
  static Future<void> saveReposted(Set<String> s) => _save('xchat_reposted', s);
  static Future<Set<String>> viewed() => _get('xchat_viewed');
  static Future<void> saveViewed(Set<String> s) => _save('xchat_viewed', s);
}

// Android system notifications (likes / comments / tips / DMs) + the unread-DM count on the app icon.
// This app has no push server (notifications are POLLED from the relays), so alerts fire when the app
// polls — foreground, or a periodic tick — not via FCM when fully killed.
class Notifs {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static Future<void> init() async {
    if (_ready) return;
    const init = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await _p.initialize(init);
    // Android 13+ needs a runtime grant for POST_NOTIFICATIONS.
    await _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  }
  static Future<void> show(int id, String title, String body) async {
    await init();
    const details = NotificationDetails(
        android: AndroidNotificationDetails('xchat_activity', 'Activity',
            channelDescription: 'Likes, comments, tips and messages on your posts',
            importance: Importance.high, priority: Priority.high, icon: '@mipmap/ic_launcher'));
    await _p.show(id, title, body, details);
  }
  static Future<void> setBadge(int count) async {
    try {
      if (count > 0) {
        await AppBadgePlus.updateBadge(count);
      } else {
        await AppBadgePlus.updateBadge(0);   // clear
      }
    } catch (_) {}   // launcher may not support numeric badges
  }
}

// Swipe a bubble toward its own side to reply to it — the gesture every messenger has, and the
// reason the long-press menu is not the only route to Reply.
//
// Horizontal only: the thread scrolls vertically, so claiming the horizontal axis costs nothing and
// cannot fight the list. The bubble follows the finger up to a limit and springs back, so a drag that
// does not reach the threshold reads as "not far enough" rather than as nothing happening.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.child, required this.onReply, required this.fromRight});
  final Widget child;
  final VoidCallback onReply;
  final bool fromRight;          // your own messages sit right and swipe left; theirs the reverse

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _trigger = 56.0;  // far enough to be deliberate, short enough to be easy
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    final sign = widget.fromRight ? -1 : 1;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragUpdate: (d) {
        // Only track movement in the reply direction, and damp it past the trigger so the bubble
        // does not slide off with the finger.
        final next = _dx + d.delta.dx * sign;
        setState(() => _dx = next.clamp(0.0, _trigger * 1.35));
      },
      onHorizontalDragEnd: (_) {
        final fire = _dx >= _trigger;
        setState(() => _dx = 0);
        if (fire) widget.onReply();
      },
      onHorizontalDragCancel: () => setState(() => _dx = 0),
      child: Stack(
        alignment: widget.fromRight ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          // The arrow fades in with the drag, so the gesture explains itself the first time.
          Opacity(
            opacity: (_dx / _trigger).clamp(0.0, 1.0),
            child: Padding(
              padding: EdgeInsets.only(
                  left: widget.fromRight ? 0 : 6, right: widget.fromRight ? 6 : 0),
              child: const Icon(Icons.reply, size: 18, color: kDim),
            ),
          ),
          Transform.translate(offset: Offset(_dx * sign, 0), child: widget.child),
        ],
      ),
    );
  }
}

// SEALED CONTROL MESSAGES — the envelope reactions, read receipts and anything after them ride in.
//
// A control message is an ordinary DM: same sealing, same relay path, same "relays hold ciphertext
// and nothing else". It differs only in that the recipient's client ACTS on it instead of showing it.
// That is deliberate — a relay must not be able to tell a reaction from a sentence, or it would learn
// the shape of a conversation it is not allowed to read.
//
// FORMAT is one line and nothing else:   xchat:ctl/1 <type> <json>
//
// Whole-message, not a prefix on a normal message, so a client that understands it can suppress the
// bubble entirely rather than rendering a stray line under someone's text.
//
// SUPPRESS-UNKNOWN is the forward-compatibility rule and the reason for the version in the tag: a
// client that meets a type it does not know still recognises the envelope, so it hides the message
// rather than printing machine text at the reader. Today's build therefore stays quiet in front of
// whatever ships next, without being taught about it.
//
// HONEST LIMIT: a client that predates this — and real users are on older builds, we watched an
// operator sit two releases behind all day — has no idea what the envelope is and will render the
// raw line as a message. That is the same trade the quote format made, and it is why control
// messages must stay LOW FREQUENCY. A reaction now and then is a tolerable oddity in an old client;
// a read receipt per message opened would be a flood, which is exactly why receipts should batch to
// one per conversation rather than one per message.
class DmCtl {
  static const tag = 'xchat:ctl/1 ';

  /// A stable id for a message that BOTH sides can compute. The ciphertext is the one thing sender
  /// and recipient hold identically, so its digest names a message without either side inventing an
  /// id or a relay having to assign one. Truncated: this only has to be unique within a conversation.
  static String keyOf(String ciphertext) =>
      NanoHelpers.byteToHex(Blake2b.digest256([Uint8List.fromList(utf8.encode(ciphertext))]))
          .toLowerCase()
          .substring(0, 16);

  static String encode(String type, Map<String, dynamic> data) =>
      '$tag$type ${jsonEncode(data)}';

  /// Parse a control message, or null if this is ordinary text. Never throws: a malformed envelope
  /// from a peer must not be able to break the thread it appears in.
  static ({String type, Map<String, dynamic> data})? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(tag) || t.contains('\n')) return null;
    final rest = t.substring(tag.length);
    final sp = rest.indexOf(' ');
    if (sp <= 0) return null;
    final type = rest.substring(0, sp);
    try {
      final j = jsonDecode(rest.substring(sp + 1));
      if (j is! Map) return null;
      return (type: type, data: j.cast<String, dynamic>());
    } catch (_) {
      // A recognised envelope with unreadable payload is still an envelope: report it so the caller
      // HIDES it. Falling back to null here would print the raw line at the reader instead.
      return (type: type, data: const <String, dynamic>{});
    }
  }

  /// True for anything that should not be drawn as a chat bubble — including types this build has
  /// never heard of. See SUPPRESS-UNKNOWN above.
  static bool isControl(String text) => parse(text) != null;
}

/// A group message, as it travels.
///
/// GROUPS RIDE THE 1:1 PATH. The content is sealed once under a fresh key and stored as a single
/// blob; each member then receives an ordinary DM carrying the group id, the blob's cid and that
/// key. So a photo sent to thirty people is one photo on the relays plus thirty envelopes of a few
/// hundred bytes — and delivery, push, the encrypted on-device store, ordering, attachments and the
/// control envelope all work already, without any of them learning that groups exist.
///
/// It is also what settles authorship. The key travels inside a crypto_box from sender to member,
/// which nobody else can produce, so the MAC that already protects a 1:1 DM protects this too. The
/// design this replaced shared one ciphertext with a wrap map, and there every member necessarily
/// learned the content key — enough to re-seal different words under wraps they could copy but not
/// forge, and have everyone read an attacker's message under the real sender's name. That needed a
/// separate signature over the ciphertext. This needs nothing.
///
/// MEMBERSHIP IS LAST-WRITER-WINS and rides in every message. There is no shared group record and no
/// consensus: each message names the group and lists who the sender believes is in it, and a client
/// takes the newest list it has seen. Two people adding different members at the same moment is
/// resolved by whoever sent last, which is a real limitation and the honest cost of having no
/// coordinator. Removal is not retroactive — it only means the next message's key is not sent to
/// them.
/// Hidden from a 1:1 thread: true for anything delivered as a DM that is not part of THIS
/// conversation — control messages and group envelopes alike. One predicate, because every place
/// that filters one must filter the other, and the inbox already proved that remembering to do it
/// twice does not work.
bool hiddenInDm(String text) => DmCtl.isControl(text) || GroupMsg.isGroup(text);

class GroupMsg {
  static const tag = 'xchat:grp/1 ';

  final String gid, name, cid, key;
  final List<String> members;         // accounts, including the sender
  const GroupMsg(
      {required this.gid,
      required this.name,
      required this.cid,
      required this.key,
      required this.members});

  String encode() => '$tag${jsonEncode({
        'g': gid,
        'n': name,
        'c': cid,
        'k': key,
        'm': members,
      })}';

  static GroupMsg? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(tag) || t.contains('\n')) return null;
    try {
      final j = jsonDecode(t.substring(tag.length));
      if (j is! Map) return null;
      final gid = '${j['g'] ?? ''}';
      final cid = '${j['c'] ?? ''}';
      final key = '${j['k'] ?? ''}';
      // A group message with no id, no content or no key is not a group message we can act on, and
      // showing the raw JSON at the reader would be the worst of both.
      if (gid.isEmpty || cid.isEmpty || key.isEmpty) return null;
      return GroupMsg(
        gid: gid,
        name: '${j['n'] ?? ''}',
        cid: cid,
        key: key,
        members: ((j['m'] as List?) ?? const []).map((e) => '$e').toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Hidden from a 1:1 thread the same way control messages are: a group message happens to be
  /// delivered as a DM, but it belongs to the group, not to the conversation with the sender. Older
  /// builds print the raw line — the same cost the control envelope already carries, and the reason
  /// both tags are checked in one place.
  static bool isGroup(String text) => parse(text) != null;
}

// ON-DEVICE MESSAGE STORE — decrypt each DM once, ever.
//
// A poll opens EVERY ciphertext in the inbox and throws the plaintext away, so cost grows linearly
// with history forever: measured at 437ms per poll over 500 messages, running every 5s in an open
// thread plus every 12s for the home badge. Caching the box halved that; this removes the rest by not
// decrypting a message we have already read.
//
// ENCRYPTED AT REST, and not optionally. The entire claim of this feature is that these bytes are
// secret — relays hold ciphertext and nothing else — so a plaintext cache on the phone would hand
// away exactly what we refused to give the network, to anything that can read app storage. The blob
// is sealed to the wallet's OWN DM key (crypto_box to self), which reuses the audited path instead of
// inventing a second one and ties the store to the identity that owns it: a different seed cannot
// open it, so a reinstall or wallet switch reads as an empty store rather than leaking the previous
// identity's conversations.
//
// One sealed blob, not one entry per key: flutter_secure_storage is built for a handful of small
// secrets, and thousands of keystore round-trips would cost more than the decryption this exists to
// avoid. The blob is opaque, so ordinary preferences are a fine place to keep it.
class DmStore {
  static const _k = 'xchat_dm_store';
  static const _max = 4000;
  static final Map<String, Map<String, dynamic>> _mem = {};   // ct -> {t: text, s: ts}
  static String _owner = '';
  static bool _dirty = false;

  static String? get(String ct) => _mem[ct]?['t'] as String?;
  static int get count => _mem.length;

  /// Newest message we hold. The incremental fetch asks the node for everything at or after this,
  /// minus an overlap — see Api.dmInbox for why the overlap is not optional.
  static int get newestTs {
    var t = 0;
    for (final v in _mem.values) {
      final s = (v['s'] ?? 0) as int;
      if (s > t) t = s;
    }
    return t;
  }

  /// Every message we hold, as the conversation-shaped records dmInbox returns. The store is the
  /// source of truth for history now: an incremental response carries only what is NEW, so threads
  /// have to be rebuilt from here or they would shrink to the last few messages on every poll.
  static List<Map<String, dynamic>> all() => [
        for (final v in _mem.values)
          if (v['p'] != null)
            {
              'from': v['f'], 'outgoing': v['o'] == true, 'text': v['t'],
              'ts': v['s'], 'peer': v['p'], 'peer_pk': v['k'], 'id': v['i'],
            }
      ];

  static void put(String ct, String text, int ts,
      {required String from, required bool outgoing, required String peer, required String peerPk}) {
    if (_mem.containsKey(ct)) return;
    // 'i' is the message id BOTH sides can compute from the ciphertext — what a reaction or a read
    // receipt points at. Derived here so it is stored once rather than hashed on every rebuild.
    _mem[ct] = {'t': text, 's': ts, 'f': from, 'o': outgoing, 'p': peer, 'k': peerPk,
                'i': DmCtl.keyOf(ct)};
    _dirty = true;
  }

  static Future<void> load(NanoWallet w) async {
    if (_owner == w.account && _mem.isNotEmpty) return;
    if (_owner != w.account) { _mem.clear(); _dirty = false; }
    _owner = w.account;
    try {
      final blob = (await SharedPreferences.getInstance()).getString('${_k}_${w.account}');
      if (blob == null || blob.isEmpty) return;
      // Sealed to ourselves, so our own DM key opens it. A blob written under a DIFFERENT seed fails
      // here and is ignored — the store rebuilds from the relay rather than throwing.
      final plain = w.dmOpen(w.dmPub, blob);
      if (plain == null) return;
      for (final e in (jsonDecode(plain) as Map<String, dynamic>).entries) {
        final rec = (e.value as Map).cast<String, dynamic>();
        // Backfill the message id for anything stored before ids existed. The map KEY is the
        // ciphertext, so it can be derived rather than migrated — without this, every message
        // already on the device would be unreactable, which is not a state a user could diagnose.
        rec['i'] ??= DmCtl.keyOf(e.key);
        _mem[e.key] = rec;
      }
    } catch (_) {
      _mem.clear();                      // corrupt or unreadable: start clean, never break a poll
    }
  }

  static Future<void> flush(NanoWallet w) async {
    if (!_dirty || _owner != w.account) return;
    _dirty = false;
    try {
      // Eviction drops the OLDEST, and that choice deserves stating: a relay also evicts ciphertext
      // under memory pressure, so a message gone from both is gone for good. The cap sits well above
      // any real thread to keep this theoretical, and the oldest is what a relay is likeliest to
      // still hold, since a live head keeps its thread alive.
      if (_mem.length > _max) {
        final byAge = _mem.entries.toList()
          ..sort((a, b) => ((a.value['s'] ?? 0) as int).compareTo((b.value['s'] ?? 0) as int));
        for (final e in byAge.take(_mem.length - _max)) {
          _mem.remove(e.key);
        }
      }
      final sealed = w.dmSeal(w.dmPub, jsonEncode(_mem));
      await (await SharedPreferences.getInstance()).setString('${_k}_${w.account}', sealed);
    } catch (_) {
      _dirty = true;                     // failed write: retry on the next flush
    }
  }

  /// Wipe a wallet's messages, so a replaced seed cannot inherit the previous identity's threads.
  static Future<void> clear(String account) async {
    _mem.clear();
    _owner = '';
    _dirty = false;
    try {
      await (await SharedPreferences.getInstance()).remove('${_k}_$account');
    } catch (_) {}
  }
}

// Remembers the update the user dismissed — for A DAY, not forever.
//
// It used to store the bare version string and suppress that version permanently. One tap on the ×
// and the banner never returned, which is wrong for the thing that carries security fixes: the user
// who most wants to postpone an update today is not saying "never tell me again". A day is long
// enough that dismissing means something and short enough that nothing important goes unmentioned.
//
// Stored as "version|unixSeconds". A legacy bare value (no separator) reads as dismissed at time 0,
// i.e. already expired — so anyone who dismissed under the old permanent rule is told once more.
class UpdateDismiss {
  static const _k = 'xchat_update_dismissed';
  static const _ttl = Duration(days: 1);

  static Future<String> get() async =>
      ((await SharedPreferences.getInstance()).getString(_k) ?? '').split('|').first;

  /// Should the banner stay hidden for this version right now?
  static Future<bool> suppressed(String version) async {
    final raw = (await SharedPreferences.getInstance()).getString(_k) ?? '';
    if (raw.isEmpty) return false;
    final parts = raw.split('|');
    if (parts.first != version) return false;              // a different version is always worth showing
    final at = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - at;
    return age >= 0 && age < _ttl.inSeconds;
  }

  static Future<void> set(String version) async =>
      (await SharedPreferences.getInstance()).setString(
          _k, '$version|${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
}

// Whether the user has CONFIRMED (by re-entering characters from their backup) that they saved a
// wallet's recovery seed. A random-seed wallet whose seed isn't backed up is unrecoverable if the app
// is reinstalled, so a fresh wallet can't be entered until this is set, and existing wallets are nagged.
class BackupStore {
  static String _k(String acct) => 'xchat_backed_up_$acct';
  static Future<bool> get(String acct) async =>
      (await SharedPreferences.getInstance()).getBool(_k(acct)) ?? false;
  static Future<void> set(String acct, bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_k(acct), v);
}

// OUTBOX: posts composed while OFFLINE are queued here (persisted across restarts) and auto-flushed
// when connectivity returns. Each entry carries everything a later Api.post round-trip needs — the
// head's seq/cid can only be assigned by the node (see the two-step prepare/submit), so we can't
// pre-sign the head offline; instead we hold the signed-when-sent COMPOSE INTENT and replay it, keeping
// the original compose timestamp so ordering is preserved.
class Outbox {
  static const _k = 'xchat_outbox';
  static Future<List<Map<String, dynamic>>> load() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[])
          .map((e) => (jsonDecode(e) as Map).cast<String, dynamic>())
          .toList();
  static Future<void> saveAll(List<Map<String, dynamic>> items) async =>
      (await SharedPreferences.getInstance())
          .setStringList(_k, items.map((e) => jsonEncode(e)).toList());
}

bool validSeed(String s) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s.trim());

// gate: no seed → onboarding; seed → activate wallet on the engine, then the app
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _loading = true;
  String? _seed;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = await WalletStore.get();
    if (s != null) {
      gWallet = NanoWallet(s);        // build the on-device signer; the seed is NEVER sent to the node
    }
    setState(() {
      _seed = s;
      _loading = false;
    });
  }

  Future<void> _onDone(String seed) async {
    // Drop the OUTGOING identity's cached messages before adopting a new seed. The blob is sealed to
    // the old wallet's key so the new one could not read it anyway, but leaving it on disk keeps
    // someone's conversations after they have handed the phone on or restored a different wallet.
    final prev = gWallet?.account;
    if (prev != null) await DmStore.clear(prev);
    await WalletStore.save(seed);
    gWallet = NanoWallet(seed);       // seedless node: nothing to activate server-side
    setState(() => _seed = seed);
  }

  Future<void> _logout() async {
    final prev = gWallet?.account;
    if (prev != null) await DmStore.clear(prev);   // logging out must not leave messages behind
    await WalletStore.clear();
    gWallet = null;
    setState(() => _seed = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: kAccent)));
    }
    if (_seed == null) return OnboardingScreen(onDone: _onDone);
    return FeedScreen(key: ValueKey(_seed), onLogout: _logout);
  }
}

// ---- onboarding: create a new wallet (with seed backup) or restore from a seed ----
class OnboardingScreen extends StatefulWidget {
  final Future<void> Function(String seed) onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String _step = 'choose'; // choose | backup | verify | restore
  String _newSeed = '';
  bool _saved = false;
  final _restoreC = TextEditingController();
  String? _err;
  bool _busy = false;
  // mandatory backup verification: the user re-enters the seed characters at these positions FROM THEIR
  // BACKUP (the seed is hidden here), proving they actually saved it — not just ticked a box.
  List<int> _vpos = [];
  final _vctl = [TextEditingController(), TextEditingController(), TextEditingController()];
  String? _verr;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _step == 'choose'
              ? _choose()
              : _step == 'backup'
                  ? _backup()
                  : _step == 'verify'
                      ? _verify()
                      : _restore(),
        ),
      ),
    );
  }

  Widget _brand() => Column(children: const [
        NanoMark(size: 64),
        SizedBox(height: 14),
        Text('Ӿ Chat',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 28)),
        SizedBox(height: 6),
        Text('a censorship-free X. your account is a Nano keypair — no email, no server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kDim, fontSize: 13, height: 1.4)),
      ]);

  Widget _choose() => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        _brand(),
        const SizedBox(height: 40),
        _bigBtn('Create a new wallet', kAccent, Colors.black, () {
          setState(() {
            _newSeed = genSeed();
            _saved = false;
            _step = 'backup';
          });
        }),
        const SizedBox(height: 12),
        _bigBtn('I already have a seed', kCard, kText, () => setState(() => _step = 'restore')),
        // Say the quiet part out loud. On Android the seed sits in the Keystore; in a browser it sits
        // in ordinary site storage, readable by anything that can run script on this page — including
        // whoever is hosting it. Someone choosing between the two deserves to know before they paste
        // a seed that controls real money.
        if (kIsWeb) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: kCard, borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withOpacity(0.35))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 17, color: Colors.amber),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                    'You are using ӾChat in a browser. Your seed is kept in this browser\'s storage, '
                    'which is weaker than the phone app\'s keystore — and this page is served by whoever '
                    'runs this node. For an account holding real value, prefer the Android app, or use a '
                    'seed here that you are willing to treat as disposable.',
                    style: TextStyle(color: kDim, fontSize: 11.5, height: 1.45)),
              ),
            ]),
          ),
        ],
      ]);

  Widget _backup() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 12),
        const Text('Back up your recovery seed',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 22)),
        const SizedBox(height: 8),
        const Text('This 64-character seed IS your account. Write it down and keep it secret — anyone who has it controls your identity, and nobody can recover it for you.',
            style: TextStyle(color: kDim, fontSize: 13, height: 1.5)),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
          child: SelectableText(_newSeed,
              style: const TextStyle(
                  color: kAccent, fontFamily: 'monospace', fontSize: 15, height: 1.5, letterSpacing: 1)),
        ),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => setState(() => _saved = !_saved),
          child: Row(children: [
            Icon(_saved ? Icons.check_box : Icons.check_box_outline_blank,
                color: _saved ? kAccent : kDim),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('I have written down my seed and stored it safely',
                    style: TextStyle(color: kText, fontSize: 14))),
          ]),
        ),
        const SizedBox(height: 8),
        const Text("Next you'll confirm a few characters from your backup — the app can't recover this seed for you.",
            style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
        const SizedBox(height: 14),
        // Set the anonymity model at creation, before any funds arrive: the account is public on the
        // ledger, and how it is funded is what does or doesn't tie it to a real name. The receive sheet
        // repeats this at each funding; here it lands first. See docs/ANONYMITY.md.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Icon(Icons.public, size: 15, color: Color(0xFF4DD0A7)),
          SizedBox(width: 8),
          Expanded(
            child: Text('This account is also public on the Nano ledger. Fund it in a way that isn\'t tied to your name to stay pseudonymous.',
                style: TextStyle(color: kDim, fontSize: 12, height: 1.45)),
          ),
        ]),
        const Spacer(),
        _bigBtn('Continue', _saved ? kAccent : kLine, _saved ? Colors.black : kDim,
            _saved ? () => _startVerify() : null),
      ]);

  void _startVerify() {
    final rnd = math.Random();
    // three distinct positions, one from each third of the 64-char seed, so they're spread + locatable
    final p = <int>[rnd.nextInt(21), 21 + rnd.nextInt(21), 42 + rnd.nextInt(22)];
    for (final c in _vctl) { c.clear(); }
    setState(() { _vpos = p; _verr = null; _step = 'verify'; });
  }

  Widget _verify() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 12),
        Row(children: [
          IconButton(
              onPressed: () => setState(() => _step = 'backup'),
              icon: const Icon(Icons.arrow_back, color: kText)),
          const Text('Confirm your backup',
              style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 22)),
        ]),
        const SizedBox(height: 8),
        const Text('From the seed you just saved, enter the character at each position. (The seed is hidden here on purpose — use your written copy.)',
            style: TextStyle(color: kDim, fontSize: 13, height: 1.5)),
        const SizedBox(height: 22),
        for (int i = 0; i < _vpos.length; i++) Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            SizedBox(width: 120, child: Text('Character #${_vpos[i] + 1}',
                style: const TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600))),
            const SizedBox(width: 12),
            Expanded(child: TextField(
              controller: _vctl[i],
              maxLength: 1,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kAccent, fontFamily: 'monospace', fontSize: 20, letterSpacing: 2),
              decoration: InputDecoration(
                  counterText: '', filled: true, fillColor: kCard,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kLine)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kAccent))),
            )),
          ]),
        ),
        if (_verr != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_verr!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 13))),
        const Spacer(),
        _bigBtn(_busy ? 'Setting up…' : 'Confirm & enter Ӿ Chat', kAccent, Colors.black, _busy ? null : () {
          for (int i = 0; i < _vpos.length; i++) {
            if (_vctl[i].text.trim().toLowerCase() != _newSeed[_vpos[i]].toLowerCase()) {
              setState(() => _verr = "That doesn't match your seed. Check your written copy (or go back to view it again).");
              return;
            }
          }
          _finish(_newSeed, backedUp: true);
        }),
      ]);

  Widget _restore() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 12),
        Row(children: [
          IconButton(
              onPressed: () => setState(() => _step = 'choose'),
              icon: const Icon(Icons.arrow_back, color: kText)),
          const Text('Restore from seed',
              style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 22)),
        ]),
        const SizedBox(height: 8),
        const Text('Paste the 64-character seed from your other device. Your account, posts, tips and follows come back — they live on the network, not the phone.',
            style: TextStyle(color: kDim, fontSize: 13, height: 1.5)),
        const SizedBox(height: 18),
        TextField(
          controller: _restoreC,
          maxLines: 3,
          style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 15),
          decoration: InputDecoration(
              hintText: '64 hex characters',
              hintStyle: const TextStyle(color: kDim),
              filled: true,
              fillColor: kCard,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kAccent))),
        ),
        if (_err != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12))),
        const Spacer(),
        _bigBtn(_busy ? 'Restoring…' : 'Restore', kAccent, Colors.black, _busy
            ? null
            : () {
                final s = _restoreC.text.trim();
                if (!validSeed(s)) {
                  setState(() => _err = 'That is not a valid 64-hex seed.');
                  return;
                }
                _finish(s, backedUp: true);   // they hold the seed already — it IS their backup
              }),
      ]);

  Future<void> _finish(String seed, {bool backedUp = false}) async {
    setState(() => _busy = true);
    // A restored seed is by definition already backed up (they just typed it in); a created one is
    // backed up only after the verify step. Either way, record it so money features aren't gated.
    if (backedUp) {
      try { await BackupStore.set(NanoWallet(seed).account, true); } catch (_) {}
    }
    await widget.onDone(seed);
  }

  Widget _bigBtn(String label, Color bg, Color fg, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );
}

// ---- data ----
// Issuer head-extension: keep OUR head (and thus our posts) visible past the 1h TTL, until this epoch,
// even while the app is closed. Set when the author pins their own post; persisted per account.
class HeadKeep {
  static String _k(String acct) => 'xchat_headkeep_$acct';
  static Future<int> get(String acct) async =>
      (await SharedPreferences.getInstance()).getInt(_k(acct)) ?? 0;
  static Future<void> set(String acct, int epoch) async =>
      (await SharedPreferences.getInstance()).setInt(_k(acct), epoch);
}

class Post {
  final String id, handle, account, kind, text;
  final String? title, media, thumb, dur;
  final String? quote, replyTo; // quoted post id (quote-post) / parent post id (thread chain)
  final List<String>? poll; // poll options (kind == 'poll'); text is the question
  final int ts, likes, reposts;
  final int edited; // unix-s the author last edited this post (0 = never); drives the "edited" marker
  int localLikes;
  bool liked;
  bool pending = false; // a locally-queued (offline) post not yet sent to any relay
  Post(this.id, this.handle, this.account, this.kind, this.text, this.title,
      this.media, this.thumb, this.dur, this.ts, this.likes, this.reposts,
      {this.quote, this.replyTo, this.poll, this.edited = 0})
      : localLikes = likes,
        liked = false;
  factory Post.fromJson(Map<String, dynamic> j) => Post(
        j['id'] ?? '',
        j['handle'] ?? 'anon.xno',
        j['account'] ?? '',
        j['kind'] ?? 'post',
        j['text'] ?? '',
        j['title'],
        j['media'],
        j['thumb'],
        j['dur'],
        j['ts'] ?? 0,
        j['likes'] ?? 0,
        j['reposts'] ?? 0,
        quote: j['quote'],
        replyTo: j['reply_to'],
        poll: (j['poll']?['options'] as List?)?.map((e) => '$e').toList(),
        edited: (j['edited'] is int) ? j['edited'] as int : 0,
      );
  // Round-trips through fromJson (same keys) for the on-device feed cache. Runtime-only fields
  // (liked/localLikes/pending) are intentionally not persisted — engagement counts refresh on load.
  Map<String, dynamic> toJson() => {
        'id': id, 'handle': handle, 'account': account, 'kind': kind, 'text': text,
        if (title != null) 'title': title,
        if (media != null) 'media': media,
        if (thumb != null) 'thumb': thumb,
        if (dur != null) 'dur': dur,
        'ts': ts, 'likes': likes, 'reposts': reposts,
        if (quote != null) 'quote': quote,
        if (replyTo != null) 'reply_to': replyTo,
        if (poll != null) 'poll': {'options': poll},
        if (edited > 0) 'edited': edited,
      };
}

// a moderation labeler: on-chain identity, reputation (Nano voting weight),
// and the posts it has flagged. Nothing here deletes — the client filters.
class Labeler {
  final String account, name;
  final double stake; // reputation = on-chain delegated voting weight
  final int lastTs;
  final Map<String, Map<String, dynamic>> flags; // postId -> {verdict, reason, ts}
  Labeler(this.account, this.name, this.stake, this.lastTs, this.flags);
}

class PostMod {
  final List<Labeler> flaggers;
  final double frac; // fraction of reputation flagging (earned + decayed)
  final bool hide;
  final String verdict, reason;
  PostMod(this.flaggers, this.frac, this.hide, this.verdict, this.reason);
}

class FeedData {
  final List<Post> posts;
  final int onchainBlocks; // Nano blocks the whole feed has ever cost
  final int relaysUp, relaysTotal; // plural relays reachable this load
  FeedData(this.posts, this.onchainBlocks, this.relaysUp, this.relaysTotal);
}

class Api {
  // on-chain relay discovery: the engine resolves the relay set off the XNO ledger (the
  // relay-directory account's frontier commits the relay-list CID). Returns {account, relays,
  // source, block} so the app can show the network was found on-chain, not from a hardcoded URL.
  static Future<Map<String, dynamic>?> relaydir() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/relaydir')).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(r.body);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  // since > 0 asks the node for ONLY posts newer than that ts (incremental poll), so a quiet
  // refresh usually returns an empty list instead of re-downloading the whole feed.
  /// The newest page of the feed. `before` walks backwards through older posts.
  ///
  /// Paged because the feed returned EVERY post it had — 625 bytes each, so a thousand posts is
  /// ~0.6 MB fetched, JSON-parsed on the UI isolate and written to the local cache on every full
  /// refresh. Invisible at 33 posts, and the one cost here that grows with the network's success.
  /// A page is bounded work no matter how large the network gets.
  static bool feedHasMore = false;      // set by the last paged fetch; drives the load-more trigger

  static Future<FeedData> feed({int since = 0, int limit = 0, int before = 0}) async {
    final q = <String>[
      if (since > 0) 'since=$since',
      if (limit > 0) 'limit=$limit',
      if (before > 0) 'before=$before',
    ];
    final url = q.isEmpty ? '$kBase/api/feed' : '$kBase/api/feed?${q.join('&')}';
    final r = await http.get(Uri.parse(url));
    final d = jsonDecode(r.body);
    final c = d['content'] ?? {};
    final posts = (c['posts'] as List?) ?? [];
    feedHasMore = c['more'] == true;
    // Persistence of the feed is owned by the feed screen now (loadCachedPosts/saveCachedPosts below):
    // it keeps a bounded, merged set across launches and fetches only what's new, instead of this
    // caching a single full-page snapshot that the next launch threw away.
    return FeedData(
        posts.map((p) => Post.fromJson(p)).toList(),
        (d['onchain_blocks'] ?? 0) as int,
        (c['relays_up'] ?? 0) as int,
        (c['relays_total'] ?? 0) as int);
  }

  // ---- on-device feed cache: a bounded, persisted set of posts -----------------------------------
  // The feed loads from here INSTANTLY on launch (no blank frame, no full re-download), then fetches
  // only posts newer than the newest cached one. The set is capped to the user's feedCacheSize and
  // trimmed oldest-first on save — the same idea as a relay bounding its own store rather than keeping
  // every post forever.
  static const _feedCacheKey = 'xchat_feed_posts';

  static Future<List<Post>> loadCachedPosts() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_feedCacheKey);
      if (s == null || s.isEmpty) return [];
      final list = (jsonDecode(s) as List)
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.ts.compareTo(a.ts));   // newest first, ready to render
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCachedPosts(List<Post> posts, int cap) async {
    try {
      final sorted = [...posts]..sort((a, b) => b.ts.compareTo(a.ts));
      final capped = (cap > 0 && sorted.length > cap) ? sorted.sublist(0, cap) : sorted;
      await (await SharedPreferences.getInstance())
          .setString(_feedCacheKey, jsonEncode(capped.map((p) => p.toJson()).toList()));
    } catch (_) {}
  }

  // settle the batched off-chain tip tally. The tip is SPLIT immutably on-chain: the creator gets
  // the rest, the relay that served the media gets split%, and whoever reposted it gets rsplit%.
  // ON-DEVICE SIGNED: the app computes the split, signs each send block locally, and the node only
  // adds PoW + broadcasts. The seed never leaves the phone.
  static Future<Map<String, dynamic>?> settle(String to, String amount,
      {int split = 10, int rsplit = 5, String media = '', String reposter = ''}) async {
    final w = gWallet;
    if (w == null) return null;
    try {
      final amtRaw = _xnoToRaw(amount);
      final st = await accountState(w.account);
      if (st == null || st['opened'] != true) return {'ok': false, 'error': 'wallet empty'};
      if (amtRaw <= BigInt.zero || BigInt.parse('${st['balance']}') < amtRaw) {
        return {'ok': false, 'error': 'insufficient balance'};
      }
      // find a relay that serves this post's media, to reward it (public read via the node)
      String relay = '';
      if (media.isNotEmpty) {
        try {
          final mr = await http.get(Uri.parse('$kBase/api/media_relay?cid=$media'));
          relay = (jsonDecode(mr.body)['account'] as String?) ?? '';
        } catch (_) {}
      }
      final sp = split.clamp(0, 50), rp = rsplit.clamp(0, 50);
      final relayRaw = relay.isNotEmpty ? amtRaw * BigInt.from(sp) ~/ BigInt.from(100) : BigInt.zero;
      final reposterRaw = reposter.isNotEmpty ? amtRaw * BigInt.from(rp) ~/ BigInt.from(100) : BigInt.zero;
      final creatorRaw = amtRaw - relayRaw - reposterRaw;
      // Split legs, creator first so a partial chain still pays the creator. All legs are sent as ONE
      // locally-chained sequence (see _sendChain) — the old code re-read the frontier over RPC between
      // legs, so the relay/reposter block was signed on a not-yet-observed frontier and silently
      // rejected as a fork. Every follow-on leg was dropped and the failure never surfaced.
      final legs = <Map<String, dynamic>>[
        {'role': 'creator', 'to': to, 'raw': creatorRaw},
        if (relay.isNotEmpty && relayRaw > BigInt.zero) {'role': 'relay', 'to': relay, 'raw': relayRaw},
        if (reposter.isNotEmpty && reposterRaw > BigInt.zero)
          {'role': 'reposter', 'to': reposter, 'raw': reposterRaw},
      ];
      final results = await _sendChain(w, legs);
      final creatorLeg = results.firstWhere((r) => r['role'] == 'creator', orElse: () => {'ok': false});
      final paidRaw = results
          .where((r) => r['ok'] == true)
          .fold<BigInt>(BigInt.zero, (a, r) => a + (r['raw'] as BigInt));
      return {
        // "settled" means the CREATOR was actually paid — not merely that the tally was cleared.
        'ok': creatorLeg['ok'] == true,
        'to': to, 'amount': amount, 'hash': creatorLeg['hash'],
        'legs': results
            .map((r) => {
                  'role': r['role'], 'to': r['to'],
                  'xno': (r['raw'] as BigInt) / BigInt.from(10).pow(30),
                  'ok': r['ok'] == true, 'hash': r['hash'], 'error': r['error'],
                })
            .toList(),
        'paid_xno': paidRaw / BigInt.from(10).pow(30),
        'split_pct': sp, 'repost_pct': rp, 'work_delegated': true,
      };
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  // pay-to-pin: keep a post's content alive on the independent public relays. For each relay, send a
  // little XNO to its account (on-device signed), then hand the payment hash to the relay so it protects
  // the CID from eviction for a span proportional to what was paid. The seed never leaves the phone.
  static Future<List<Map<String, dynamic>>> pinTargets() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/pin_targets')).timeout(const Duration(seconds: 20));
      return (((jsonDecode(r.body))['relays'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  // reservedXno: XNO already earmarked for un-settled tips. Subtracted from the balance so a pin
  // can't spend what a creator was already promised (cross-path reservation — see _guardTip).
  static Future<Map<String, dynamic>?> pin(String cid, double xno, {double reservedXno = 0}) async {
    final w = gWallet;
    if (w == null || cid.isEmpty) return {'ok': false, 'error': 'no content to pin'};
    try {
      final targets = await pinTargets();
      if (targets.isEmpty) return {'ok': false, 'error': 'no public relay to pin on yet'};
      final raw = _xnoToRaw(xno.toStringAsFixed(6));
      final st = await accountState(w.account);
      if (st == null || st['opened'] != true) return {'ok': false, 'error': 'wallet empty'};
      final need = raw * BigInt.from(targets.length);
      final free = BigInt.parse('${st['balance']}') - _xnoToRaw(reservedXno.toStringAsFixed(6));
      if (free < need) {
        return {'ok': false, 'error': reservedXno > 1e-9
            ? 'need ${(xno * targets.length).toStringAsFixed(3)} XNO free — ${reservedXno.toStringAsFixed(2)} is reserved for pending tips'
            : 'need ${(xno * targets.length).toStringAsFixed(3)} XNO for ${targets.length} relay(s)'};
      }
      int pinned = 0;
      double days = 0;
      String? err;
      for (final t in targets) {
        final payhash = await _sendRaw(w, '${t['account']}', raw);   // pay this relay, on-device signed
        if (payhash == null) { err ??= 'payment failed'; continue; }
        try {
          final r = await http.post(Uri.parse('${t['url']}/pin'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'cid': cid, 'payhash': payhash})).timeout(const Duration(seconds: 30));
          final j = jsonDecode(r.body);
          if (j['ok'] == true) { pinned++; days = (j['days'] ?? days).toDouble(); }
          else { err ??= (j['error'] ?? 'pin refused').toString(); }
        } catch (e) { err ??= '$e'; }
      }
      return {'ok': pinned > 0, 'pinned': pinned, 'relays': targets.length, 'days': days, 'error': err};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  // ---- on-device Nano money primitives (shared by send / settle / receive / rep-change) ----

  // XNO decimal string -> raw (×10^30), exact via BigInt (a double would overflow int64 at ~1e28).
  static BigInt _xnoToRaw(String amount) {
    final parts = amount.trim().split('.');
    final whole = parts[0].isEmpty ? '0' : parts[0];
    var frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > 30) frac = frac.substring(0, 30);
    frac = frac.padRight(30, '0');
    return BigInt.parse(whole) * BigInt.from(10).pow(30) + BigInt.parse(frac);
  }

  // read an account's ledger state — a public RPC read (no seed): {opened, frontier, balance, representative}
  static Future<Map<String, dynamic>?> accountState(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/account_state?account=$account'));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // broadcast an app-signed state block; the node adds delegated PoW and processes it (no seed)
  static Future<Map<String, dynamic>?> blockProcess(Map<String, dynamic> block, String subtype) async {
    // Route delegated PoW to a fast (work:local) node when we have one, then fall back to kBase. A
    // freshly-signed block is idempotent to re-`process` (same hash), so a fallback can't double-spend —
    // it just lands the block a slept/unreachable work node couldn't. Skips duplicates in the list.
    final bases = <String>[if (kWorkBase != null) kWorkBase!, kBase].toSet().toList();
    final body = jsonEncode({'block': block, 'subtype': subtype});
    Map<String, dynamic>? last;
    for (final base in bases) {
      try {
        final r = await http.post(Uri.parse('$base/api/block_process'),
            headers: {'Content-Type': 'application/json'}, body: body);
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        if (d['ok'] == true) return d;   // landed — done
        last = d;                        // a ledger error (fork/old block); retrying elsewhere is harmless
      } catch (_) {
        // work node unreachable (home nodes sleep) — fall through to the next base
      }
    }
    return last;
  }

  // one on-device send of a raw amount to an address; returns the block hash (null on failure)
  static Future<String?> _sendRaw(NanoWallet w, String toAddr, BigInt raw) async {
    final st = await accountState(w.account);
    if (st == null || st['opened'] != true) return null;
    final bal = BigInt.parse('${st['balance']}');
    if (raw <= BigInt.zero || bal < raw) return null;
    final block = w.signStateBlock(
        previous: '${st['frontier']}', representative: '${st['representative']}',
        balance: bal - raw, link: w.pubOf(toAddr));
    final r = await blockProcess(block, 'send');
    if (r?['ok'] == true) return r?['hash'] as String?;
    return null;
  }

  // Send several amounts from ONE account as a single locally-chained sequence. Each block uses the
  // PREVIOUS leg's own block hash as its `previous` (the node returns it on process), so a follow-on
  // leg never re-reads a frontier the just-broadcast block may not be reflected in yet — that stale
  // RPC read is exactly what made the relay/reposter leg fork and get silently dropped. Advances the
  // local balance/frontier only on a confirmed broadcast; stops the chain at the first failure so no
  // later leg is stranded on an unknown `previous`. Returns one result row per leg (never throws).
  static Future<List<Map<String, dynamic>>> _sendChain(
      NanoWallet w, List<Map<String, dynamic>> legs) async {
    final out = <Map<String, dynamic>>[];
    final st = await accountState(w.account);
    if (st == null || st['opened'] != true) {
      for (final l in legs) out.add({...l, 'ok': false, 'hash': null, 'error': 'wallet empty'});
      return out;
    }
    var prev = '${st['frontier']}';
    var bal = BigInt.parse('${st['balance']}');
    final rep = '${st['representative']}';
    var broken = false;
    for (final l in legs) {
      final to = l['to'] as String;
      final raw = l['raw'] as BigInt;
      if (broken) { out.add({...l, 'ok': false, 'hash': null, 'error': 'skipped (prior leg failed)'}); continue; }
      if (raw <= BigInt.zero) { out.add({...l, 'ok': false, 'hash': null, 'error': 'zero amount'}); continue; }
      if (bal < raw) { out.add({...l, 'ok': false, 'hash': null, 'error': 'insufficient balance'}); broken = true; continue; }
      final newBal = bal - raw;
      final block = w.signStateBlock(previous: prev, representative: rep, balance: newBal, link: w.pubOf(to));
      final r = await blockProcess(block, 'send');
      final ok = r?['ok'] == true;
      final hash = r?['hash'] as String?;
      out.add({...l, 'ok': ok, 'hash': ok ? hash : null, 'error': ok ? null : (r?['error']?.toString() ?? 'broadcast failed')});
      if (ok && hash != null) { prev = hash; bal = newBal; } else { broken = true; }
    }
    return out;
  }

  // identity: the app already holds the account (on-device key); the node only reads the balance.
  static Future<Map<String, dynamic>> me() async {
    final acct = gWallet?.account ?? '';
    final r = await http.get(Uri.parse('$kBase/api/me?account=$acct'));
    return jsonDecode(r.body);
  }

  // media (thumbnails/movies) by CID via the engine: IPFS origin OR relay cache → survives origin loss
  static Future<Uint8List?> media(String cid) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/media?cid=$cid'));
      final b64 = jsonDecode(r.body)['b64'];
      return b64 == null ? null : base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  // Fetch a RELEASE APK (tens of MB) and verify its hash. Order of preference:
  //  1) `mirrorUrl` from the record — a plain BINARY download from a CDN (e.g. the repo's raw host). This
  //     is ~half the bytes of the base64 relay path and streams reliably; a relay serving 27 MB of base64
  //     JSON from a 512 MB box to a phone is what made the in-app download spin-and-fail.
  //  2) DIRECT from the public relays (base64) — the censorship-resistant fallback if the mirror is down.
  //  3) the node's /api/media — last resort.
  // Trust is the SHA-256, not the host: whatever a source returns is accepted only if it matches the hash
  // in the SIGNED release record, so a mirror is exactly that — a mirror, never a root of trust.
  static Future<Uint8List?> fetchReleaseApk(String cid, String wantSha, {String? mirrorUrl}) async {
    if (mirrorUrl != null && mirrorUrl.isNotEmpty) {
      try {
        final r = await http.get(Uri.parse(mirrorUrl)).timeout(const Duration(seconds: 120));
        if (r.statusCode == 200 && r.bodyBytes.isNotEmpty &&
            sha256.convert(r.bodyBytes).toString() == wantSha) return r.bodyBytes;
      } catch (_) {}
    }
    for (final url in await relayUrls()) {                // every discovered PUBLIC relay (not deduped by account)
      try {
        final r = await http.get(Uri.parse('$url/blob?cid=$cid')).timeout(const Duration(seconds: 120));
        final b64 = jsonDecode(r.body)['b64'];
        if (b64 is! String || b64.isEmpty) continue;
        final bytes = base64Decode(b64);
        if (sha256.convert(bytes).toString() == wantSha) return bytes;   // exact bytes the signed record names
      } catch (_) {}
    }
    // last resort: the node's media path (works if the node happens to hold the blob locally)
    final viaNode = await media(cid);
    if (viaNode != null && sha256.convert(viaNode).toString() == wantSha) return viaNode;
    return null;
  }

  // the discovered PUBLIC relay origins (https), from the on-chain relay directory — NOT deduped by pin
  // account (pinTargets is), so a peer relay that actually holds a big blob is reachable directly.
  static Future<List<String>> relayUrls() async {
    final out = <String>[];
    final relays = <String>[];
    try {
      final r = await http.get(Uri.parse('$kBase/api/relaydir')).timeout(const Duration(seconds: 25));
      final d = jsonDecode(r.body);
      final list = (d['relays'] as List?) ?? (d['active'] as List?) ?? const [];
      relays.addAll(list.map((e) => '$e').where((u) => u.startsWith('https')));
      out.addAll(relays);
    } catch (_) {}
    // A hub-fronted NAT'd node is off-ledger, so it never appears in /api/relaydir. Add its reach urls
    // two ways: (1) a private node we hold the rendezvous secret for; (2) PUBLIC nodes — auto-discovered
    // by asking every hub we know (the relays above + kBase) "who's attached?" (no secret, no config).
    // Both are plain <hub>/r/<token> urls — the node's own IP is never exposed anywhere.
    out.addAll(MeshReach.reachBases());
    final hubs = [...relays, kBase];
    if (MeshReach.discovered.isEmpty) {
      await MeshReach.autoDiscoverFrom(hubs);        // first read: populate before we return
    } else {
      MeshReach.autoDiscoverFrom(hubs);              // warm cache: refresh in the background
    }
    out.addAll(MeshReach.discovered);
    return out;
  }

  // (Api.setWallet removed — the seed never leaves the device; there is no /api/wallet anymore.)

  // the issuer can keep their own post VISIBLE past the head TTL: republish signs the head with an
  // expiry at least this far out (epoch s). Set when you pin your own post; persisted per account.
  static int headKeepUntil = 0;

  // issuer head-extension: keep our head (and thus our posts) visible until `untilEpoch`, even offline.
  // Only the author can do this — the head is signed with their key.
  static Future<void> extendHead(String account, int untilEpoch) async {
    if (untilEpoch <= headKeepUntil) return;
    headKeepUntil = untilEpoch;
    await HeadKeep.set(account, untilEpoch);
    await republish();   // push a head signed with the long expiry NOW, so it survives the app closing
  }

  // republish our head so it stays live past its TTL and reaches newly-joined relays.
  // ON-DEVICE: fetch our current head (seq+cid), re-sign it with a fresh expiry locally, and push it
  // via the same submit path a post uses. The seed never leaves the device.
  static Future<void> republish() async {
    final w = gWallet;
    if (w == null) return;
    try {
      final hr = await http.get(Uri.parse('$kBase/api/head?account=${w.account}'));
      final head = (jsonDecode(hr.body)['head'] as Map?)?.cast<String, dynamic>();
      if (head == null) return;                            // nothing posted yet — nothing to refresh
      final seq = head['seq'] as int, cid = '${head['cid']}';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expires = math.max(now + kHeadTtl, headKeepUntil);   // honour an issuer head-extension
      final hs = w.signMsg(w.headMsg(seq, cid, expires));
      await http.post(Uri.parse('$kBase/api/post_submit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'author': w.account, 'handle': '${head['handle'] ?? 'you.xno'}',
                            'seq': seq, 'cid': cid, 'expires': expires, 'sig': hs['sig'], 'pub': hs['pub']}));
    } catch (_) {}
  }

  // supporter-mode work: propagate signed heads across the relay mesh (backfill laggards)
  static Future<Map<String, dynamic>?> gossip() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/gossip'));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  // supporter-mode work: pin content to relays so it survives loss of the origin host
  static Future<Map<String, dynamic>?> pinContent() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/pincontent'));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> engagement() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/engagement'));
      return (jsonDecode(r.body)['engage'] as Map?)?.cast<String, dynamic>() ?? {};
    } catch (_) {
      return {};
    }
  }

  // count an impression (view) for a post or comment cid — client dedups one per session
  static Future<void> view(String pid) async {
    try {
      await http.post(Uri.parse('$kBase/api/view'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'delta': '1'}));
    } catch (_) {}
  }

  // channel directory: [{account, display, bio, avatar, followers, online}]. A public read; no seed.
  static Future<List<Map<String, dynamic>>> channels() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/channels')).timeout(const Duration(seconds: 12));
      return (((jsonDecode(r.body))['channels'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return const [];
    }
  }

  // accounts online right now (heads refreshed within the presence window). A public read; no seed.
  static Future<Set<String>> presence() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/presence')).timeout(const Duration(seconds: 8));
      return (((jsonDecode(r.body))['online'] as List?) ?? const []).map((e) => '$e').toSet();
    } catch (_) {
      return const <String>{};
    }
  }

  static Future<void> like(String pid, int delta) => _engagePost('like', pid, delta);
  // A reshare earns a slice of every tip to the post, so it is SIGNED on-device (canon
  // reshare|account|post_id|ts). The relay verifies it before crediting the resharer — an unsigned
  // reshare can no longer name someone else's/your own account to skim tips.
  static Future<void> repost(String pid, int delta, String account) async {
    final w = gWallet;
    if (w == null) return; // seedless: no signer, no reshare
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.reshareMsg(pid, ts));
    try {
      await http.post(Uri.parse('$kBase/api/repost'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'delta': '$delta', 'account': w.account,
                            'ts': ts, 'sig': s['sig'], 'pub': s['pub']}));
    } catch (_) {}
  }
  static Future<void> _engagePost(String kind, String pid, int delta) async {
    try {
      await http.post(Uri.parse('$kBase/api/$kind'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'delta': '$delta'}));
    } catch (_) {}
  }

  // Without payhash+cid this is a DISPLAY counter, in the same class as likes and views: anyone can
  // bump it and nothing consequential depends on it. Sent AFTER settlement with the creator leg's
  // block hash, the relay verifies the payment on-chain and credits the media's stored value — which
  // decides what survives eviction, so it must be backed by money that actually moved (issue #5).
  static Future<void> tipstat(String pid, String raw, {String payhash = '', String cid = ''}) async {
    try {
      await http.post(Uri.parse('$kBase/api/tipstat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': pid, 'raw': raw,
            if (payhash.isNotEmpty && cid.isNotEmpty) 'payhash': payhash,
            if (payhash.isNotEmpty && cid.isNotEmpty) 'cid': cid,
          }));
    } catch (_) {}
  }

  // tell the content creator about a like / repost / tip / comment
  static Future<void> notifyPush(String to, String from, String kind, String text) async {
    try {
      await http.post(Uri.parse('$kBase/api/notify_push'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'to': to, 'from': from, 'kind': kind, 'text': text}));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> notify() async {
    final w = gWallet;
    if (w == null) return [];
    try {
      // key notifications by the UNIQUE account, not the shared 'you.xno' handle — otherwise every
      // user reads one common bucket and sees everyone else's tip/like alerts (issue: alerts predating
      // your own install). The relay routes by whatever string it's given, so the account rides the
      // existing 'handle' param end-to-end (no relay change needed).
      final r = await http.get(Uri.parse('$kBase/api/notify?account=${w.account}'));
      final d = jsonDecode(r.body);
      return ((d['notifs'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // A coordinated-event banner (network migration etc.). The node returns it ONLY when a valid,
  // publisher-signed, unexpired record is configured — so normal operation returns {active:false} and
  // the app shows nothing. Returns the banner text, or null.
  static Future<String?> announcement() async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/announcement'));
      final d = jsonDecode(r.body);
      if (d is Map && d['active'] == true) {
        final t = '${d['text'] ?? ''}'.trim();
        return t.isEmpty ? null : t;
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> supporter(bool on, String account) async {
    try {
      final r = await http.post(Uri.parse('$kBase/api/supporter'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'account': account,
            'on': on ? '1' : '0',
            'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
          }));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Labeler>> labels() async {
    final r = await http.get(Uri.parse('$kBase/api/labels'));
    final d = jsonDecode(r.body);
    final out = <Labeler>[];
    for (final le in (d['labelers'] as List? ?? [])) {
      final list = le['list'] ?? {};
      final flags = <String, Map<String, dynamic>>{};
      int lastTs = 0;
      for (final x in (list['labels'] as List? ?? [])) {
        final pid = x['post'];
        if (pid == null) continue;
        flags[pid] = {'verdict': x['verdict'], 'reason': x['reason'], 'ts': x['ts'] ?? 0, 'frac': x['frac']};
        final t = (x['ts'] ?? 0) as int;
        if (t > lastTs) lastTs = t;
      }
      out.add(Labeler(le['account'] ?? '', list['labeler'] ?? 'labeler',
          double.tryParse('${le['reputation']}') ?? 0, lastTs, flags));
    }
    return out;
  }

  // Publish a SIGNED community report — "report|account|postId|ts" signed on-device — to the relays.
  // cid (the post's media, if any) lets the relays penalise/take-down the content by the same score.
  static Future<Map<String, dynamic>?> report(String postId, String cid) async {
    final w = gWallet;
    if (w == null) return {'ok': false, 'error': 'no wallet'};
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final s = w.signMsg(w.reportMsg(postId, ts));
      final r = await http
          .post(Uri.parse('$kBase/api/report'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'post_id': postId, 'account': w.account, 'ts': ts,
                                'sig': s['sig'], 'pub': s['pub'], 'cid': cid}))
          .timeout(const Duration(seconds: 20));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  // Delete your OWN post: sign a delete event, the node rebuilds your thread WITHOUT it (new CID),
  // you sign the new head over that CID and submit it — same on-device two-step as posting, so the
  // node never touches your seed. The post drops from every relay's feed.
  static Future<bool> deletePost(String postId, String handle) async {
    final w = gWallet;
    if (w == null) return false;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ds = w.signMsg(w.deleteMsg(postId, ts));                 // 1) prove authorship of the delete
      final pr = await http
          .post(Uri.parse('$kBase/api/post_delete'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'account': w.account, 'post_id': postId, 'ts': ts,
                                'sig': ds['sig'], 'pub': ds['pub'], 'handle': handle}))
          .timeout(const Duration(seconds: 30));
      final d = jsonDecode(pr.body) as Map<String, dynamic>;
      final cid = d['cid'] as String?;
      if (cid == null) return false;
      final seq = d['seq'] as int, expires = d['expires'] as int;
      final hs = w.signMsg(w.headMsg(seq, cid, expires));            // 2) sign the new head over the new thread
      final sub = await http
          .post(Uri.parse('$kBase/api/post_submit'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'author': w.account, 'handle': handle, 'seq': seq, 'cid': cid,
                                'expires': expires, 'sig': hs['sig'], 'pub': hs['pub']}))
          .timeout(const Duration(seconds: 30));
      return (jsonDecode(sub.body)['ok'] == true);
    } catch (_) {
      return false;
    }
  }

  // Edit your own post. Same two-step as delete: (1) sign the edit event proving authorship + the new
  // text; the node replaces that post's text in your thread and returns the new CID/seq; (2) sign the
  // new head over that CID and submit. The seed never leaves the device; the head signature is what
  // authorises the changed content.
  static Future<bool> editPost(String postId, String newText, String handle) async {
    final w = gWallet;
    if (w == null) return false;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final es = w.signMsg(w.editPostMsg(postId, newText, ts));
      final pr = await http
          .post(Uri.parse('$kBase/api/post_edit'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'account': w.account, 'post_id': postId, 'text': newText, 'ts': ts,
                                'sig': es['sig'], 'pub': es['pub'], 'handle': handle}))
          .timeout(const Duration(seconds: 30));
      final d = jsonDecode(pr.body) as Map<String, dynamic>;
      final cid = d['cid'] as String?;
      if (cid == null) return false;
      final seq = d['seq'] as int, expires = d['expires'] as int;
      final hs = w.signMsg(w.headMsg(seq, cid, expires));
      final sub = await http
          .post(Uri.parse('$kBase/api/post_submit'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'author': w.account, 'handle': handle, 'seq': seq, 'cid': cid,
                                'expires': expires, 'sig': hs['sig'], 'pub': hs['pub']}))
          .timeout(const Duration(seconds: 30));
      return (jsonDecode(sub.body)['ok'] == true);
    } catch (_) {
      return false;
    }
  }

  // returns the new post's id (empty string on failure) so a thread can chain reply_to.
  // ON-DEVICE SIGNED, two-step: (1) sign the post event locally + POST it to /api/post_prepare — the
  // node assembles the thread, pins it, and returns the content CID + head seq; (2) sign the head
  // "account|seq|cid|expires" locally + POST to /api/post_submit — the node verifies + gossips it.
  // The seed never leaves the device; the node only assembles content and relays signed records.
  static Future<String> post(String text, {String handle = 'you.xno', String media = '', String mediaKind = '', String quote = '', String replyTo = '', String title = '', String poll = '', int? ts, NanoWallet? signer}) async {
    final w = signer ?? gWallet;   // `signer` lets a post be authored by a channel identity, not the user
    if (w == null) return '';
    ts ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;   // a flushed queued post keeps its compose time
    final mk = (mediaKind == 'photo' || mediaKind == 'movie') ? mediaKind : 'movie';
    final kind = poll.isNotEmpty ? 'poll' : (title.isNotEmpty ? 'article' : (media.isNotEmpty ? mk : 'post'));
    final id = 'u$ts';
    final pollOpts = poll.isEmpty ? <String>[] : poll.split('|').where((o) => o.trim().isNotEmpty).toList();
    final es = w.signMsg(w.postEventMsg(handle, kind, text, ts));   // sign the post event on-device
    try {
      // 1) prepare — node verifies the event, builds + pins the thread, returns the CID/seq to sign.
      // A timeout matters for the OFFLINE OUTBOX: a reconnect attempt fired while the link is still
      // validating must FAIL FAST so the retry can re-send once the network is really up, instead of
      // hanging on a dead socket for a minute.
      const t = Duration(seconds: 15);
      final pr = await http.post(Uri.parse('$kBase/api/post_prepare'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id': id, 'handle': handle, 'account': w.account, 'kind': kind, 'text': text,
                            'ts': ts, 'media': media, 'title': title, 'quote': quote, 'reply_to': replyTo,
                            'poll': pollOpts, 'sig': es['sig'], 'pub': es['pub']})).timeout(t);
      final pj = jsonDecode(pr.body);
      if (pj['ok'] != true) return '';
      final seq = pj['seq'] as int;
      final expires = math.max(pj['expires'] as int, headKeepUntil);   // don't drop below an issuer head-extension
      final cid = pj['cid'] as String;
      // 2) submit — sign the head over the returned CID on-device, node verifies + gossips
      final hs = w.signMsg(w.headMsg(seq, cid, expires));
      final sr = await http.post(Uri.parse('$kBase/api/post_submit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'author': w.account, 'handle': handle, 'seq': seq, 'cid': cid,
                            'expires': expires, 'sig': hs['sig'], 'pub': hs['pub']})).timeout(t);
      return jsonDecode(sr.body)['ok'] == true ? id : '';
    } catch (_) {
      return '';
    }
  }

  // wallet: send Nano to any address (mainnet, feeless, PoW delegated).
  // ON-DEVICE SIGNED: builds + signs the send block locally; the node only adds PoW + broadcasts.
  // reservedXno: XNO earmarked for un-settled tips. A discretionary send subtracts it so it can't
  // spend the creators' promised pay (cross-path reservation). The wallet-cap excess return passes 0.
  static Future<Map<String, dynamic>?> send(String to, String amount, {double reservedXno = 0}) async {
    final w = gWallet;
    if (w == null) return null;
    try {
      final amtRaw = _xnoToRaw(amount);
      if (reservedXno > 1e-9) {
        final st = await accountState(w.account);
        if (st == null || st['opened'] != true) return {'ok': false, 'to': to, 'amount': amount, 'error': 'wallet empty'};
        final free = BigInt.parse('${st['balance'] ?? '0'}') - _xnoToRaw(reservedXno.toStringAsFixed(6));
        if (free < amtRaw) {
          final freeXno = (free < BigInt.zero ? BigInt.zero : free) / BigInt.from(10).pow(30);
          return {'ok': false, 'to': to, 'amount': amount,
              'error': 'only ${freeXno.toStringAsFixed(3)} XNO free — ${reservedXno.toStringAsFixed(2)} reserved for pending tips'};
        }
      }
      final hash = await _sendRaw(w, to, amtRaw);
      if (hash != null) return {'ok': true, 'to': to, 'amount': amount, 'hash': hash};
      final st = await accountState(w.account);
      final bal = st == null ? BigInt.zero : BigInt.parse('${st['balance'] ?? '0'}');
      return {'ok': false, 'to': to, 'amount': amount,
              'error': (st?['opened'] != true) ? 'wallet empty' : (bal < amtRaw ? 'insufficient balance' : 'send failed')};
    } catch (e) {
      return {'ok': false, 'to': to, 'amount': amount, 'error': '$e'};
    }
  }

  // wallet: this account's on-chain transactions, newest first. The wallet showed a balance but
  // never how it got there, so a tip arriving was invisible unless you watched the number change.
  static Future<List<Map<String, dynamic>>> history({int count = 50}) async {
    final w = gWallet;
    if (w == null) return [];
    try {
      final r = await http.get(Uri.parse('$kBase/api/history?account=${w.account}&count=$count'))
          .timeout(const Duration(seconds: 30));
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      return ((d['history'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // wallet: claim any pending receivable blocks into the account.
  // ON-DEVICE SIGNED: each receive/open block is built + signed locally, sequentially.
  // Auto-receive is how every real Nano wallet behaves — Nault ships "Receive Method: automatic" as
  // the default and keeps manual mode mainly for hardware wallets, where each claim needs an on-device
  // confirmation. Nano's receivable model is an implementation detail; a user should not have to learn
  // it to see their own money.
  //
  // MIN RECEIVE exists for the same reason Nault has it: Nano gets dusted. Auto-claiming every 1-raw
  // spam send would mint a receive block — and burn real proof-of-work on our node — for each one.
  // The floor sits far below a real tip (the default tip is 0.01 XNO) so nothing a person sends is
  // ever ignored.
  static final BigInt minReceiveRaw = BigInt.from(10).pow(24);   // 0.000001 XNO, as Nault defaults
  static bool _receiving = false;                                // no two claims over one frontier

  static Future<Map<String, dynamic>?> receive() async {
    final w = gWallet;
    if (w == null) return null;
    // Overlapping claims build on the SAME frontier, so the second one forks and is rejected. That is
    // reachable by hand today: the button stays live for the whole ~7s round trip, so a double tap
    // starts a second pass over the same list.
    if (_receiving) return {'ok': false, 'busy': true, 'received': 0};
    _receiving = true;
    int received = 0, skipped = 0;
    try {
      final rc = await http.get(Uri.parse('$kBase/api/receivables?account=${w.account}'));
      final list = ((jsonDecode(rc.body)['receivables'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final item in list) {
        final srcHash = '${item['hash']}';                 // the send block we're receiving
        final amt = BigInt.parse('${item['amount']}');
        if (amt < minReceiveRaw) { skipped++; continue; }  // dust: not worth a block and its PoW
        final st = await accountState(w.account);
        if (st == null) break;
        final opened = st['opened'] == true;
        final prev = opened ? '${st['frontier']}' : '0' * 64;
        final rep = opened ? '${st['representative']}' : w.account;   // self-represent on open
        final bal = opened ? BigInt.parse('${st['balance']}') : BigInt.zero;
        final block = w.signStateBlock(previous: prev, representative: rep, balance: bal + amt, link: srcHash);
        final r = await blockProcess(block, opened ? 'receive' : 'open');
        if (r?['ok'] == true) received++;
      }
    } catch (_) {
      // fall through: report what DID land rather than losing the count on a late failure
    } finally {
      _receiving = false;
    }
    final st = await accountState(w.account);
    return {'ok': true, 'received': received, 'skipped': skipped,
            'balance': st?['balance'] ?? '0'};
  }

  /// How much is claimable right now, ignoring dust. Drives the "incoming" hint in the wallet, so a
  /// balance can never silently understate what is already yours.
  static Future<BigInt> receivableTotal() async {
    final w = gWallet;
    if (w == null) return BigInt.zero;
    try {
      final rc = await http.get(Uri.parse('$kBase/api/receivables?account=${w.account}'))
          .timeout(const Duration(seconds: 12));
      final list = ((jsonDecode(rc.body)['receivables'] as List?) ?? []).cast<Map<String, dynamic>>();
      var t = BigInt.zero;
      for (final i in list) {
        final a = BigInt.tryParse('${i['amount']}') ?? BigInt.zero;
        if (a >= minReceiveRaw) t += a;
      }
      return t;
    } catch (_) {
      return BigInt.zero;
    }
  }

  // wallet: read the account's current Nano representative (public RPC read)
  static Future<Map<String, dynamic>?> repGet() async {
    final w = gWallet;
    if (w == null) return null;
    final st = await accountState(w.account);
    if (st == null) return null;
    final rep = st['representative'] as String?;
    return {'ok': true, 'account': w.account, 'representative': rep, 'self': rep == w.account};
  }

  // wallet: change the representative (a change block — no value moves).
  // ON-DEVICE SIGNED: builds + signs the change block locally; the node only adds PoW + broadcasts.
  static Future<Map<String, dynamic>?> repSet(String rep) async {
    final w = gWallet;
    if (w == null) return null;
    try {
      w.pubOf(rep);                                        // validate the nano_ address shape
      final st = await accountState(w.account);
      if (st == null || st['opened'] != true) {
        return {'ok': false, 'error': 'account not opened yet — receive some XNO first'};
      }
      final bal = BigInt.parse('${st['balance']}');
      final block = w.signStateBlock(previous: '${st['frontier']}', representative: rep, balance: bal, link: '0' * 64);
      final r = await blockProcess(block, 'change');
      return {'ok': r?['ok'] == true, 'representative': rep, 'hash': r?['hash'], 'error': r?['error']};
    } catch (e) {
      return {'ok': false, 'representative': rep, 'error': '$e'};
    }
  }

  // portable follows: publish the signed follow-list to relays (survives a restore)
  // on-device signed: the app builds + signs the follow record; the node only verifies + relays.
  static Future<void> followsPub(Map<String, dynamic> rec) async {
    try {
      await http.post(Uri.parse('$kBase/api/follows_set'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(rec));
    } catch (_) {}
  }

  // polls: read the signed, per-account tally / cast a vote
  static Future<Map<String, dynamic>?> pollGet(String pollId) async {
    final acct = gWallet?.account ?? '';
    try {
      final r = await http.get(Uri.parse('$kBase/api/poll_get?poll=$pollId&account=$acct'));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  // on-device signed: the app signs the vote locally; the node only verifies + relays.
  static Future<void> pollVote(String pollId, int option) async {
    final w = gWallet;
    if (w == null) return;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.pollMsg(pollId, '$option', ts));
    try {
      await http.post(Uri.parse('$kBase/api/poll_vote'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'poll_id': pollId, 'account': w.account, 'option': option,
                            'ts': ts, 'sig': s['sig'], 'pub': s['pub']}));
    } catch (_) {}
  }

  // publish our SIGNED DM public-key record so peers can encrypt to us (idempotent; call on boot)
  static Future<void> dmKeyRegister() async {
    final w = gWallet;
    if (w == null) return;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.dmKeyMsg(ts, w.dmPub));
    // Advertise that this client can READ sealed-sender records, signed separately so an old verifier
    // ignores it and a new sender can trust it (a bare flag could be stripped to force a downgrade).
    final cs = w.signMsg(w.dmKeyCapsMsg(ts, NanoWallet.dmCaps));
    try {
      await http.post(Uri.parse('$kBase/api/dm_key_set'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'account': w.account, 'dm_pk': w.dmPub, 'ts': ts, 'sig': s['sig'], 'pub': s['pub'],
                            'caps': NanoWallet.dmCaps, 'caps_sig': cs['sig']}));
    } catch (_) {}
  }

  // fetch + verify a peer's DM public key + capabilities (the node validates BOTH signatures — the
  // dm_pk binding and the separate caps signature — so `caps` here is a claim the peer really made).
  static Future<Map<String, String>?> dmKeyInfo(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/dm_key_get?account=$account'));
      final j = jsonDecode(r.body);
      final pk = j['dm_pk'] as String?;
      if (pk == null) return null;
      return {'dm_pk': pk, 'caps': '${j['caps'] ?? ''}'};
    } catch (_) {
      return null;
    }
  }

  // Just the DM public key, for the paths where capabilities are irrelevant (authorship checks, etc.).
  static Future<String?> dmKeyGet(String account) async => (await dmKeyInfo(account))?['dm_pk'];

  // encrypted DMs: seal ON-DEVICE (NaCl crypto_box), relay only the ciphertext — the node never
  // sees plaintext or any secret.
  // An attachment is: seal the bytes to the peer, park the SEALED bytes in an ordinary blob, then send
  // a normal DM whose (also sealed) text carries the blob's cid. The relay stores a blob it cannot read
  // and a message it cannot read, and never learns the two belong together beyond what the recipient's
  // own fetch reveals. Marker goes on its own first line so a caption can follow it, and so a client
  // that predates attachments shows one odd line plus a readable caption rather than nothing at all.
  static const dmImgTag = 'xchat:img:';
  // A DISAPPEARING photo. Same sealed-blob path as a normal DM photo; the marker differs and carries the
  // view duration in seconds: `xchat:img1:<seconds>:<cid>`. An older client that doesn't know the marker
  // renders nothing rather than the raw line (it just doesn't get the ephemeral behaviour). Enforced on
  // the client, like every disappearing photo — the honest limit (not camera-proof) is stated in the UI.
  static const dmImgOnceTag = 'xchat:img1:';

  static Future<Map<String, dynamic>?> dmSendImage(String to, Uint8List bytes, String caption,
      {int? seconds}) async {
    final w = gWallet;
    if (w == null) return null;
    final peer = await dmKeyGet(to);
    if (peer == null) return {'ok': false, 'error': 'recipient has not enabled DMs yet'};
    final cid = await blobPut(w.dmSealBytes(peer, bytes));
    if (cid == null || cid.isEmpty) {
      return {'ok': false, 'error': 'could not store the image (${lastBlobErr ?? "no cid"})'};
    }
    final body = caption.trim();
    final marker = seconds != null ? '$dmImgOnceTag$seconds:$cid' : '$dmImgTag$cid';
    return dmSend(to, body.isEmpty ? marker : '$marker\n$body');
  }

  /// Fetch + decrypt a DM attachment. `peerPk` is the other party's DM key for this conversation —
  /// the same box opens messages in both directions, so this works for what you sent too.
  static Future<Uint8List?> dmImage(String cid, String peerPk) async {
    final w = gWallet;
    if (w == null) return null;
    try {
      final r = await http.get(Uri.parse('$kBase/api/media?cid=$cid')).timeout(const Duration(seconds: 45));
      final b64 = jsonDecode(r.body)['b64'];
      if (b64 == null) return null;
      return w.dmOpenBytes(peerPk, base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  // ---- groups ----
  // Seal the text ONCE, park the sealed bytes in an ordinary blob, then send each member a normal DM
  // carrying the group id, that blob's cid and the key. The relay stores one blob it cannot read and
  // N tiny messages it cannot read; nothing in the delivery path knows groups exist.
  //
  // Sends to each member INDEPENDENTLY and reports how many landed, rather than failing the whole
  // send on one bad recipient. A group where one person has not enabled DMs must still work for
  // everyone else — the alternative is a group that silently cannot be used and does not say why.
  static Future<Map<String, dynamic>> groupSend(
      String gid, String name, List<String> members, String text) async {
    final w = gWallet;
    if (w == null) return {'ok': false, 'error': 'no wallet'};
    final sealed = w.groupContentSeal(Uint8List.fromList(utf8.encode(text)));
    final cid = await blobPut(sealed.ct);
    if (cid == null || cid.isEmpty) {
      return {'ok': false, 'error': 'could not store the message (${lastBlobErr ?? "no cid"})'};
    }
    final env = GroupMsg(gid: gid, name: name, cid: cid, key: sealed.key, members: members).encode();
    var sent = 0;
    final failed = <String>[];
    // Everyone including ourselves: the sender re-reads their own history off a relay like anyone
    // else, so skipping self loses your own messages on a reinstall.
    for (final m in members) {
      final r = await dmSend(m, env);
      if (r != null && r['ok'] == true) {
        sent++;
      } else {
        failed.add(m);
      }
    }
    return {
      'ok': sent > 0,
      'sent': sent,
      'of': members.length,
      'failed': failed,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'error': sent == 0 ? 'nobody in this group could be reached' : null,
    };
  }

  /// Fetch and open a group message's content. The key came in our own envelope, so this needs no
  /// peer key and works identically for messages we sent and messages we received.
  static Future<String?> groupText(String cid, String key) async {
    final w = gWallet;
    if (w == null) return null;
    try {
      final r = await http.get(Uri.parse('$kBase/api/media?cid=$cid'))
          .timeout(const Duration(seconds: 30));
      final b64 = jsonDecode(r.body)['b64'];
      if (b64 == null) return null;
      final b = w.groupContentOpen(key, base64Decode(b64));
      return b == null ? null : utf8.decode(b);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> dmSend(String to, String text) async {
    final w = gWallet;
    if (w == null) return null;
    final info = await dmKeyInfo(to);
    if (info == null) return {'ok': false, 'error': 'recipient has not enabled DMs yet'};
    final peer = info['dm_pk']!;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Send sealed ONLY to a recipient who has advertised (with a signature) that it can read the format.
    // Otherwise fall back to v1, so an old install never receives a record it cannot open — the format
    // is safe by construction, not by flag day.
    final sealed = (info['caps'] ?? '').contains(NanoWallet.dmCaps);
    final Map<String, dynamic> record;
    Map<String, dynamic>? selfRecord;   // sealed-sender only: a copy addressed to us, for device sync
    final String storeKey;
    if (sealed) {
      // SEALED SENDER: the relay never learns WE sent this. `to` stays visible (the recipient must be
      // addressable to pull their own mailbox); `from`/`from_pk`/`to_pk` are gone. `mid` is a random id
      // so two sealed records in the same second still dedup now that the relay cannot key on `from`.
      final env = w.dmSealSealed(peer, text);
      record = {'v': 2, 'to': to, 'ts': ts, 'mid': randHex(16), 'epk': env['epk'], 'ct': env['ct']};
      // SELF-COPY: also send a sealed record addressed to OURSELF so this sent message survives a seed
      // restore or reaches a second device — a normal v2 record hides `from` and is addressed to the
      // peer, so our own mailbox read never returns it. Store the local copy under the SELF-COPY's ct so
      // the later poll that fetches it dedups (via DmStore.get) instead of showing the message twice.
      final self = w.dmSealSealedSelf(to, peer, text);
      selfRecord = {'v': 2, 'to': w.account, 'ts': ts, 'mid': randHex(16), 'epk': self['epk'], 'ct': self['ct']};
      storeKey = '${self['ct']}';
    } else {
      final ct = w.dmSeal(peer, text);
      record = {'to': to, 'from': w.account, 'from_pk': w.dmPub, 'to_pk': peer, 'ct': ct, 'ts': ts};
      storeKey = ct;
    }
    try {
      final r = await http.post(Uri.parse('$kBase/api/dm_send'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(record));
      final ok = jsonDecode(r.body)['ok'] == true;
      if (ok) {
        if (sealed) {
          // Fire the self-copy to the network (best-effort — the local store below still holds it on this
          // device if the mirror send fails; only cross-device sync depends on it landing).
          try {
            await http.post(Uri.parse('$kBase/api/dm_send'),
                headers: {'Content-Type': 'application/json'}, body: jsonEncode(selfRecord));
          } catch (_) {}
        }
        // Persist our own copy locally NOW so the send confirms from the STORE immediately, instead of
        // waiting to read it back off a relay. That read-back is fragile: it can be slow, blind-only, or
        // — for a sealed self-copy — sitting on our node's own co-located relay, which the blind path
        // cannot address. When it fails, the optimistic bubble hangs on the pending clock forever
        // ("can't send"). The store is the source of truth; _load() clears _pending as soon as the sent
        // message appears here, no round-trip required. Keyed by the same ct the later poll fetches, so
        // the network copy dedups (DmStore.get) instead of double-rendering.
        //
        // This now runs for v1 sends too: previously only sealed sends persisted here, so a v1 send's
        // confirmation depended entirely on the relay echoing it back and hung when that path broke.
        await DmStore.load(w);
        DmStore.put(storeKey, text, ts, from: w.account, outgoing: true, peer: to, peerPk: peer);
        await DmStore.flush(w);
      }
      return {'ok': ok, 'ts': ts};
    } catch (_) {
      return {'ok': false, 'error': 'send failed'};
    }
  }

  // encrypted DMs: fetch RAW ciphertext records, DECRYPT ON-DEVICE, group into conversations
  static int _dmPoll = 0;   // drives the periodic full sweep in dmInbox
  static Future<List<Map<String, dynamic>>> dmInbox() async {
    final w = gWallet;
    if (w == null) return [];
    // Load the store BEFORE the fetch and build the result FROM it afterwards — on success AND on
    // failure. The store is the source of truth: every message we have ever decrypted, persisted and
    // sealed to our own key. The network poll only ADDS newly-arrived ciphertext to it; it can never
    // be the thing that decides what is shown.
    //
    // Returning [] on a slow/failed poll — which this used to do in the catch below — is what made
    // DMs flicker: an empty result wiped the on-screen thread, and the next good poll restored it, so
    // the user watched messages vanish and reappear. The 12s timeout added to stop DMs hanging is
    // exactly what made a failed poll common enough to see. A poll that fetched nothing must SHOW
    // nothing new, not show nothing at all.
    await DmStore.load(w);          // decrypt-once cache; no-op after the first call; never throws
    try {
      // INCREMENTAL FETCH. The store holds everything already read, so a poll only needs ciphertext
      // that is NEW. Two safeguards, because `since` on its own is not correct:
      //
      //   OVERLAP — relays gossip, so a message can reach the node AFTER one with a later timestamp.
      //   Asking from exactly our newest ts would skip it permanently. We ask from newest minus 10min.
      //
      //   FULL SWEEP every 10th poll (~1 min in an open thread) — the backstop for anything later
      //   than the overlap, and for a message evicted and re-gossiped. The feed poll does the same
      //   thing for the same reason: a missing message is worse than a wasted request.
      final newest = DmStore.newestTs;
      final full = (_dmPoll++ % 10 == 0) || newest == 0;
      final since = full ? 0 : (newest - 600).clamp(0, newest);
      // Fetch the new ciphertext. Prefer a BLIND read (sealed to a ledger-anchored relay, forwarded by
      // the node without seeing which mailbox) so the node cannot tie our IP to our account; fall back
      // to the ordinary signed read whenever a blind one is unavailable — a privacy upgrade must never
      // cost a delivered message. Either way the decrypt loop below is identical. The full sweep reads
      // EVERY eligible relay (completeness); incremental polls read one (speed).
      final dms = await _dmFetchRaw(w, since, full);
      // A sealed (v2) record hides its sender, so authorship is proven by opening the INNER seal under
      // the sender's LEDGER-published dm_pk. Resolve each `from` to that key at most once per sweep.
      final Map<String, String?> pkCache = {};
      for (final m in dms) {
        // Already-read messages come from the store; only genuinely NEW ciphertext is decrypted.
        // Keyed by ciphertext, which is safe HERE (unlike inside dmOpen) because this loop has
        // already established the message is addressed to us — a ciphertext that is not ours never
        // reaches put(), so it can never be served from get().
        final ct = '${m['ct']}';
        if (ct.isEmpty || DmStore.get(ct) != null) continue;   // already held — nothing to decrypt
        if (m['v'] == 2 || m['v'] == '2') {
          // SEALED SENDER. The relay only ever saw an ephemeral key; the true identity is inside the
          // outer seal. Open the outer with our dm key × the ephemeral key.
          final outer = w.dmOpenSealedOuter('${m['epk']}', ct);
          if (outer == null) continue;                    // outer seal is not addressed to us
          final from = '${outer['f']}', claimedPk = '${outer['k']}', inner = '${outer['i']}';
          if (from.isEmpty || claimedPk.isEmpty || inner.isEmpty) continue;
          // Authorship check. A forger can put any `from` with their OWN key; the claim is only real if
          // that key IS the sender's ledger-published dm_pk (which the node validates by signature).
          // Resolve it and require an exact match, THEN open the inner under it — opening is the MAC
          // proof that whoever wrote this held that key. Either test failing = a forged sender, dropped.
          if (!pkCache.containsKey(from)) pkCache[from] = await dmKeyGet(from);
          final realPk = pkCache[from];
          if (realPk == null || realPk != claimedPk) continue;
          final plain = w.dmOpen(realPk, inner);
          if (plain == null) continue;
          // SELF-COPY: a message WE sent, mirrored to our own mailbox so it syncs to a restored/second
          // device. It carries the real recipient in `p`/`pk`; store it as OUTGOING to that peer rather
          // than as an incoming self-DM. (Only we can have produced its inner, so `from == account` here
          // is authenticated by the MAC, not just claimed.)
          final selfPeer = outer['p'];
          if (selfPeer is String && selfPeer.isNotEmpty && from == w.account) {
            DmStore.put(ct, plain, (m['ts'] ?? 0) as int,
                from: w.account, outgoing: true, peer: selfPeer, peerPk: '${outer['pk']}');
          } else {
            DmStore.put(ct, plain, (m['ts'] ?? 0) as int,
                from: from, outgoing: false, peer: from, peerPk: realPk);
          }
          continue;
        }
        // LEGACY (v1): sender/recipient identity and keys are on the record in the clear.
        final outgoing = m['from'] == w.account;
        final peerAcc = '${outgoing ? m['to'] : m['from']}';
        final peerPk = '${outgoing ? m['to_pk'] : m['from_pk']}';
        final plain = w.dmOpen(peerPk, ct);               // decrypts locally; null if not ours
        if (plain == null) continue;
        DmStore.put(ct, plain, (m['ts'] ?? 0) as int,
            from: '${m['from']}', outgoing: outgoing, peer: peerAcc, peerPk: peerPk);
      }
      await DmStore.flush(w);           // persist what was new, sealed to our own key
    } catch (_) {
      // A slow or failed poll adds nothing new; it must not REMOVE what the store already holds. Do
      // not return here — fall through and rebuild from the store as it stands.
    }
    return _convosFromStore();
  }

  // ---- blind mailbox read (breaks IP<->account correlation) ----
  // The ordinary read GETs /api/dm_inbox?account=... from our node, so the node sees our IP beside the
  // account whose mailbox we read — enough to re-attach a sender to a sealed message by correlation.
  // A blind read seals the request (account + ownership proof) to a relay's key and hands the node an
  // opaque blob to forward: the node sees the IP but not the account, the relay sees the account but
  // only the node's IP. See docs/ANONYMITY.md §4 and wallet.dart's sealMailboxRead.
  static List<Map<String, dynamic>>? _blindRelays;  // eligible relays, each verified against the LEDGER
  static int _blindRelayAt = 0;                      // epoch secs of the last (re)resolution attempt
  static bool _blindDisabled = false;                // nothing eligible last try — back off, don't rescan
  static String _blindRelayBase = '';                // the node (kBase) this set was resolved against

  /// Raw DM ciphertext records — via a BLIND read when relay keys are available, else the ordinary
  /// signed read straight to our node. `full` (the periodic full sweep) reads EVERY eligible relay and
  /// merges, so a message that landed only on some relays is still caught; incremental polls read one
  /// relay for speed. Both paths deliver the same shape; the caller's decrypt loop does not care which.
  static Future<List<Map<String, dynamic>>> _dmFetchRaw(NanoWallet w, int since, bool full) async {
    final blind = await _blindDmFetch(w, since, full);
    if (blind != null) return blind;
    // Fallback: ordinary signed read. The node cannot forge this proof — it holds no seed — but it does
    // see (our IP, our account) together, which the blind path above is what avoids.
    final ats = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final auth = w.signMsg(w.dmInboxMsg(ats));
    final r = await http.get(Uri.parse('$kBase/api/dm_inbox?account=${w.account}'
        '${since > 0 ? '&since=$since' : ''}'
        '&ts=$ats&sig=${Uri.encodeQueryComponent(auth['sig']!)}'
        '&pub=${Uri.encodeQueryComponent(auth['pub']!)}'))
        .timeout(const Duration(seconds: 12));
    return ((jsonDecode(r.body)['dms'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Blind-read the mailbox. `all` reads EVERY eligible relay in parallel and merges — the completeness
  /// backstop that closes the single-relay gap: a message that landed only on some relays (the one we
  /// usually read was down when it was sent) is still caught. Otherwise it reads just the first relay.
  /// Returns null ONLY when NO relay could serve it, so the caller falls back to the ordinary read; an
  /// empty-but-successful read returns [] (an empty mailbox is a valid answer, not a failure).
  static Future<List<Map<String, dynamic>>?> _blindDmFetch(NanoWallet w, int since, bool all) async {
    try {
      final relays = await _blindReadRelays();
      if (relays.isEmpty) return null;
      final targets = all ? relays : relays.take(1).toList();
      final results = await Future.wait(targets.map((r) => _blindReadOne(w, since, r)));
      if (results.every((r) => r == null)) return null;    // every target failed → fall back
      final seen = <String>{};
      final merged = <Map<String, dynamic>>[];
      for (final list in results) {
        if (list == null) continue;
        for (final m in list) {
          // Dedup across relays the way the node does: by `mid` for sealed v2, else (from, ts).
          final k = m['mid'] != null ? 'mid:${m['mid']}' : 'ft:${m['from']}:${m['ts']}';
          if (seen.add(k)) merged.add(m);
        }
      }
      return merged;
    } catch (_) {
      return null;                                        // never let the privacy path drop a message
    }
  }

  /// One blind read against one relay. Returns its records, or null if that relay could not serve it.
  static Future<List<Map<String, dynamic>>?> _blindReadOne(
      NanoWallet w, int since, Map<String, dynamic> relay) async {
    try {
      final ats = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final auth = w.signMsg(w.dmInboxMsg(ats));
      final read = w.sealMailboxRead(relay['read_pk'] as String, {
        'account': w.account, 'ts': ats, 'sig': auth['sig'], 'pub': auth['pub'], 'since': since,
      });
      final r = await http.post(Uri.parse('$kBase/api/dm_blind_read'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'relay': relay['url'], 'epk': read.epk, 'ct': read.ct}))
          .timeout(const Duration(seconds: 12));
      final resp = jsonDecode(r.body);
      final ct = resp is Map ? resp['ct'] : null;
      if (ct is! String || ct.isEmpty) return null;
      final reply = read.openReply(ct);
      if (reply == null || reply['error'] != null) return null;
      return ((reply['dms'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  /// Resolve and cache the relays to seal blind reads to: the ones the LEDGER (not our node) says exist,
  /// whose host differs from our node's, and whose read key is signed by their ledger account. Cached an
  /// hour — a ledger scan is not worth doing on every 5s poll. Capped so the full-sweep fan-out is small.
  static Future<List<Map<String, dynamic>>> _blindReadRelays() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // The cache is scoped to the current node: a REPOINT invalidates it, because a relay chosen for the
    // old node may be co-located with the new operator (privacy loss) or unknown to it (reads fall
    // back). While the node is unchanged, keep an eligible set for an hour; but back off only ~3 min
    // after a FAILED/empty resolution — a transient ledger-discovery blip (a rate-limited public RPC)
    // must not silently disable the private read for a whole hour, though we still must not rescan the
    // ledger on every 5s poll.
    if (_blindRelayBase == kBase) {
      if (_blindRelays != null && now - _blindRelayAt < 3600) return _blindRelays!;
      if (_blindDisabled && now - _blindRelayAt < 180) return const [];
    }
    final w = gWallet;
    if (w == null) return const [];
    final out = <Map<String, dynamic>>[];

    Future<void> tryAdd(String url, String acct) async {
      if (out.any((e) => e['url'] == url)) return;
      try {
        final r = await http
            .get(Uri.parse('$kBase/api/relay_readkey?relay=${Uri.encodeQueryComponent(url)}'))
            .timeout(const Duration(seconds: 6));
        final rec = jsonDecode(r.body);
        if (rec is! Map<String, dynamic>) return;
        final readPk = w.relayReadPk(rec, acct);            // verifies the sig binds read_pk to acct
        if (readPk != null) out.add({'url': url, 'account': acct, 'read_pk': readPk});
      } catch (_) {/* skip this relay */}
    }

    // DEBUG-ONLY hook, for a local relay NOT announced on the ledger (a test rig). It anchors read_pk to
    // the account the /relaykey record SELF-REPORTS instead of one read off the ledger, so it TRUSTS THE
    // NODE and gives up the MITM protection the ledger anchor provides — NEVER set in a shipped build.
    // Inert unless compiled with --dart-define=XCHAT_DEBUG_BLIND_RELAY=<node-side relay url>.
    const debugRelay = String.fromEnvironment('XCHAT_DEBUG_BLIND_RELAY');
    if (debugRelay.isNotEmpty) {
      try {
        final r = await http
            .get(Uri.parse('$kBase/api/relay_readkey?relay=${Uri.encodeQueryComponent(debugRelay)}'))
            .timeout(const Duration(seconds: 6));
        final rec = jsonDecode(r.body);
        if (rec is Map<String, dynamic>) {
          final acct = '${rec['account']}';                 // self-reported (debug: NOT ledger-anchored)
          final readPk = w.relayReadPk(rec, acct);
          if (readPk != null) out.add({'url': debugRelay, 'account': acct, 'read_pk': readPk});
        }
      } catch (_) {/* fall through to real discovery */}
    }
    try {
      final nodeHost = Uri.parse(kBase).host;
      for (final rl in await LedgerDiscovery.discoverRelays()) {
        if (out.length >= 5) break;                         // cap the full-sweep fan-out
        final url = rl['url'] ?? '', acct = rl['account'] ?? '';
        if (url.isEmpty || acct.isEmpty) continue;
        if (Uri.parse(url).host == nodeHost) continue;      // must not be our own node's operator
        await tryAdd(url, acct);
      }
    } catch (_) {/* discovery failed — fall back for now */}

    if (out.isNotEmpty) {
      _blindRelays = out;
      _blindRelayAt = now;
      _blindRelayBase = kBase;
      _blindDisabled = false;
      return out;
    }
    _blindDisabled = true;
    _blindRelayAt = now;                                    // nothing eligible; back off ~3 min, then retry
    _blindRelayBase = kBase;
    return const [];
  }

  /// The conversation list straight from the on-device store, no network. Loads the store (fast,
  /// local) and returns what it holds, so the inbox can paint IMMEDIATELY instead of spinning for the
  /// seconds a cold /api/dm_inbox takes. dmInbox() then refreshes it in the background. A returning
  /// user has their whole history on disk already — making them wait on the network to see it was the
  /// 15s spinner this removes.
  static Future<List<Map<String, dynamic>>> dmInboxCached() async {
    final w = gWallet;
    if (w == null) return [];
    await DmStore.load(w);
    return _convosFromStore();
  }

  /// Every conversation, rebuilt from the on-device store — never from a network response. An
  /// incremental response carries only the NEW messages and a failed one carries none, so building a
  /// thread from a response would shrink it (or empty it); the store has the whole history. Kept
  /// separate so the "always show the store, whatever the network did" rule lives in one place.
  static List<Map<String, dynamic>> _convosFromStore() {
    final convos = <String, List<Map<String, dynamic>>>{};
    // The peer's DM key, kept per conversation: attachments are sealed to this same box, so the chat
    // screen needs it to decrypt them and would otherwise have to re-fetch it per image.
    final peerKeys = <String, String>{};
    for (final m in DmStore.all()) {
      final peerAcc = '${m['peer']}';
      peerKeys[peerAcc] = '${m['peer_pk']}';
      (convos[peerAcc] ??= []).add(m);
    }
    for (final lst in convos.values) {
      lst.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    }
    final out = convos.entries
        .map((e) => {'peer': e.key, 'messages': e.value, 'last_ts': e.value.last['ts'],
                     'peer_pk': peerKeys[e.key] ?? ''})
        .toList();
    out.sort((a, b) => (b['last_ts'] as int).compareTo(a['last_ts'] as int));
    return out.cast<Map<String, dynamic>>();
  }

  // profile: signed portable record (display name, bio, avatar/banner CIDs) keyed by account
  static Future<Map<String, dynamic>?> profileGet(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/profile_get?account=$account'));
      return (jsonDecode(r.body)['profile'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  // The RAW (unverified) profile record straight from the relay (the node proxies non-/api paths to it).
  // Used only to recover our OWN display name whose signed record was invalidated by a signing-format
  // change, so we can re-sign it under the current scheme. Not trusted for other accounts.
  static Future<Map<String, dynamic>?> profileRaw(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/profile?account=$account'));
      return (jsonDecode(r.body)['record'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  // on-device signed: the app signs the profile record locally; the node only verifies + relays.
  static Future<Map<String, dynamic>?> profileSet(String display, String bio, String avatar, String banner, {NanoWallet? signer, String type = '', String? pinned}) async {
    final w = signer ?? gWallet;   // `signer` lets a channel set ITS OWN profile (name/desc/avatar)
    if (w == null) return null;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.profileMsg(ts, display, bio, avatar, banner));
    // Pinned post: carried and signed SEPARATELY (additive), so it never changes the profile canon and
    // an old client ignores it. `pinned == ''` clears the pin; `pinned == null` leaves it untouched.
    final ps = pinned != null ? w.signMsg(w.pinMsg(ts, pinned)) : null;
    try {
      final r = await http.post(Uri.parse('$kBase/api/profile_set'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'account': w.account, 'display': display, 'bio': bio, 'avatar': avatar,
                            'banner': banner, 'ts': ts, 'sig': s['sig'], 'pub': s['pub'],
                            if (type.isNotEmpty) 'type': type,
                            if (pinned != null) 'pinned': pinned,
                            if (ps != null) 'pinned_sig': ps['sig']}));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  // Pin (or, with postId '', unpin) a post to your profile. Re-publishes your profile with the current
  // display/bio/avatar/banner plus the separately-signed pinned marker.
  static Future<bool> setPinned(String postId) async {
    final w = gWallet;
    if (w == null) return false;
    final p = await profileGet(w.account) ?? {};
    final r = await profileSet('${p['display'] ?? ''}', '${p['bio'] ?? ''}',
        '${p['avatar'] ?? ''}', '${p['banner'] ?? ''}', pinned: postId);
    return r?['ok'] == true;
  }

  // upload an image; returns its content-addressed cid (pinned to the relays)
  static String? lastBlobErr;
  static Future<String?> blobPut(Uint8List bytes) async {
    try {
      final r = await http.post(Uri.parse('$kBase/api/blob_put'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'b64': base64Encode(bytes)})).timeout(const Duration(seconds: 45));
      final cid = jsonDecode(r.body)['cid'] as String?;
      if (cid == null || cid.isEmpty) {
        final b = r.body;
        lastBlobErr = 'HTTP ${r.statusCode}: ${b.length > 100 ? b.substring(0, 100) : b}';
      }
      return cid;
    } catch (e) {
      lastBlobErr = '$e';
      return null;
    }
  }

  // comments: signed off-chain replies to a post
  static Future<List<Map<String, dynamic>>> comments(String postId) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/comments_get?post=$postId'));
      return ((jsonDecode(r.body)['comments'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // on-device signed: the app signs the reply locally; the node only verifies + relays.
  static Future<Map<String, dynamic>?> comment(String postId, String text, String handle, {String parent = ''}) async {
    final w = gWallet;
    if (w == null) return null;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.commentMsg(postId, ts, text, parent));
    try {
      final r = await http.post(Uri.parse('$kBase/api/comment_post'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': postId, 'account': w.account, 'handle': handle, 'text': text,
                            'parent': parent, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']}));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  // self-update: check for a newer signed, content-addressed release published to the relays
  static Future<Map<String, dynamic>?> releaseCheck() async {
    // the single-threaded engine can be momentarily busy (a feed refresh, a big download) and 502
    // at the tunnel — a non-JSON reply. Retry once before surfacing an error, with a real timeout.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await http
            .get(Uri.parse('$kBase/api/release_check?current=$kAppVersion'))
            .timeout(const Duration(seconds: 25));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
      if (attempt == 0) await Future.delayed(const Duration(milliseconds: 800));
    }
    return null;
  }

  // download the release APK from the relays (content-addressed) and verify its hash
  static Future<Map<String, dynamic>?> releaseFetch(String cid, String sha256) async {
    try {
      final r = await http.post(Uri.parse('$kBase/api/release_fetch'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'cid': cid, 'sha256': sha256}));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> followsGet(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/follows_get?account=$account'));
      final f = jsonDecode(r.body)['follows'];
      if (f is List) return f.map((e) => '$e').where((e) => e.isNotEmpty).toList();
      if (f is String && f.isNotEmpty) return f.split(',').where((e) => e.isNotEmpty).toList();
      return [];
    } catch (_) {
      return [];
    }
  }

  // Who follows `account` (the reverse edge), unioned across relays by the node's /api/followers.
  static Future<List<String>> followersGet(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/followers?account=$account'));
      return ((jsonDecode(r.body)['followers'] as List?) ?? const [])
          .map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

}

// compact counts, X-style: 942 · 1.2K · 3.4M
String _compact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) { final k = n / 1000; return '${k < 10 ? k.toStringAsFixed(1) : k.round()}K'; }
  final m = n / 1000000; return '${m < 10 ? m.toStringAsFixed(1) : m.round()}M';
}

// Format an XNO tip amount compactly — a small tip keeps its significant decimals (0.001 stays
// "0.001", not rounded to "0.00"); a whole number drops the decimals. Used for tip amounts everywhere
// so sub-0.01 tips are shown (and, via _xnoToRaw, sent) at full precision.
String fmtXno(double v) {
  if (v >= 1) return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  var s = v.toStringAsFixed(6);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s.isEmpty ? '0' : s;
}

String timeAgo(int ts) {
  if (ts == 0) return '';
  final s = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

// a short, STABLE per-account tag (a discriminator, not a full address) so two accounts that share a
// handle — e.g. the default "you.xno" everyone starts with — are still distinguishable at a glance.
// Derived from the account's own pubkey encoding, so it's unforgeable: you can't fake someone's tag.
String acctTag(String account) {
  final p = account.startsWith('nano_') ? account.substring(5) : account;
  return p.length >= 5 ? p.substring(0, 5) : p;
}

Color avatarColor(String h) {
  int n = 0;
  for (final c in h.codeUnits) {
    n = (n * 31 + c) & 0x7fffffff;
  }
  const palette = [
    Color(0xFF3E9BFF), Color(0xFF4DD0A7), Color(0xFFE0B64D),
    Color(0xFFEF6C9B), Color(0xFF9B7BFF), Color(0xFFFF8A5B),
  ];
  return palette[n % palette.length];
}

// resolves account -> signed profile (display name, bio, avatar/banner CIDs), lazily + cached,
// so any avatar/name in the app upgrades to the real profile as soon as it loads.
class ProfileCache extends ChangeNotifier {
  static final ProfileCache I = ProfileCache._();
  ProfileCache._();
  final Map<String, Map<String, dynamic>> _p = {};
  final Set<String> _loading = {};

  Map<String, dynamic>? of(String account) => _p[account];

  void put(String account, Map<String, dynamic> prof) {
    _p[account] = prof;
    notifyListeners();
  }

  void ensure(String account) {
    if (account.isEmpty || _p.containsKey(account) || _loading.contains(account)) return;
    _loading.add(account);
    Api.profileGet(account).then((prof) {
      _loading.remove(account);
      if (prof != null) put(account, prof);
    });
  }

  String displayName(String account, String fallbackHandle) {
    final d = _p[account]?['display'];
    return (d is String && d.trim().isNotEmpty) ? d : fallbackHandle;
  }

  String? avatarCid(String account) {
    final a = _p[account]?['avatar'];
    return (a is String && a.isNotEmpty) ? a : null;
  }
}

// an avatar that shows the account's uploaded image once its profile resolves, else a letter tile
// Who is online right now, from /api/presence (a head refreshed in the last ~2.5 min ≈ an open app,
// since the app republishes its head every 45s). A ChangeNotifier so every AuthorAvatar toggles its
// green dot reactively when the set refreshes. No identity tracking beyond the head each account
// already publishes publicly.
class PresenceCache extends ChangeNotifier {
  PresenceCache._();
  static final PresenceCache I = PresenceCache._();
  Set<String> _online = {};
  bool isOnline(String account) => account.isNotEmpty && _online.contains(account);
  void update(Set<String> online) {
    if (online.length == _online.length && online.containsAll(_online)) return; // no change → no rebuild
    _online = online;
    notifyListeners();
  }
}

class AuthorAvatar extends StatelessWidget {
  final String account, handle;
  final double radius;
  const AuthorAvatar({super.key, required this.account, required this.handle, this.radius = 22});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([ProfileCache.I, PresenceCache.I]),
      builder: (_, __) {
        ProfileCache.I.ensure(account);
        final cid = ProfileCache.I.avatarCid(account);
        final Widget avatar = (cid != null && cid.startsWith('live:'))
            ? LiveAvatar(style: cid.substring(5), radius: radius)   // animated, code-drawn avatar
            : cid != null
                ? ClipOval(
                    child: SizedBox(
                      width: radius * 2, height: radius * 2,
                      child: MediaImage(cid: cid, fit: BoxFit.cover),
                    ),
                  )
                : CircleAvatar(
                    radius: radius,
                    backgroundColor: avatarColor(handle),
                    child: Text(handle.isEmpty ? '?' : handle.substring(0, 1).toUpperCase(),
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: radius * 0.62)),
                  );
        final who = handle.isEmpty ? 'this account' : handle;
        if (!PresenceCache.I.isOnline(account)) {
          // ONE label for the whole avatar, whichever of the three forms it took. Without it, the
          // initial-letter fallback reads out as a lone capital letter and the image forms read as
          // nothing at all.
          return Semantics(
              image: true, label: 'Avatar of $who', child: ExcludeSemantics(child: avatar));
        }
        final d = (radius * 0.55).clamp(8.0, 14.0);        // dot scales with the avatar
        return Semantics(
          image: true,
          // The online dot is a 10-pixel green circle — pure colour and position, carrying a fact
          // that is otherwise unreachable without sight.
          label: 'Avatar of $who, online',
          child: ExcludeSemantics(
            child: Stack(clipBehavior: Clip.none, children: [
          avatar,
          Positioned(
            right: -1, bottom: -1,
            child: Container(
              width: d, height: d,
              decoration: BoxDecoration(
                color: const Color(0xFF3BD671),            // "online" green
                shape: BoxShape.circle,
                border: Border.all(color: kBg, width: 2),  // ring so it reads on any avatar/photo
              ),
            ),
          ),
            ]),
          ),
        );
      },
    );
  }
}

// A LIVE (animated, code-drawn) avatar — no image upload. Stored in the profile as the sentinel
// "live:<style>" in the avatar field; AuthorAvatar renders this instead of a MediaImage. Older app
// versions that don't know the sentinel fall back to the initial-letter avatar (graceful).
class LiveAvatar extends StatefulWidget {
  final String style;   // currently 'orbit'
  final double radius;
  const LiveAvatar({super.key, required this.style, this.radius = 22});
  @override
  State<LiveAvatar> createState() => _LiveAvatarState();
}

class _LiveAvatarState extends State<LiveAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final d = widget.radius * 2;
    return SizedBox(
      width: d, height: d,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
            painter: widget.style == 'key' ? _KeyPainter(_c.value) : _OrbitPainter(_c.value)),
      ),
    );
  }
}

// "Orbit": a dark disc with three coloured dots (XNO teal / blue / green) orbiting the Ӿ mark.
class _OrbitPainter extends CustomPainter {
  final double t; // 0..1 animation phase
  _OrbitPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF0B1A22));          // disc
    canvas.drawCircle(c, r - 1, Paint()                                          // faint rim
      ..style = PaintingStyle.stroke..strokeWidth = 1
      ..color = const Color(0xFF14E0C8).withValues(alpha: 0.22));
    final orbitR = r * 0.74, dotR = (r * 0.14).clamp(1.5, 6.0);
    const colors = [Color(0xFF14E0C8), Color(0xFF3B82F6), Color(0xFF3BD671)];
    for (int i = 0; i < 3; i++) {
      final ang = 2 * math.pi * (t + i / 3);
      final p = c + Offset(math.cos(ang), math.sin(ang)) * orbitR;
      canvas.drawCircle(p, dotR, Paint()
        ..color = colors[i]
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8));
    }
    final xr = r * 0.42;                                                          // centre Ӿ mark
    final pen = Paint()
      ..color = Colors.white
      ..strokeWidth = math.max(1.5, r * 0.12)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c + Offset(-xr * 0.62, -xr), c + Offset(xr * 0.62, xr), pen);
    canvas.drawLine(c + Offset(xr * 0.62, -xr), c + Offset(-xr * 0.62, xr), pen);
    canvas.drawLine(c + Offset(-xr * 0.5, 0), c + Offset(xr * 0.5, 0), pen);      // the Ӿ bar
  }
  @override
  bool shouldRepaint(_OrbitPainter old) => old.t != t;
}

// "Key": a glowing key (diamond bow + toothed blade) spinning on a dark disc — the "keyholder" motif.
class _KeyPainter extends CustomPainter {
  final double t; // 0..1 phase → one full rotation per cycle
  _KeyPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF0B1A22));            // disc
    canvas.drawCircle(c, r - 1, Paint()                                          // faint rim
      ..style = PaintingStyle.stroke..strokeWidth = 1
      ..color = const Color(0xFF14E0C8).withValues(alpha: 0.22));

    // key silhouette, centred on the origin and scaled to the radius
    final key = Path();
    final bowY = -0.40 * r, bs = 0.34 * r;                                        // bow = diamond
    key.moveTo(0, bowY - bs); key.lineTo(bs, bowY); key.lineTo(0, bowY + bs); key.lineTo(-bs, bowY); key.close();
    final sw = 0.10 * r;
    key.addRect(Rect.fromLTRB(-sw, bowY, sw, 0.60 * r));                          // shaft
    key.addRect(Rect.fromLTRB(sw, 0.28 * r, sw + 0.22 * r, 0.38 * r));            // tooth 1
    key.addRect(Rect.fromLTRB(sw, 0.46 * r, sw + 0.13 * r, 0.55 * r));            // tooth 2
    final hole = Path();                                                          // bow negative space
    final hs = 0.15 * r;
    hole.moveTo(0, bowY - hs); hole.lineTo(hs, bowY); hole.lineTo(0, bowY + hs); hole.lineTo(-hs, bowY); hole.close();

    canvas.save();
    canvas.translate(c.dx, c.dy);
    // Turn LEFT → RIGHT around the vertical axis (like a key turning in a lock), rather than a flat
    // pinwheel spin: scaling X by cos(phase) is the orthographic projection of that horizontal rotation.
    canvas.scale(math.cos(2 * math.pi * t), 1.0);
    canvas.drawPath(key, Paint()                                                  // glow halo
      ..color = const Color(0xFF4FD1C5).withValues(alpha: 0.85)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, (r * 0.22).clamp(1.0, 10.0)));
    canvas.drawPath(key, Paint()..color = const Color(0xFF2EA8F0));              // sharp key
    canvas.drawPath(hole, Paint()..color = const Color(0xFF0B1A22));            // punch the bow hole
    canvas.restore();
  }
  @override
  bool shouldRepaint(_KeyPainter old) => old.t != t;
}

// a subtle dark scrim + camera glyph, laid over an image thumbnail to say "tap to change"
class _CamScrim extends StatelessWidget {
  const _CamScrim();
  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withValues(alpha: 0.28),
        child: const Center(child: Icon(Icons.photo_camera_outlined, color: Colors.white70, size: 20)),
      );
}

// ---- Ӿ : the XNO (Nano) symbol, drawn as a vector so it renders on any font ----
class XnoGlyph extends StatelessWidget {
  final double size;
  final Color color;
  final double weight;
  const XnoGlyph({super.key, required this.size, required this.color, this.weight = 0.12});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _XnoPainter(color, weight));
}

class _XnoPainter extends CustomPainter {
  final Color color;
  final double weight;
  _XnoPainter(this.color, this.weight);
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final p = Paint()
      ..color = color
      ..strokeWidth = s * weight
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    // the X (Cyrillic Ha) …
    canvas.drawLine(Offset(s * 0.22, s * 0.18), Offset(s * 0.78, s * 0.82), p);
    canvas.drawLine(Offset(s * 0.78, s * 0.18), Offset(s * 0.22, s * 0.82), p);
    // … with the HORIZONTAL crossbar through the waist that makes it Ӿ (Nano / XNO).
    canvas.drawLine(Offset(s * 0.26, s * 0.52), Offset(s * 0.74, s * 0.52), p);
  }

  @override
  bool shouldRepaint(_XnoPainter o) => o.color != color || o.weight != weight;
}

// gradient badge containing the Ӿ mark
class NanoMark extends StatelessWidget {
  final double size;
  final bool filled;
  const NanoMark({super.key, this.size = 30, this.filled = true});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled
            ? const LinearGradient(
                colors: [kAccent, Color(0xFF4DD0A7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight)
            : null,
      ),
      child: XnoGlyph(
          size: size * 0.6, color: filled ? Colors.black : kText, weight: 0.14),
    );
  }
}

// ---- feed ----
class FeedScreen extends StatefulWidget {
  final Future<void> Function()? onLogout;
  const FeedScreen({super.key, this.onLogout});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  NanoWallet? _wallet; // on-device signer, built from the local seed — never sent to the node
  List<Post> _posts = [];
  final List<Post> _newPosts = [];        // fetched but held BACK — surfaced via a "new posts" pill,
                                          // not injected live, so the reader's scroll never jumps
  int _pollTick = 0;                      // every 5th quiet poll does a full reconcile (drops expired)
  final ScrollController _scroll = ScrollController();
  // One screen holds ~6 cards, so 40 is several screens of runway before the next fetch — enough
  // that scrolling never waits on the network, small enough that a cold launch parses ~25 KB
  // instead of the whole timeline.
  static const _pageSize = 40;
  bool _loadingMore = false;
  List<Labeler> _labelers = [];
  final Set<String> _shown = {}; // posts the viewer chose to reveal
  int _modIdx = 0;
  final List<double> _thresh = [0.5, 0.9, 0.1, 2.0]; // ≥50% / ≥90% / ≥10% / off
  final List<String> _threshLbl = ['≥50%', '≥90%', '≥10%', 'off'];
  static const double _halflife = 7 * 86400; // reputation halves per 7 idle days
  String _handle = 'you.xno';
  String _balance = '0';
  bool _loading = true;
  String? _error;
  int _onchainBlocks = 0;
  int _relaysUp = 0, _relaysTotal = 0;
  final Map<String, double> _pending = {}; // author account -> tallied XNO (off-chain)
  final Set<String> _settling = {};        // creators with a settle in flight — blocks re-entrant settles
  bool _settleBusy = false;                 // guards the manual batch settle against a double-tap
  final Map<String, String> _handleOf = {}; // account -> handle, for the settle bar

  /// account -> handle for the transaction list. A nano_ address identifies nobody, so pair it with
  /// whatever name this device has actually seen that account post under. _handleOf is populated by
  /// the settle bar; the feed carries the rest. Unknown accounts simply stay addresses — never guess.
  Map<String, String> _knownHandles() {
    final m = <String, String>{..._handleOf};
    for (final p in _posts) {
      if (p.account.isNotEmpty && p.handle.isNotEmpty) m[p.account] = p.handle;
    }
    if (_account.isNotEmpty) m[_account] = _handle;
    return m;
  }
  // reshare/media attribution LOCKED at tip time (per creator) — a later reshare can't claim it
  final Map<String, String> _reposterOf = {}; // author account -> resharer account to reward
  final Map<String, String> _mediaOf = {};    // author account -> media cid (to reward its host relay)
  // auto-settle policy: consented once (threshold + cap), fires within bounds, non-custodial
  bool _autoSettle = false;
  double _autoThreshold = 0.05, _autoCap = 1.0, _autoSpent = 0.0;
  int _tab = 0; // 0 = Home, 1 = Discover (everyone + search)
  String? _discoverQ;   // a query handed over by tapping a mention or a hashtag

  /// Jump to Discover with the search already filled in.
  void _openDiscover(String q) => setState(() { _discoverQ = q; _tab = 2; });
  int _homeFeed = 0; // 0 = For You (ranked), 1 = Following (STRICT: only accounts you follow). Open on
  // For You so a user who follows nobody isn't greeted by an empty Following tab.
  List<Map<String, dynamic>> _outbox = []; // posts composed OFFLINE, queued + auto-flushed on reconnect
  bool _flushing = false;                  // guards _flushOutbox against re-entrancy
  Map<String, dynamic>? _update;           // a newer signed release found by the launch auto-check
  bool _needsBackup = false;               // this wallet's seed isn't confirmed backed up (footgun guard)
  BigInt _incomingRaw = BigInt.zero;       // claimable right now, shown while it lands
  Set<String> _follows = {};
  Settings _settings = Settings();
  Map<String, dynamic> _engage = {}; // post_id -> {likes, reposts, tips_raw}
  final Set<String> _liked = {}, _reposted = {}, _reported = {};
  Set<String> _muted = {}, _blocked = {}; // per-viewer moderation (accounts)
  List<String> _mutedWords = [];          // hidden words — posts containing one are filtered (viewer-only)
  Set<String> _bookmarks = {}; // saved post ids (private, on-device)
  final Set<String> _viewed = {}; // ids counted as viewed this session (dedup)
  final Map<String, int> _commentCount = {}; // post_id -> comment count (lazy)
  List<Map<String, dynamic>> _notifs = []; // push payloads (mentions/replies)
  int _dmUnread = 0;   // conversations with an incoming DM newer than _dmSeenTs (drives the mail badge)
  int _dmSeenTs = 0;   // unix-s of the last time DMs were opened; persisted so the badge survives restarts
  int _dmNewestInTs = 0; // ts of the newest incoming DM the badge has seen — a floor for "seen" on open,
                         // so a sender whose clock runs ahead of ours can't leave a read DM stuck unread
  int _notifSeenTs = 0;  // unix-s the notifications bell was last opened; older notifs don't count as unread
  // unread = notifications newer than the last bell-open, minus muted/blocked (matches what _showNotifs lists)
  int get _notifUnread {
    final hidden = {..._muted, ..._blocked}.map(_handleFor).toSet();
    return _notifs.where((n) =>
        !hidden.contains('${n['from']}') && ((n['ts'] as int?) ?? 0) > _notifSeenTs).length;
  }
  String? _announcement;  // publisher-signed coordinated-event banner text; null in normal operation
  String _account = '';
  // supporter mode: contribute (relay/pin) ONLY when charging + on Wi-Fi
  bool _supporterOn = false, _charging = false, _wifi = false;
  int _supporters = 0;
  final Battery _battery = Battery();
  StreamSubscription? _batSub, _connSub;
  Timer? _republishTimer, _gossipTimer, _feedTimer, _updateTimer, _presenceTimer;
  int _relayed = 0; // signed heads this phone has propagated (backfilled) this session
  int _republishTick = 0; // gates the head republish: every tick = presence beacon, else keepalive only
  bool get _supporterActive => _supporterOn && _charging && _wifi;

  @override
  void initState() {
    super.initState();
    Notifs.init();   // set up Android notifications + ask for the POST_NOTIFICATIONS grant (Android 13+)
    _bootWallet();
    _load();
    _initDevice();
    SettingsStore.get().then((s) {
      if (mounted) setState(() => _settings = s);
    });
    _initProfile();
    MuteStore.get().then((m) { if (mounted) setState(() => _muted = m); });
    BlockStore.get().then((b) { if (mounted) setState(() => _blocked = b); });
    MutedWordsStore.get().then((w) { if (mounted) setState(() => _mutedWords = w); });
    BookmarkStore.get().then((b) { if (mounted) setState(() => _bookmarks = b); });
    // per-device engagement memory — so a view/like is counted once per device, not re-sent each launch
    EngageStore.liked().then((s) { if (mounted) setState(() => _liked.addAll(s)); });
    EngageStore.reposted().then((s) { if (mounted) setState(() => _reposted.addAll(s)); });
    EngageStore.viewed().then((s) { if (mounted) _viewed.addAll(s); });
    _refreshTxLog();
    SharedPreferences.getInstance().then((sp) {
      if (mounted) setState(() {
        _dmSeenTs = sp.getInt('dm_seen_ts') ?? 0;
        _notifSeenTs = sp.getInt('notif_seen_ts') ?? 0;
      });
    });
    _loadChannels();
    // keep our own head alive on the relays (republish < TTL); also backfills new relays
    WidgetsBinding.instance.addObserver(this);   // resume -> claim immediately (see below)
    // Load the next page BEFORE the user reaches the end, so the timeline never shows a dead stop.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels > p.maxScrollExtent - 1200) _loadMore();
    });
    // Head republish. A fresh head within the node's ~150s presence window is what makes /api/presence
    // report us "online", so the 45s cadence is really a presence BEACON — separate from keeping the
    // head alive (its expiry is far longer). Presence is OPT-IN: with it on we republish every 45s (a
    // live green dot); with it off — the default — we republish only ~every 20 min, enough to keep the
    // head propagating to newly-joined relays without broadcasting a continuous "this person is awake"
    // signal to anyone who polls /api/presence. Reads _settings live, so toggling takes effect next tick.
    _republishTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      _republishTick++;
      if (_settings.showPresence || _republishTick % 27 == 0) Api.republish();   // 27*45s ≈ 20 min
    });
    // quietly poll the feed so posts from OTHER devices appear on their own (no manual refresh)
    _feedTimer = Timer.periodic(const Duration(seconds: 12), (_) => _refreshFeedQuiet());
    // who's online — refresh the green dots a bit faster than the 45s head heartbeat so they feel live
    _refreshPresence();
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPresence());
    _refreshChannelAccounts(); // learn which accounts are channels (to keep them out of the feed)
    // re-check for a newer release periodically, not only at launch — so a long-lived session still
    // surfaces the update banner (the launch check is in _bootWallet).
    // Every 30 min, not every 4 hours. The check is one GET that the node answers from a 20s cache,
    // so it is cheap; four hours meant a release could sit unmentioned for most of a day in front of
    // someone with the app open — which is exactly how a 2.4.1 that fixes a stuck wallet goes unseen.
    _updateTimer = Timer.periodic(const Duration(minutes: 30), (_) => _autoCheckUpdate());
    // Push: the badge updates when a DM is sent, not up to 12s later. The poll below stays as the
    // safety net — see DmPush — but backs off to 45s while a stream is live.
    DmPush.onNudge = _refreshDmBadge;
    _dmBadgeTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (DmPush.live && DateTime.now().difference(_lastBadgePoll).inSeconds < 45) return;
      _lastBadgePoll = DateTime.now();
      _refreshDmBadge();
    });
  }

  Timer? _dmBadgeTimer;
  DateTime _lastBadgePoll = DateTime.fromMillisecondsSinceEpoch(0);

  // THE trigger that matters. Until now the app did not observe lifecycle at all, so a phone that sat
  // in a pocket for an hour came back showing a balance that had been wrong the whole time and stayed
  // wrong until a timer happened to fire. Money that arrived while you were away should be there the
  // instant you look — that is the moment a person actually checks.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _autoReceive();
      _refreshDmBadge();
      final a = gWallet?.account;
      if (a != null) DmPush.start(a);
    } else if (state == AppLifecycleState.paused) {
      // Drop the stream when the app is not in front of anyone. An idle SSE connection is cheaper
      // than a request every 5s, but only while it is genuinely idle AND closed on the way out —
      // otherwise push trades a visible battery cost for an invisible one. Android will suspend the
      // socket anyway; closing it means the node frees the slot instead of discovering the corpse
      // on its next keep-alive.
      DmPush.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dmBadgeTimer?.cancel();
    DmPush.stop();
    _batSub?.cancel();
    _connSub?.cancel();
    _republishTimer?.cancel();
    _presenceTimer?.cancel();
    _gossipTimer?.cancel();
    _feedTimer?.cancel();
    _updateTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _newestTs() {                               // newest ts we already hold (shown OR buffered)
    var t = 0;
    for (final p in _posts) { if (p.ts > t) t = p.ts; }
    for (final p in _newPosts) { if (p.ts > t) t = p.ts; }
    return t;
  }

  // Persist the shown timeline to the on-device cache, bounded to the user's feedCacheSize. Fire-and-
  // forget: a cache write must never block the UI. Called after any change to _posts.
  void _persistFeed() {
    Api.saveCachedPosts(_posts, _settings.feedCacheSize);
  }

  // A lightweight, silent poll. It fetches ONLY posts newer than we already have (incremental), holds
  // them in a buffer surfaced by a "new posts" pill instead of injecting them live (so the reader's
  // scroll never jumps), and updates engagement counts in place. The timeline itself is never
  // rebuilt from scratch here — already-fetched posts (and their CID-cached media) stay put.
  Future<void> _refreshFeedQuiet() async {
    if (_loading) return;                         // a full _load() is already in flight
    // most polls are incremental (only new posts, for the pill); every 5th (~60s) pulls the full set
    // so we can also DROP posts whose head expired / was removed — the incremental slice can't show that.
    final reconcile = (++_pollTick % 5 == 0);
    _refreshDmBadge();   // keep the mail-icon unread count live between full loads
    _autoReceive();   // 12s backstop; the real triggers are resume, a tip alert, and opening the wallet
    if (_pollTick % 2 == 0) _refreshNotifs();   // ~every 24s: pull notifs + raise Android alerts for new ones
    if (_pollTick % 10 == 0) {   // ~every 2 min: pick up a newly-activated announcement without a relaunch
      Api.announcement().then((a) { if (mounted && a != _announcement) setState(() => _announcement = a); });
    }
    try {
      // since-1 re-includes the boundary second (ts filter is strict '>'), so a post arriving in the
      // same second as our newest isn't missed; the id-dedupe below drops the tiny overlap.
      final t = _newestTs();
      final results = await Future.wait(
          [Api.feed(since: reconcile ? 0 : (t > 0 ? t - 1 : 0)), Api.engagement()]);
      final fd = results[0] as FeedData;
      if (!mounted) return;
      final seen = {..._posts.map((p) => p.id), ..._newPosts.map((p) => p.id)};
      final fresh = fd.posts.where((p) => !seen.contains(p.id)).toList();
      setState(() {
        _engage = results[1] as Map<String, dynamic>;      // counts tick in place — non-disruptive
        _relaysUp = fd.relaysUp;
        _relaysTotal = fd.relaysTotal;
        if (reconcile) {
          final live = fd.posts.map((p) => p.id).toSet();  // authoritative full set this round
          _posts = _posts.where((p) => live.contains(p.id)).toList();   // drop expired/removed
          _newPosts.removeWhere((p) => !live.contains(p.id));
        }
      });
      if (reconcile) { _refreshLabels(); _persistFeed(); }   // reports for the shield filter; cache the reconciled set
      if (!mounted) return;
      setState(() {
        if (fresh.isNotEmpty) {
          _newPosts.addAll(fresh);
          _newPosts.sort((a, b) => b.ts.compareTo(a.ts));  // newest first, ready to prepend
        }
      });
    } catch (_) {/* transient — keep showing the last good timeline */}
  }

  // The reader tapped the "new posts" pill: merge the buffer into the timeline and jump to the top.
  void _showNewPosts() {
    if (_newPosts.isEmpty) return;
    setState(() {
      final have = _posts.map((p) => p.id).toSet();
      _posts = [..._newPosts.where((p) => !have.contains(p.id)), ..._posts]
        ..sort((a, b) => b.ts.compareTo(a.ts));
      _newPosts.clear();
    });
    _persistFeed();   // the merged-in new posts are now part of the timeline — cache them
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  // start/stop the actual serving work as the charging+wifi gate flips
  void _updateGossip() {
    if (_supporterActive) {
      _gossipTimer ??= Timer.periodic(const Duration(seconds: 25), (_) => _gossipRound());
      _gossipRound(); // do a round immediately
    } else {
      _gossipTimer?.cancel();
      _gossipTimer = null;
    }
  }

  Future<void> _gossipRound() async {
    final g = await Api.gossip();      // propagate signed heads (pointers)
    final p = await Api.pinContent();  // pin content (so it survives origin loss)
    final n = ((g?['backfilled'] ?? 0) as int) + ((p?['backfilled'] ?? 0) as int);
    if (mounted) setState(() => _relayed += n);
  }

  Future<void> _initDevice() async {
    bool wifiFrom(List<ConnectivityResult> r) =>
        r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    try {
      final bs = await _battery.batteryState;
      _charging = bs == BatteryState.charging || bs == BatteryState.full;
      _wifi = wifiFrom(await Connectivity().checkConnectivity());
      if (mounted) setState(() {});
    } catch (_) {}
    _batSub = _battery.onBatteryStateChanged.listen((s) {
      setState(() => _charging = s == BatteryState.charging || s == BatteryState.full);
      _syncSupporter();
    });
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      setState(() => _wifi = wifiFrom(r));
      _syncSupporter();
      if (_onlineFrom(r)) _retryFlush();     // connectivity is back → send anything queued offline
    });
  }

  bool _onlineFrom(List<ConnectivityResult> r) =>
      r.isNotEmpty && r.any((x) => x != ConnectivityResult.none);
  Future<bool> _onlineNow() async {
    if (_onlineFrom(await Connectivity().checkConnectivity())) return true;
    // connectivity_plus can report "none" even when the network is fine (emulators, some VPNs / Android
    // builds). Don't strand posts in the outbox on its say-so — confirm with a real reachability probe
    // against the node before deciding we're offline.
    return _endpointHealthy(kBase);
  }

  // A "connectivity regained" event often arrives while the link is still validating (wifi shows "!"),
  // so a single flush attempt can fail fast. Retry a few times with backoff until the queue drains.
  bool _retrying = false;
  Future<void> _retryFlush() async {
    if (_retrying) return;
    _retrying = true;
    try {
      for (final d in const [Duration.zero, Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)]) {
        await Future.delayed(d);
        if (_outbox.isEmpty || gWallet == null) return;
        if (await _onlineNow()) await _flushOutbox();
      }
    } finally {
      _retrying = false;
    }
  }

  // register/deregister as a supporter, and start/stop the actual serving work
  Future<void> _syncSupporter() async {
    _updateGossip(); // begin/stop propagating heads based on charging+wifi
    if (_account.isEmpty) return;
    final r = await Api.supporter(_supporterActive, _account);
    if (r != null && mounted) setState(() => _supporters = (r['supporters'] ?? _supporters) as int);
  }

  // a tip is tallied CLIENT-SIDE — no network, no block. Settled later in a batch.
  // Amount defaults to the user's configured default tip (Settings).
  // the resharer to credit for a tip on this post: the earliest resharer that isn't the
  // author or me (the "spreader"). '' if none. Captured at tip time so it can't change later.
  String _firstResharer(Post p) {
    final rs = (_eng(p.id)['resharers'] as List?) ?? const [];
    for (final r in rs) {
      final a = '$r';
      if (a != p.account && a != _account) return a;
    }
    return '';
  }

  // spendable balance (XNO) and the off-chain tally waiting to be settled
  double _walletXno() => (double.tryParse(_balance) ?? 0) / 1e30;
  double _pendingTotal() => _pending.values.fold(0.0, (a, b) => a + b);

  // A tip is a promise to pay in real XNO at settle time. Tallying one the wallet can't cover
  // misleads the user into thinking a creator was paid when settlement will simply fail — so a tip
  // is refused whenever it would push the total tally past the wallet balance (0 funds is just the
  // first case of that). Balance and tally are both in XNO.
  bool _guardTip(double amt) {
    final have = _walletXno();
    if (_pendingTotal() + amt <= have + 1e-9) return true;
    _load(); // balance may be stale (e.g. funds just received) — refresh so the next tap can pass
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kCard,
        duration: const Duration(milliseconds: 2600),
        content: Text(have <= 0
            ? 'Your wallet has 0 XNO — receive some before you can tip'
            : 'Not enough XNO: ${have.toStringAsFixed(3)} in wallet, '
                '${(_pendingTotal() + amt).toStringAsFixed(2)} would be tallied')));
    return false;
  }

  void _tallyTip(Post p) {
    if (p.account == _account) {
      // Tipping your own post would settle as a send-to-yourself — it can't complete and would sit in
      // the pending list forever. Block it up front.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard, content: Text("You can't tip your own post")));
      return;
    }
    final amt = _settings.defaultTip;
    if (!_guardTip(amt)) return;
    setState(() {
      _pending[p.account] = (_pending[p.account] ?? 0) + amt;
      _handleOf[p.account] = p.handle;
      // LOCK the reshare + media-host attribution the first time this creator is tipped this batch.
      // A reshare that happens AFTER this can't retroactively claim the tip.
      _reposterOf.putIfAbsent(p.account, () => _firstResharer(p));
      _mediaOf.putIfAbsent(p.account, () => p.media ?? '');
      _bumpEngage(p.id, 'tips_xno', amt); // XNO gathered by this post
    });
    Api.tipstat(p.id, _rawOf(amt));
    // NB: no notification here. A tip is only a PLEDGE until it settles — notifying the creator now
    // would tell them they were paid for money that may never move (the tally can be dropped, or the
    // settle can fail). The creator is notified at SETTLE (see _settle / _maybeAutoSettle), when a real
    // Nano block actually lands.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        backgroundColor: kCard,
        content: Text('◈ +${fmtXno(amt)} XNO tallied off-chain — no network, no block'),
        // Undo is safe HERE because a tip is only a pledge until it settles — and auto-settle is fired
        // right after, so the window is exactly while it's still pending. `_untip` refuses once settled.
        action: SnackBarAction(label: 'Undo', textColor: kAccent, onPressed: () => _untip(p, amt))));
    _maybeAutoSettle(p.account, p.handle);
  }

  // Undo a tip that hasn't settled on-chain yet — a mistap or a change of mind. It just removes the
  // off-chain pledge from `_pending` (and the local tip display); nothing left the wallet until settle,
  // so there's nothing to claw back. Once settled (real XNO sent), it's irreversible — say so.
  void _untip(Post p, double amt) {
    final pending = _pending[p.account] ?? 0;
    if (pending < amt - 1e-9) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text("too late to undo — this tip already settled on-chain")));
      return;
    }
    setState(() {
      final rem = pending - amt;
      if (rem <= 1e-9) {
        _pending.remove(p.account);
      } else {
        _pending[p.account] = rem;
      }
      _bumpEngage(p.id, 'tips_xno', -amt);   // pull it back out of this post's tally display
    });
    Api.tipstat(p.id, '-${_rawOf(amt)}');     // best-effort decrement of the network counter
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kCard,
        duration: const Duration(milliseconds: 1400),
        content: Text('↩ tip undone — ${fmtXno(amt)} XNO not tallied')));
  }

  // fire an on-chain settlement automatically ONLY within the user-consented policy
  Future<void> _maybeAutoSettle(String account, String handle) async {
    if (account == _account) { setState(() => _pending.remove(account)); return; } // self-tip: nothing to settle
    if (!_autoSettle) return;
    // RE-ENTRANCY GUARD: settle is a multi-second network+PoW round trip fired from every tip tap. ALL
    // settles sign against the wallet's single frontier, so two overlapping ones — even for DIFFERENT
    // creators — sign on the same (not-yet-advanced) frontier and one forks (and the second clears a
    // tally the first hadn't accounted for, and both read a stale _autoSpent). Serialize GLOBALLY: block
    // if any settle at all is in flight, not just one for this creator.
    if (_settling.isNotEmpty || _settleBusy) return;
    final amt = _pending[account] ?? 0;
    if (amt + 1e-9 < _autoThreshold) return; // below the per-creator threshold — keep tallying
    if (_autoSpent + amt > _autoCap + 1e-9) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text('auto-settle cap reached — settle the rest manually')));
      return;
    }
    _settling.add(account);
    try {
    final r = await Api.settle(account, amt.toStringAsFixed(6),
        split: _settings.relaySplit, rsplit: _settings.reposterSplit,
        reposter: _reposterOf[account] ?? '', media: _mediaOf[account] ?? '');
    if (r != null && r['ok'] == true) {
      // same as manual settle: money moved, so notify the creator + record the receipt (both settle
      // paths must behave identically — otherwise an auto-settled tip would never notify or log).
      await TxLogStore.add({
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'handle': handle, 'account': account,
        'total': amt, 'paid': r['paid_xno'], 'legs': (r['legs'] as List?) ?? const [],
      });
      if (account != _account && _settings.notifyTip) {
        Api.notifyPush(account, _handle, 'tip', 'settled ${fmtXno(amt)} XNO to you on-chain');
      }
      setState(() {
        _autoSpent += amt;
        // Subtract ONLY what we settled — anything tallied for this creator DURING the await must stay
        // pending (removing the whole entry would silently drop those later tips). Drain fully → clear.
        final rem = (_pending[account] ?? 0) - amt;
        if (rem > 1e-9) {
          _pending[account] = rem;
        } else {
          _pending.remove(account);
          _reposterOf.remove(account);
          _mediaOf.remove(account);
        }
      });
      await _refreshTxLog();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text(
              '⚡ auto-settled ${fmtXno(amt)} XNO → @$handle · 1 block (policy ≥${fmtXno(_autoThreshold)})')));
    } else if (r != null && mounted) {
      // a failed auto-settle must not fail silently — the tally stays pending and the user is told why
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text('auto-settle held: ${r['error'] ?? 'failed'} — still pending')));
    }
    } finally {
      _settling.remove(account);
    }
  }

  void _showAutoSettle() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Widget chips(String label, List<double> opts, double sel, void Function(double) pick) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(color: kDim, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: opts.map((o) {
                  final on = (o - sel).abs() < 1e-9;
                  return GestureDetector(
                    onTap: () { pick(o); setSheet(() {}); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                          color: on ? kAccent : kCard,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: on ? kAccent : kLine)),
                      child: Text('${o.toStringAsFixed(2)} XNO',
                          style: TextStyle(
                              color: on ? Colors.black : kText,
                              fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                  );
                }).toList()),
              ]),
            );
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const XnoGlyph(size: 20, color: kAccent, weight: 0.16),
              const SizedBox(width: 8),
              const Text('Auto-settle policy', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              const Spacer(),
              Switch(
                  value: _autoSettle,
                  activeThumbColor: kAccent,
                  onChanged: (v) { setState(() => _autoSettle = v); setSheet(() {}); }),
            ]),
            const Text('Tips tally off-chain. When enabled, a creator’s tally auto-settles in one direct Nano send once it crosses the threshold — within your cap, non-custodial. Manual “Settle” is always available.',
                style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
            chips('Settle each creator at', [0.03, 0.05, 0.10], _autoThreshold, (o) => _autoThreshold = o),
            chips('Session cap (safety ceiling)', [0.50, 1.00, 5.00], _autoCap, (o) => _autoCap = o),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
              child: Text(
                  _autoSettle
                      ? 'On · auto-settled ${_autoSpent.toStringAsFixed(2)} / ${_autoCap.toStringAsFixed(2)} XNO this session'
                      : 'Off · tips wait for a manual Settle',
                  style: const TextStyle(color: kDim, fontSize: 12.5)),
            ),
          ]),
        );
      }),
    );
  }

  Future<void> _settle() async {
    if (_settleBusy || _settling.isNotEmpty) return;   // already settling (a double-tap, OR an auto-settle in flight) — both sign the same wallet frontier
    _settleBusy = true;
    try {
    _pending.remove(_account);   // a self-tip settles as send-to-yourself — drop it so it can't get stuck
    final entries = _pending.entries.toList();
    int paidCreators = 0, blocks = 0, failedCreators = 0, legShorts = 0;
    String? err;
    for (final e in entries) {
      final handle = _handleOf[e.key] ?? 'creator';
      final r = await Api.settle(e.key, e.value.toStringAsFixed(6),
          split: _settings.relaySplit, rsplit: _settings.reposterSplit,
          reposter: _reposterOf[e.key] ?? '', media: _mediaOf[e.key] ?? '');
      final legs = (r?['legs'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
      final creatorPaid = r != null && r['ok'] == true;
      if (creatorPaid) {
        paidCreators++;
        blocks += legs.where((l) => l['ok'] == true).length;
        if (legs.any((l) => l['role'] != 'creator' && l['ok'] == false)) legShorts++;
        // Persist the receipt — the tipper's own on-chain trail (roles, amounts, block hashes) — and
        // tell the creator the money actually MOVED (settle time), not just that a tally was pledged.
        await TxLogStore.add({
          'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'handle': handle, 'account': e.key,
          'total': e.value, 'paid': r['paid_xno'], 'legs': legs,
        });
        if (e.key != _account && _settings.notifyTip) {
          Api.notifyPush(e.key, _handle, 'tip', 'settled ${fmtXno(e.value)} XNO to you on-chain');
        }
        // Now that the creator leg is ON-CHAIN, report the tip again WITH its block hash so the relay
        // can verify it and credit the media's stored value. Before this, that value was a number in a
        // POST body that anyone could inflate to make their own content un-evictable (issue #5).
        final creatorHash = legs.firstWhere((l) => l['role'] == 'creator',
            orElse: () => const <String, dynamic>{})['hash'] as String?;
        final tippedCid = _mediaOf[e.key] ?? '';
        if (creatorHash != null && creatorHash.isNotEmpty && tippedCid.isNotEmpty) {
          Api.tipstat(tippedCid, _rawOf(e.value), payhash: creatorHash, cid: tippedCid);
        }
        // Subtract ONLY what we settled — a tip tallied to this creator DURING the awaited settle must
        // survive (removing the whole entry would drop it). Drain fully → clear the entry + its locks.
        setState(() {
          final rem = (_pending[e.key] ?? 0) - e.value;
          if (rem > 1e-9) {
            _pending[e.key] = rem;
          } else {
            _pending.remove(e.key); _reposterOf.remove(e.key); _mediaOf.remove(e.key);
          }
        });
      } else {
        failedCreators++;
        err ??= r?['error']?.toString() ??
            (legs.firstWhere((l) => l['role'] == 'creator', orElse: () => const {})['error']?.toString());
      }
    }
    await _refreshTxLog();
    await _refreshTxCount(); // your on-chain tx count just grew — update the header
    await _load(); // refresh the footprint meter
    if (!mounted) return;
    final msg = failedCreators == 0
        ? (legShorts == 0
            ? '✓ settled $paidCreators creator${paidCreators == 1 ? '' : 's'} · $blocks Nano block${blocks == 1 ? '' : 's'} on-chain'
            : '✓ paid $paidCreators · $legShorts split leg${legShorts == 1 ? '' : 's'} failed — see Transactions')
        : paidCreators > 0
            ? 'paid $paidCreators of ${entries.length} · $failedCreators unpaid (${err ?? 'failed'}) — still pending'
            : 'nothing settled — ${err ?? 'settle failed'}. Your tips are still pending.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: kCard, content: Text(msg)));
    } finally {
      _settleBusy = false;
    }
  }

  // The tipper's receipt trail, loaded from disk. See TxLogStore — the network notifies the RECIPIENT
  // of a tip, never the sender, so this on-device log is the only place a tipper can see (and verify
  // against the ledger) exactly what their settlements moved.
  List<Map<String, dynamic>> _txLog = [];
  Future<void> _refreshTxLog() async {
    final t = await TxLogStore.get();
    if (mounted) setState(() => _txLog = t);
  }

  // The header's "Nano txns" = the number of on-chain blocks on YOUR account chain (every settle / send /
  // receive you've made). Read from the ledger via account_state.block_count; grows as you settle tips.
  Future<void> _refreshTxCount() async {
    if (_account.isEmpty) return;
    final st = await Api.accountState(_account);
    final bc = (st?['block_count'] as num?)?.toInt();
    if (bc != null && mounted) setState(() => _onchainBlocks = bc);
  }

  // pull the set of online accounts into PresenceCache; AuthorAvatars repaint their green dots.
  Future<void> _refreshPresence() async {
    PresenceCache.I.update(await Api.presence());
  }

  // network-wide channel accounts — excluded from the Home/For-You feed so channels live only in the
  // Channels tab (their posts/articles are read there), not mixed into the personal timeline.
  Set<String> _channelAccounts = {};
  Future<void> _refreshChannelAccounts() async {
    final chs = await Api.channels();
    final next = chs.map((c) => '${c['account']}').toSet();
    if (mounted && !setEquals(next, _channelAccounts)) {
      setState(() => _channelAccounts = next);
    }
  }

  // A settled-tips history sheet: one card per settlement, each split leg with its amount, a ✓/✗ for
  // whether that Nano block actually landed, and the hash (tap to copy → paste into any explorer).
  void _showTransactions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7, minChildSize: 0.4, maxChildSize: 0.95, expand: false,
        builder: (_, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.receipt_long, size: 20, color: kAccent),
              const SizedBox(width: 8),
              const Text('Transactions', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              const Spacer(),
              Text('${_txLog.length}', style: const TextStyle(color: kDim, fontSize: 13)),
            ]),
            const SizedBox(height: 4),
            const Text('Tips you settled on-chain. Tap a block hash to copy it — paste into any Nano explorer to verify.',
                style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
            const SizedBox(height: 12),
            Expanded(
              child: _txLog.isEmpty
                  ? const Center(child: Text('No settlements yet.', style: TextStyle(color: kDim, fontSize: 13)))
                  : ListView.separated(
                      controller: scroll,
                      itemCount: _txLog.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _txCard(_txLog[i]),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _txCard(Map<String, dynamic> tx) {
    final legs = ((tx['legs'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final ts = (tx['ts'] as num?)?.toInt() ?? 0;
    final when = ts == 0 ? '' : DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal().toString().substring(0, 16);
    final paid = (tx['paid'] as num?)?.toDouble() ?? 0;
    final total = (tx['total'] as num?)?.toDouble() ?? paid;
    final short = paid + 1e-9 < total;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('@${tx['handle'] ?? 'creator'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 14))),
          Text('${paid.toStringAsFixed(3)} XNO', style: const TextStyle(color: kAccent, fontWeight: FontWeight.w800, fontSize: 14)),
        ]),
        if (when.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2),
            child: Text(when, style: const TextStyle(color: kDim, fontSize: 11))),
        const SizedBox(height: 8),
        ...legs.map((l) {
          final ok = l['ok'] == true;
          final hash = (l['hash'] as String?) ?? '';
          final xno = (l['xno'] as num?)?.toDouble() ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Icon(ok ? Icons.check_circle : Icons.cancel, size: 15, color: ok ? kAccent : Colors.redAccent),
              const SizedBox(width: 6),
              SizedBox(width: 64, child: Text('${l['role']}', style: const TextStyle(color: kDim, fontSize: 12))),
              Text('${xno.toStringAsFixed(3)}', style: const TextStyle(color: kText, fontSize: 12.5)),
              const SizedBox(width: 8),
              Expanded(
                child: ok && hash.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: hash));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              backgroundColor: kCard, duration: Duration(milliseconds: 1200),
                              content: Text('block hash copied')));
                        },
                        child: Text('${hash.substring(0, 12)}… ⧉',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kAccent, fontSize: 11, fontFamily: 'monospace')))
                    : Text(ok ? '' : '${l['error'] ?? 'failed'}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
              ),
            ]),
          );
        }),
        if (short) Padding(padding: const EdgeInsets.only(top: 2),
            child: Text('creator paid; a split leg did not land — retry available next settle',
                style: TextStyle(color: Colors.orangeAccent.shade100, fontSize: 11))),
      ]),
    );
  }

  // The settle menu: opened deliberately from the header tips icon, not always on screen. Lists the
  // off-chain tallies, then one tap sends a direct Nano block per creator — with a live spinner so it
  // never looks frozen while proof-of-work runs, and the result reported when it lands.
  void _showSettle() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      isScrollControlled: true,
      builder: (_) {
        bool settling = false;                           // persists across StatefulBuilder rebuilds
        return StatefulBuilder(builder: (ctx, setSheet) {
          _pending.remove(_account);   // hide any self-tip: it can't settle (send-to-self), so never list it
          final entries = _pending.entries.toList();
          final total = _pending.values.fold<double>(0, (a, b) => a + b);
          return Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 22 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const XnoGlyph(size: 20, color: kAccent, weight: 0.16),
                const SizedBox(width: 8),
                const Text('Tips to settle', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                IconButton(
                  onPressed: () { Navigator.pop(ctx); _showTransactions(); },
                  icon: const Icon(Icons.receipt_long, size: 20, color: kDim),
                  tooltip: 'Transactions',
                ),
                IconButton(
                  onPressed: () { Navigator.pop(ctx); _showAutoSettle(); },
                  icon: Icon(Icons.tune, size: 20, color: _autoSettle ? kAccent : kDim),
                  tooltip: 'Auto-settle policy',
                ),
              ]),
              Text(
                  _autoSettle
                      ? 'Tips tally off-chain. Auto-settle is on (≥${fmtXno(_autoThreshold)} XNO each). Settle the rest now, or leave them to accrue.'
                      : 'Tips tally off-chain — nothing has moved yet. Settling sends one direct Nano block to each creator.',
                  style: const TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 14),
              if (entries.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 26),
                    child: Center(child: Text('No tips waiting — tip a post and it collects here.',
                        style: TextStyle(color: kDim, fontSize: 13))))
              else ...[
                ...entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Row(children: [
                        Expanded(child: Text('@${_handleOf[e.key] ?? 'creator'}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w600))),
                        Text('${fmtXno(e.value)} XNO',
                            style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700, fontSize: 14)),
                        // Undo this whole pending tally — a change of mind before it settles on-chain.
                        // Nothing has moved yet, so it just drops the pledge.
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.undo, size: 18, color: kDim),
                          tooltip: 'Undo tip',
                          onPressed: () {
                            final amt = e.value;
                            setState(() => _pending.remove(e.key));   // drop the pledge (FeedScreen state)
                            setSheet(() {});                           // rebuild the sheet list
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                backgroundColor: kCard, duration: const Duration(milliseconds: 1500),
                                content: Text('↩ undone — ${fmtXno(amt)} XNO not tallied')));
                          },
                        ),
                      ]),
                    )),
                const Divider(color: kLine, height: 22),
                Row(children: [
                  Text('${entries.length} creator${entries.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: kDim, fontSize: 12)),
                  const Spacer(),
                  Text('${fmtXno(total)} XNO total',
                      style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                            // Nautilus-style: acknowledge instantly and settle on-chain in the BACKGROUND,
                            // so the user isn't held on a spinner through the multi-second PoW + broadcast.
                            // _settle() (guarded by _settleBusy) posts the final result when the blocks land.
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                backgroundColor: kCard,
                                content: Text('◈ Tip sent — settling ${fmtXno(total)} XNO on-chain in the background…')));
                            _settle();
                          },
                    style: FilledButton.styleFrom(
                        backgroundColor: kAccent, foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                    child: Text('Settle ${fmtXno(total)} XNO',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(settling ? 'signing on-device · delegating proof-of-work…'
                              : 'mainnet · real XNO · PoW delegated · one direct send per creator',
                    textAlign: TextAlign.center, style: const TextStyle(color: kDim, fontSize: 11)),
              ],
            ]),
          );
        });
      },
    );
  }

  // ---- reputation-weighted, earned + decaying (ported from the KeelTube client) ----
  double _recency(Labeler l) {
    if (l.lastTs == 0) return 0.01;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return math.pow(0.5, (now - l.lastTs) / _halflife).toDouble();
  }

  double _accuracy(Labeler l) {
    final posts = l.flags.keys.toList();
    if (posts.isEmpty) return 0;
    double s = 0;
    for (final pid in posts) {
      final others = _labelers.where((o) => o != l);
      final tot = others.fold<double>(0, (a, o) => a + o.stake);
      final agree = others
          .where((o) => o.flags.containsKey(pid))
          .fold<double>(0, (a, o) => a + o.stake);
      s += tot > 0 ? agree / tot : 0;
    }
    return s / posts.length;
  }

  double _eff(Labeler l) => l.stake * _recency(l) * (0.25 + 0.75 * _accuracy(l));

  PostMod _mod(String postId) {
    final th = _thresh[_modIdx];
    if (th > 1) return PostMod([], 0, false, '', ''); // moderation off
    final flaggers =
        _labelers.where((l) => l.flags.containsKey(postId)).toList();
    if (flaggers.isEmpty) return PostMod([], 0, false, '', '');
    // Community reports carry a per-post fraction (distinct reporters / quorum); use the strongest.
    // Fall back to the reputation-weighted labeler share for any labeler that doesn't provide one.
    final perPost = flaggers
        .map((l) => (l.flags[postId]!['frac'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
    double frac;
    if (perPost.isNotEmpty) {
      frac = perPost.reduce((a, b) => a > b ? a : b);
    } else {
      final tot = _labelers.fold<double>(0, (a, l) => a + _eff(l));
      frac = tot > 0 ? flaggers.fold<double>(0, (a, l) => a + _eff(l)) / tot : 0.0;
    }
    final hide = frac >= th && !_shown.contains(postId);
    final v = flaggers.first.flags[postId]!['verdict'];
    final reason =
        flaggers.map((l) => '${l.flags[postId]!['reason']}').where((s) => s.isNotEmpty).join(' · ');
    return PostMod(flaggers, frac, hide, v ?? '', reason);
  }

  void _cycleMod() => setState(() => _modIdx = (_modIdx + 1) % _thresh.length);

  // unique authors across the feed (for Discover)
  List<Map<String, String>> _authors() {
    final seen = <String>{};
    final out = <Map<String, String>>[];
    for (final p in _posts) {
      // exclude only YOUR OWN account (and muted/blocked) — not the default "you.xno" handle, or Discover
      // is empty whenever everyone still shares that default handle (they're told apart by their acctTag).
      if (p.account.isNotEmpty && p.account != _account && !_hidden(p.account) && seen.add(p.account)) {
        out.add({'account': p.account, 'handle': p.handle});
      }
    }
    out.sort((a, b) => a['handle']!.compareTo(b['handle']!));
    return out;
  }

  // Home shows the people you follow (+ your own posts); everyone if you follow no one yet
  List<Post> _homePosts() {
    // STRICT Following: ONLY the accounts you follow — not your own posts (those live on your profile
    // and in For You). Follow nobody → empty, and the feed shows a discover prompt instead of falling
    // back to everyone. Roots only (replyTo == null) — replies render NESTED under their parent.
    if (_follows.isEmpty) return const [];
    return _posts
        .where((p) =>
            _follows.contains(p.account) &&
            !_reported.contains(p.id) &&
            !_hidden(p.account) &&
            !_hasMutedWord(p) &&
            !_channelAccounts.contains(p.account) && // channels have their own tab
            p.replyTo == null)
        .toList();
  }

  // ---- "For You": a TRANSPARENT, tunable ranking (unlike a black-box algorithm) ----
  // score = engagement (likes ×1, reposts ×2, comments ×1.5, tips ×20) blended with recency,
  // plus a boost for people you follow. The freshness setting shifts the engagement↔recency mix.
  double _score(Post p) {
    final e = _eng(p.id);
    final likes = ((e['likes'] ?? 0) as num).toDouble();
    final reposts = ((e['reposts'] ?? 0) as num).toDouble();
    final tips = ((e['tips_xno'] ?? 0) as num).toDouble();
    final comments = (_commentCount[p.id] ?? 0).toDouble();
    final engagement = likes * 1.0 + reposts * 2.0 + comments * 1.5 + tips * 20.0;
    final ageHours = (DateTime.now().millisecondsSinceEpoch / 1000 - p.ts) / 3600.0;
    final recency = 1.0 / (1.0 + (ageHours < 0 ? 0 : ageHours)); // 1.0 fresh → 0 as it ages
    // freshness mix: 0 popular, 1 balanced, 2 latest
    const engW = [1.0, 0.6, 0.2];
    const recW = [3.0, 8.0, 20.0];
    final f = _settings.forYouFreshness.clamp(0, 2);
    final affinity = (_settings.forYouBoostFollows && _follows.contains(p.account)) ? 3.0 : 0.0;
    return engagement * engW[f] + recency * recW[f] + affinity + (p.account == _account ? 0.5 : 0);
  }

  // A post is filtered if it contains one of the viewer's hidden words (Threads-style, viewer-only).
  bool _hasMutedWord(Post p) {
    if (_mutedWords.isEmpty) return false;
    final t = '${p.text} ${p.title ?? ''}'.toLowerCase();
    for (final w in _mutedWords) {
      final ww = w.trim().toLowerCase();
      if (ww.isNotEmpty && t.contains(ww)) return true;
    }
    return false;
  }

  // ranked feed across everyone (minus muted/blocked/reported/hidden-words), highest score first
  List<Post> _forYouPosts() {
    final list = _posts
        .where((p) => !_reported.contains(p.id) && !_hidden(p.account) && p.replyTo == null &&
            !_hasMutedWord(p) &&
            !_channelAccounts.contains(p.account)) // channels live in the Channels tab, not the feed
        .toList();
    list.sort((a, b) => _score(b).compareTo(_score(a)));
    return list;
  }

  // ---- engagement (relay-backed likes/reposts + XNO gathered per post) ----
  Map<String, dynamic> _eng(String pid) {
    final e = _engage[pid];
    return e is Map ? Map<String, dynamic>.from(e) : {'likes': 0, 'reposts': 0, 'tips_xno': 0};
  }


  String _rawOf(double xno) => Api._xnoToRaw(xno.toStringAsFixed(6)).toString(); // XNO(6dp) -> raw string (supports sub-0.01 tips)

  void _bumpEngage(String pid, String field, num delta) {
    final e = _eng(pid);
    e[field] = ((e[field] ?? 0) as num) + delta;
    _engage[pid] = e;
  }

  void _toggleLike(Post p) {
    final liked = _liked.contains(p.id);
    setState(() {
      liked ? _liked.remove(p.id) : _liked.add(p.id);
      _bumpEngage(p.id, 'likes', liked ? -1 : 1);
    });
    Api.like(p.id, liked ? -1 : 1);
    EngageStore.saveLiked(_liked); // persist so this device's like counts once (no re-like each session)
    if (!liked && p.account != _account && _settings.notifyLike) {
      Api.notifyPush(p.account, _handle, 'like',
          'liked: ${p.text.length > 40 ? '${p.text.substring(0, 40)}…' : p.text}');
    }
  }

  void _toggleRepost(Post p) {
    final rp = _reposted.contains(p.id);
    setState(() {
      rp ? _reposted.remove(p.id) : _reposted.add(p.id);
      _bumpEngage(p.id, 'reposts', rp ? -1 : 1);
    });
    Api.repost(p.id, rp ? -1 : 1, _account); // record WHO reshared (reward attribution)
    EngageStore.saveReposted(_reposted); // persist so this device's repost counts once
    if (!rp && p.account != _account) {
      Api.notifyPush(p.account, _handle, 'repost', 'reposted your post');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text('🔁 reposted — spreads to your followers; you earn a cut of its future tips')));
    }
  }

  // count one impression per post/comment per session (fire-and-forget; shows on next refresh)
  void _countView(String id) {
    if (id.isNotEmpty && _viewed.add(id)) { Api.view(id); EngageStore.saveViewed(_viewed); }
  }

  // build a fully-wired post card (reused by the profile screen's Posts/Media tabs)
  Widget _profileCard(Post post, {bool expanded = false}) {
    _countView(post.id); // this card is being rendered → an impression
    final mod = _mod(post.id);
    if (mod.hide) {
      return HiddenPostTile(post: post, mod: mod, onShow: () => setState(() => _shown.add(post.id)));
    }
    return PostCard(
        post: post,
        expanded: expanded,
        softFlag: mod,
        pending: _pending[post.account] ?? 0,
        engage: _eng(post.id),
        liked: _liked.contains(post.id),
        reposted: _reposted.contains(post.id),
        commentCount: _commentCount[post.id] ?? 0,
        quoted: _postById(post.quote),
        inThread: _inThread(post),
        repostedBy: _firstResharer(post).isEmpty ? '' : '@${_handleFor(_firstResharer(post))}',
        onTip: () => _tallyTip(post),
        onLike: () => _toggleLike(post),
        onRepost: () => _toggleRepost(post),
        onReport: () => _reportPost(post),
        onComment: () => _openComments(post),
        onReply: () => _compose(replyToPost: post),                 // X-style reply → new post w/ reply_to
        // count the WHOLE thread below this post (transitive), incl. buffered new posts — a reply chain
        // shows its true size, not just direct children (which read as "1" on a multi-deep thread).
        replyCount: _threadReplyCount(post.id),
        replyingToHandle: post.replyTo == null ? '' : (_postById(post.replyTo)?.handle ?? ''),
        onQuote: () => _quotePost(post),
        onOpenThread: () => _openThread(post),
        // A handle resolves to an account only here, where the feed's view of who is who lives.
        onTapHandle: (h) {
          final want = h.toLowerCase();
          final hit = _knownHandles().entries
              .where((e) => e.value.toLowerCase() == want)
              .map((e) => e.key);
          if (hit.isNotEmpty) {
            _openProfile(hit.first, h);
          } else {
            // Unknown handle: fall back to search rather than doing nothing, since the person may
            // simply not be in the posts we currently hold.
            _openDiscover('@$h');
          }
        },
        onTapTag: (t) => _openDiscover('#$t'),
        onOpenProfile: () => _openProfile(post.account, post.handle),
        muted: _muted.contains(post.account),
        blocked: _blocked.contains(post.account),
        bookmarked: _bookmarks.contains(post.id),
        onBookmark: () => _toggleBookmark(post),
        onPin: (post.media != null && post.media!.isNotEmpty) ? () => _pinPost(post) : null,
        onMute: post.account == _account ? null : () => _toggleMute(post.account, post.handle),
        onBlock: post.account == _account ? null : () => _toggleBlock(post.account, post.handle),
        onDelete: post.account == _account ? () => _deletePost(post) : null,   // your own posts only
        onEdit: (post.account == _account && post.kind == 'post') ? () => _editPost(post) : null,
        onPinProfile: post.account == _account ? () => _pinToProfile(post) : null);
  }

  // ---- threads: posts chained by reply_to ----
  Post? _postById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final p in _posts) { if (p.id == id) return p; }
    return null;
  }

  bool _inThread(Post p) =>
      (p.replyTo != null && p.replyTo!.isNotEmpty) || _posts.any((x) => x.replyTo == p.id);

  // Count EVERY reply in the thread below a post (transitive), not just direct children. Replies chain
  // (A <- B <- C), so a direct-only count shows 1 on a 3-deep thread — which reads as "several comments
  // but it says 1". Walks children across the loaded feed + the buffered new posts. Guards against a
  // cycle with `seen`. O(n) over loaded posts; the feed is small, and it's only called per visible card.
  int _threadReplyCount(String rootId) {
    final kids = <String, List<String>>{};
    for (final p in [..._posts, ..._newPosts]) {
      final parent = p.replyTo;
      if (parent != null && parent.isNotEmpty) (kids[parent] ??= []).add(p.id);
    }
    final seen = <String>{};
    final stack = <String>[rootId];
    var n = 0;
    while (stack.isNotEmpty) {
      for (final child in (kids[stack.removeLast()] ?? const [])) {
        if (seen.add(child)) { n++; stack.add(child); }
      }
    }
    return n;
  }

  // Every reply in the thread below a post, in reading order (depth-first, oldest-first at each level).
  // Used to render replies NESTED under their parent in the feed. Spans the loaded feed + new posts.
  List<Post> _threadReplies(String rootId) {
    final kids = <String, List<Post>>{};
    for (final p in [..._posts, ..._newPosts]) {
      final parent = p.replyTo;
      if (parent != null && parent.isNotEmpty) (kids[parent] ??= []).add(p);
    }
    final out = <Post>[];
    final seen = <String>{};
    void walk(String id) {
      final cs = (kids[id] ?? [])..sort((a, b) => a.ts.compareTo(b.ts));
      for (final c in cs) {
        if (seen.add(c.id)) { out.add(c); walk(c.id); }
      }
    }
    walk(rootId);
    return out;
  }


  Post _threadRoot(Post p) {
    var cur = p;
    final seen = <String>{};
    while (cur.replyTo != null && cur.replyTo!.isNotEmpty && !seen.contains(cur.id)) {
      seen.add(cur.id);
      final parent = _postById(cur.replyTo);
      if (parent == null) break;
      cur = parent;
    }
    return cur;
  }

  // root + ALL its descendants in reading order. Uses the same transitive DFS walk as the feed count
  // (_threadReplies), so a BRANCHED thread — two replies to the same post, a reply to a reply — shows
  // every message. (The old walk only extended from the last-added node, dropping sibling branches.)
  List<Post> _threadChain(Post root) => [root, ..._threadReplies(root.id)];

  void _openThread(Post p) {
    if (p.kind == 'article') { _openArticle(p); return; }   // long-form → full-screen reader
    final root = _threadRoot(p);
    final chain = _threadChain(root);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
          title: const Text('Thread', style: TextStyle(color: kText, fontWeight: FontWeight.w800))),
      body: ListView.separated(
        itemCount: chain.length,
        separatorBuilder: (_, __) => Container(color: kLine, height: 1),
        // the focused (root) post shows its full text; replies keep the compact "Show more" behaviour
        itemBuilder: (_, i) => _profileCard(chain[i], expanded: i == 0),
      ),
    )));
  }

  // full-screen article reader: cover + title + author + markdown body + engagement (reuses feed handlers)
  void _openArticle(Post p) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
          title: const Text('Article', style: TextStyle(color: kText, fontWeight: FontWeight.w800))),
      body: ListView(children: [
        if (p.media != null && p.media!.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SizedBox(
                width: double.infinity,
                child: MediaImage(
                    cid: p.media!, fit: BoxFit.cover, label: 'Header image of an article by ${p.handle}')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title ?? '',
                style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 26, height: 1.25)),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => _openProfile(p.account, p.handle),
              child: Row(children: [
                AuthorAvatar(account: p.account, handle: p.handle, radius: 18),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AnimatedBuilder(
                      animation: ProfileCache.I,
                      builder: (_, __) => Text(ProfileCache.I.displayName(p.account, p.handle),
                          style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15))),
                  Text('@${p.handle} · ${timeAgo(p.ts)}', style: const TextStyle(color: kDim, fontSize: 12.5)),
                ]),
              ]),
            ),
            const SizedBox(height: 18),
            MarkdownBody(
              data: p.text,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(color: kText, fontSize: 17, height: 1.6),
                h1: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 24, height: 1.3),
                h2: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 20, height: 1.3),
                h3: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 18),
                a: const TextStyle(color: kAccent),
                blockquote: const TextStyle(color: kDim, fontSize: 16, height: 1.5),
                code: const TextStyle(color: kAccent, fontFamily: 'monospace'),
                listBullet: const TextStyle(color: kText, fontSize: 17),
              ),
            ),
            const SizedBox(height: 24),
            Container(height: 1, color: kLine),
            const SizedBox(height: 12),
            _readerActionRow(p),
          ]),
        ),
        // Comments below the article. Channels post ARTICLES, and the reader used to show only the body —
        // so a channel post's replies were invisible ("channels don't show the comments"). Render the
        // conversation here, the same reply-posts a normal post shows in its thread view.
        Container(height: 8, color: kBg),
        Container(height: 1, color: kLine),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: Row(children: [
            Icon(Icons.mode_comment_outlined, color: kAccent, size: 18),
            SizedBox(width: 8),
            Text('Comments', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 16)),
          ]),
        ),
        Builder(builder: (_) {
          final replies = _threadReplies(p.id);
          if (replies.isEmpty) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 30),
              child: Text('No comments yet — tap the reply icon above to be the first.',
                  style: TextStyle(color: kDim, fontSize: 13.5)));
          }
          return Column(children: [
            for (final r in replies) ...[Container(color: kLine, height: 1), _profileCard(r)],
          ]);
        }),
      ]),
    )));
  }

  Widget _readerActionRow(Post p) {
    final e = _eng(p.id);
    final liked = _liked.contains(p.id);
    final reposted = _reposted.contains(p.id);
    final tips = (e['tips_xno'] is num) ? (e['tips_xno'] as num).toDouble() : 0.0;
    Widget act(IconData ic, String label, Color c, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(children: [
              Icon(ic, size: 20, color: c),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: c, fontSize: 13.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      act(liked ? Icons.favorite : Icons.favorite_border, '${e['likes'] ?? 0}', liked ? kAccent : kDim,
          () => _toggleLike(p)),
      act(Icons.mode_comment_outlined, '${_commentCount[p.id] ?? 0}', kDim, () => _openComments(p)),
      act(Icons.repeat, '${e['reposts'] ?? 0}', reposted ? kAccent : kDim, () => _toggleRepost(p)),
      act(Icons.bolt, tips > 0 ? 'Ӿ ${tips.toStringAsFixed(2)}' : 'Tip', kAccent, () => _tallyTip(p)),
    ]);
  }

  // ---- CHANNELS: seed-derived publishing identities (like Medium publications) ----
  List<String> _myChannels = [];
  Future<void> _loadChannels() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _myChannels = p.getStringList('xchat_channels') ?? []);
  }
  Future<void> _saveChannels() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('xchat_channels', _myChannels);
  }

  String _channelHandle(String name) => name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  InputDecoration _chanDeco(String hint) => InputDecoration(
        hintText: hint, hintStyle: const TextStyle(color: kDim), counterText: '',
        enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: kLine)),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: kAccent)),
      );

  void _createChannel() {
    final nameCtl = TextEditingController();
    final descCtl = TextEditingController();
    final picker = ImagePicker();
    String avatarCid = '';
    bool saving = false, uploadingA = false;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> pickAvatar() async {
          final x = await picker.pickImage(
              source: ImageSource.gallery, maxWidth: 480, maxHeight: 480, imageQuality: 82);
          if (x == null) return;
          setSheet(() => uploadingA = true);
          final bytes = await x.readAsBytes();
          final cid = await Api.blobPut(bytes);
          setSheet(() { if (cid != null) avatarCid = cid; uploadingA = false; });
        }
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('New channel', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 4),
              const Text('A publication with its own identity — restorable from your seed, followable by anyone.',
                  style: TextStyle(color: kDim, fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 16),
              // channel photo — the publication's avatar (a content-addressed blob, like a profile picture)
              Row(children: [
                GestureDetector(
                  onTap: uploadingA ? null : pickAvatar,
                  child: Container(
                    width: 64, height: 64, clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: kCard, border: Border.all(color: kLine)),
                    child: uploadingA
                        ? const Center(child: SizedBox(height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
                        : (avatarCid.isEmpty
                            ? const Icon(Icons.add_a_photo_outlined, color: kDim, size: 24)
                            : MediaImage(cid: avatarCid, fit: BoxFit.cover)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(avatarCid.isEmpty ? 'Add a channel photo (optional)' : 'Photo added — tap to change',
                    style: const TextStyle(color: kDim, fontSize: 13))),
              ]),
              const SizedBox(height: 14),
              TextField(controller: nameCtl, maxLength: 40, style: const TextStyle(color: kText, fontSize: 15),
                  decoration: _chanDeco('Channel name')),
              const SizedBox(height: 8),
              TextField(controller: descCtl, maxLength: 160, minLines: 2, maxLines: 3,
                  style: const TextStyle(color: kText, fontSize: 15), decoration: _chanDeco('Description')),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: saving ? null : () async {
                  final name = nameCtl.text.trim();
                  final w = gWallet;
                  if (name.isEmpty || w == null || _myChannels.contains(name)) { Navigator.pop(ctx); return; }
                  setSheet(() => saving = true);
                  final ch = w.channelWallet(name);
                  await Api.profileSet(name, descCtl.text.trim(), avatarCid, '', signer: ch, type: 'channel');
                  // surface the new channel's name/photo everywhere at once (don't wait for a relay round-trip)
                  ProfileCache.I.put(ch.account, {'display': name, 'bio': descCtl.text.trim(), 'avatar': avatarCid});
                  setState(() => _myChannels.add(name));
                  await _saveChannels();
                  if (!_follows.contains(ch.account)) { _follows.add(ch.account); _publishFollows(); }
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      backgroundColor: kCard, content: Text('channel created — publish articles under it')));
                },
                style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                child: Text(saving ? 'Creating…' : 'Create channel', style: const TextStyle(fontWeight: FontWeight.w800)),
              )),
            ]),
          ),
        );
      }),
    );
  }

  void _openChannels() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
          title: const Text('Channels', style: TextStyle(color: kText, fontWeight: FontWeight.w800)),
          actions: [IconButton(icon: const Icon(Icons.add, color: kAccent),
              onPressed: () { Navigator.pop(context); _createChannel(); }, tooltip: 'New channel')]),
      body: _myChannels.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(32),
              child: Text('No channels yet.\nCreate one to publish articles under a publication identity.',
                  textAlign: TextAlign.center, style: TextStyle(color: kDim, height: 1.6))))
          : ListView(children: [
              for (final name in _myChannels)
                ListTile(
                  leading: AuthorAvatar(account: gWallet?.channelWallet(name).account ?? '',
                      handle: _channelHandle(name), radius: 20),
                  title: Text(name, style: const TextStyle(color: kText, fontWeight: FontWeight.w700)),
                  subtitle: Text('@${_channelHandle(name)}', style: const TextStyle(color: kDim, fontSize: 12.5)),
                  trailing: const Icon(Icons.chevron_right, color: kDim),
                  onTap: () => _openProfile(gWallet?.channelWallet(name).account ?? '', _channelHandle(name)),
                ),
            ]),
    )));
  }

  // open an author's profile page
  void _openProfile(String account, String handle) {
    if (account.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(
      account: account,
      handle: handle,
      isMe: account == _account,
      allPosts: _posts,
      cardBuilder: _profileCard,
      isFollowing: _follows.contains(account),
      onToggleFollow: () => _toggleFollow(account),
      onEdit: _showEditProfile,
      onMessage: () => _openChat(account, handle),
    )));
  }

  // resolve an account to a handle (feed authors → cache → truncated account)
  String _handleFor(String account) {
    if (account == _account) return _handle;
    for (final p in _posts) { if (p.account == account) return p.handle; }
    if (_handleOf.containsKey(account)) return _handleOf[account]!;
    return account.isEmpty ? 'anon' : '${account.substring(0, 12)}…';
  }

  void _openDms() {
    // Opening the inbox marks everything up to now as seen, so the mail badge clears. Floor it at the
    // newest incoming DM the badge already knows about: a DM carries the SENDER's clock time, which can
    // run ahead of ours, so `now` alone would leave a just-arrived (already-read) DM counted as unread.
    final nowTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seenTs = nowTs > _dmNewestInTs ? nowTs : _dmNewestInTs;
    _dmSeenTs = seenTs;
    SharedPreferences.getInstance().then((sp) => sp.setInt('dm_seen_ts', seenTs));
    setState(() => _dmUnread = 0);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmInboxScreen(
      handleOf: _handleFor,
      isBlocked: (acc) => _blocked.contains(acc), // blocked people's DMs don't reach you
      onOpen: (acc, h) => _openChat(acc, h),
    )));
  }

  // Count conversations whose newest INCOMING message is newer than the last time DMs were opened.
  // Runs on launch and on the same quiet cadence as the feed, so a DM that arrives while you're in the
  // app lights the mail icon on its own (matching the bell). Best-effort: a failed poll leaves it as-is.
  // AUTO-RECEIVE. Nano credits you by leaving a "receivable" block that the recipient must claim; the
  // balance reads low until they do. Every real wallet hides this — Nault defaults to
  // "Receive Method: automatic" and keeps manual mainly for hardware wallets. We had only a button,
  // and a user watched 13.3 XNO sit unclaimed because nothing said it was there or that pressing
  // anything would help.
  //
  // Note this is NOT gated on _needsBackup, unlike the manual button. That gate reads as "don't put
  // funds into an unrecoverable wallet", but the funds are ALREADY assigned to this account on-chain:
  // claiming them changes nothing about whether losing the seed loses the money. Blocking the claim
  // protects nothing and just hides value the user already owns. The backup nag stays; the money
  // arrives either way.
  bool _autoReceiving = false;
  Future<void> _autoReceive() async {
    if (_autoReceiving || gWallet == null || !_settings.autoReceive) return;
    _autoReceiving = true;
    try {
      final waiting = await Api.receivableTotal();
      if (waiting == BigInt.zero) return;               // nothing above the dust floor
      if (mounted) setState(() => _incomingRaw = waiting);
      final r = await Api.receive();
      final n = (r?['received'] ?? 0) as int;
      if (n > 0) {
        await _load();
        if (mounted) {
          setState(() => _incomingRaw = BigInt.zero);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              backgroundColor: kCard,
              content: Text('⬇ received ${(waiting / BigInt.from(10).pow(30)).toStringAsFixed(5)} XNO')));
        }
      }
    } catch (_) {
    } finally {
      _autoReceiving = false;
      if (mounted) setState(() => _incomingRaw = BigInt.zero);
    }
  }

  /// Fetch the next page of OLDER posts and append. Guarded against re-entry, because a scroll can
  /// cross the trigger many times before the first request returns and each one would refetch the
  /// same page.
  Future<void> _loadMore() async {
    if (_loadingMore || !Api.feedHasMore || _posts.isEmpty) return;
    _loadingMore = true;
    try {
      final oldest = _posts.map((p) => p.ts).reduce((a, b) => a < b ? a : b);
      final fd = await Api.feed(limit: _pageSize, before: oldest);
      if (!mounted || fd.posts.isEmpty) return;
      // De-dupe by id: a post can arrive in a page AND in the incremental poll, and appending both
      // would show it twice.
      final have = {for (final p in _posts) p.id};
      final add = [for (final p in fd.posts) if (!have.contains(p.id)) p];
      if (add.isEmpty) return;
      setState(() => _posts = [..._posts, ...add]);
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _refreshDmBadge() async {
    if (gWallet == null) return;
    try {
      final convos = await Api.dmInbox();
      var unread = 0;
      var newestIn = _dmNewestInTs;                // track the newest incoming ts across all convos
      final fresh = <Map<String, dynamic>>[];     // newest incoming per conversation, for alerting
      for (final c in convos) {
        final msgs = (c['messages'] as List?) ?? const [];
        var lastIn = 0;
        var lastText = '';
        for (final m in msgs) {
          // Skip control (read receipts, reactions) and group-plumbing messages: they arrive as
          // incoming records but are NOT a message the user sent. Counting them lit the mail badge and
          // pushed a notification whenever a peer merely opened the thread or reacted — with the raw
          // `xchat:ctl/1 read {...}` machine line as the preview text. hiddenInDm is the same filter the
          // thread view uses to hide them.
          if ((m as Map)['outgoing'] != true && !hiddenInDm('${m['text'] ?? ''}')) {
            final ts = (m['ts'] ?? 0) as int;
            if (ts > lastIn) { lastIn = ts; lastText = '${m['text'] ?? ''}'; }
          }
        }
        if (lastIn > newestIn) newestIn = lastIn;
        if (lastIn > _dmSeenTs) unread++;
        if (lastIn > 0) fresh.add({'peer': c['peer'], 'ts': lastIn, 'text': lastText});
      }
      _dmNewestInTs = newestIn;                     // remembered so _openDms can floor "seen" at it
      // Only rebuild when the number actually MOVED. This runs inside the 12s feed poll, and an
      // unconditional setState here rebuilt the entire home screen — feed, avatars and all — four
      // times a minute to redraw an identical badge. That is invisible in a screenshot diff (the
      // pixels match) and very visible on a phone.
      if (mounted && unread != _dmUnread) setState(() => _dmUnread = unread);
      Notifs.setBadge(unread);   // unread-DM count on the launcher icon
      await _alertNewDms(fresh);
    } catch (_) {}
  }

  // Raise an Android alert for a DM that arrived since the last check. Until now a new message only
  // ever moved a silent badge, so unless you happened to look at the app you did not know.
  //
  // Deliberately LOCAL. Likes, comments and tips route through the relay's notify queue, and it would
  // have been less code to do the same here — but that queue stores {from, to, ts} in the clear, so
  // every DM would publish "A messaged B at T" to a relay. That metadata does not exist today, and
  // withholding it is most of the point of sealing the messages. The app already polls and decrypts,
  // so it has everything it needs; the preview is built from plaintext that never leaves the device.
  Future<void> _alertNewDms(List<Map<String, dynamic>> fresh) async {
    final p = await SharedPreferences.getInstance();
    final seen = p.getInt('dm_alert_ts') ?? -1;
    var maxTs = seen < 0 ? 0 : seen;
    for (final f in fresh) {
      final ts = f['ts'] as int;
      if (ts > maxTs) maxTs = ts;
    }
    if (seen < 0) {                    // first run: baseline, don't alert for the entire history
      await p.setInt('dm_alert_ts', maxTs);
      return;
    }
    if (_settings.notifyDm) {
      for (final f in fresh) {
        final ts = f['ts'] as int;
        if (ts <= seen) continue;
        final peer = '${f['peer']}';
        final name = ProfileCache.I.displayName(peer, '');
        Notifs.show('dm$peer$ts'.hashCode & 0x7fffffff,
            name.trim().isEmpty ? '💬 New message' : '💬 $name', _dmPreview('${f['text']}'));
      }
    }
    if (maxTs > seen) await p.setInt('dm_alert_ts', maxTs);
  }

  // The shade should show the message, not our wire format: drop quote lines and turn an attachment
  // marker into "📷 Photo" (plus its caption) rather than printing a cid at the reader.
  String _dmPreview(String text) {
    var s = text.split('\n').where((l) => !l.startsWith('>')).join(' ').trim();
    if (s.startsWith(Api.dmImgOnceTag)) {
      final sp = s.indexOf(' ');
      final rest = sp < 0 ? '' : s.substring(sp + 1).trim();
      s = rest.isEmpty ? '⏱ Disappearing photo' : '⏱ $rest';
    } else if (s.startsWith(Api.dmImgTag)) {
      final sp = s.indexOf(' ');
      final rest = sp < 0 ? '' : s.substring(sp + 1).trim();
      s = rest.isEmpty ? '📷 Photo' : '📷 $rest';
    }
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  Future<void> _openChat(String account, String handle) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DmChatScreen(peer: account, handle: handle, myAccount: _account)));
  }

  // load our own profile into the cache on start (so avatars/name show everywhere)
  Future<void> _initProfile() async {
    if (_account.isEmpty) return;
    final p = await Api.profileGet(_account);
    if (p != null && '${p['display'] ?? ''}'.trim().isNotEmpty) {
      ProfileCache.I.put(_account, p);
      return;
    }
    // Our signed profile didn't verify (its record predates the current signing scheme), so our name
    // shows as the default handle. AUTO-HEAL: recover the display name from the raw relay record and
    // re-publish it signed under the current scheme — so names come back on their own after a migration,
    // no manual re-entry. Only our OWN account, and only when the raw record is actually ours.
    final raw = await Api.profileRaw(_account);
    final display = '${raw?['display'] ?? ''}'.trim();
    if (raw != null && raw['account'] == _account && display.isNotEmpty) {
      await Api.profileSet(display, '${raw['bio'] ?? ''}', '${raw['avatar'] ?? ''}', '${raw['banner'] ?? ''}');
      final fresh = await Api.profileGet(_account);
      if (fresh != null) ProfileCache.I.put(_account, fresh);
    } else if (p != null) {
      ProfileCache.I.put(_account, p);
    }
  }

  // edit-profile sheet: display name, bio, pick avatar/banner → upload (content-addressed) → publish
  void _showEditProfile() {
    final prof = ProfileCache.I.of(_account) ?? {};
    final nameCtl = TextEditingController(text: '${prof['display'] ?? ''}');
    final bioCtl = TextEditingController(text: '${prof['bio'] ?? ''}');
    String avatar = '${prof['avatar'] ?? ''}';
    String banner = '${prof['banner'] ?? ''}';
    bool saving = false, uploadingA = false, uploadingB = false;
    final picker = ImagePicker();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> pick(bool isAvatar) async {
          final x = await picker.pickImage(
              source: ImageSource.gallery,
              maxWidth: isAvatar ? 480 : 1200, maxHeight: isAvatar ? 480 : 600, imageQuality: 82);
          if (x == null) return;
          setSheet(() { if (isAvatar) uploadingA = true; else uploadingB = true; });
          final bytes = await x.readAsBytes();
          final cid = await Api.blobPut(bytes);
          setSheet(() {
            if (isAvatar) { if (cid != null) avatar = cid; uploadingA = false; }
            else { if (cid != null) banner = cid; uploadingB = false; }
          });
        }

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Edit profile', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                if (saving) const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
              ]),
              const SizedBox(height: 14),
              // banner + avatar preview with pick buttons
              GestureDetector(
                onTap: uploadingB ? null : () => pick(false),
                child: Container(
                  height: 96,
                  decoration: BoxDecoration(
                      color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                  clipBehavior: Clip.antiAlias,
                  child: banner.isNotEmpty
                      ? Stack(fit: StackFit.expand, children: [MediaImage(cid: banner, fit: BoxFit.cover), const _CamScrim()])
                      : Center(child: uploadingB
                          ? const CircularProgressIndicator(strokeWidth: 2, color: kAccent)
                          : const Text('＋ Add banner', style: TextStyle(color: kDim))),
                ),
              ),
              Transform.translate(
                offset: const Offset(8, -28),
                child: GestureDetector(
                  onTap: uploadingA ? null : () => pick(true),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: kBg, shape: BoxShape.circle),
                    child: avatar.startsWith('live:')
                        ? LiveAvatar(style: avatar.substring(5), radius: 31)
                        : avatar.isNotEmpty
                            ? Stack(children: [
                                ClipOval(child: SizedBox(width: 62, height: 62, child: MediaImage(cid: avatar, fit: BoxFit.cover))),
                                const Positioned.fill(child: ClipOval(child: _CamScrim())),
                              ])
                            : CircleAvatar(radius: 31, backgroundColor: kCard,
                                child: uploadingA
                                    ? const CircularProgressIndicator(strokeWidth: 2, color: kAccent)
                                    : const Icon(Icons.add_a_photo_outlined, color: kDim, size: 20)),
                  ),
                ),
              ),
              TextField(
                controller: nameCtl,
                style: const TextStyle(color: kText, fontSize: 15),
                maxLength: 40,
                decoration: _fieldDeco('Display name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bioCtl,
                style: const TextStyle(color: kText, fontSize: 15),
                minLines: 2, maxLines: 4, maxLength: 160,
                decoration: _fieldDeco('Bio'),
              ),
              const SizedBox(height: 6),
              // LIVE avatar picker — animated, code-drawn avatars (no upload). Tap a style to set/unset.
              Row(children: [
                const Text('Live avatar', style: TextStyle(color: kDim, fontSize: 12.5)),
                const SizedBox(width: 12),
                Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in const [('orbit', 'Orbit'), ('key', 'Key')])
                    GestureDetector(
                      onTap: () => setSheet(() => avatar = avatar == 'live:${s.$1}' ? '' : 'live:${s.$1}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                            color: avatar == 'live:${s.$1}' ? kAccent.withValues(alpha: 0.15) : kCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: avatar == 'live:${s.$1}' ? kAccent : kLine)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          LiveAvatar(style: s.$1, radius: 11),
                          const SizedBox(width: 7),
                          Text(s.$2,
                              style: TextStyle(color: avatar == 'live:${s.$1}' ? kAccent : kText,
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                        ]),
                      ),
                    ),
                ])),
              ]),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: saving ? null : () async {
                  setSheet(() => saving = true);
                  final r = await Api.profileSet(nameCtl.text.trim(), bioCtl.text.trim(), avatar, banner);
                  if (r != null && r['ok'] == true) {
                    // re-fetch the full record (with follower/following counts) into the cache
                    final full = await Api.profileGet(_account);
                    if (full != null) ProfileCache.I.put(_account, full);
                  }
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      backgroundColor: kCard, content: Text('profile published to the relays — portable across devices')));
                },
                style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
              )),
            ]),
          ),
        );
      }),
    );
  }

  // open the comment thread for a post; refresh the count when it closes
  Future<void> _openComments(Post p) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => CommentsSheet(
        post: p,
        myHandle: _handle,
        myAccount: _account,
        defaultTip: _settings.defaultTip,
        isHidden: _hidden,
        onTipComment: _tallyCommentTip,
        onCommented: () {
          if (p.account != _account && _settings.notifyComment) {
            Api.notifyPush(p.account, _handle, 'comment', 'commented on your post');
          }
        },
      ),
    );
    final cs = await Api.comments(p.id);
    if (mounted) setState(() => _commentCount[p.id] = cs.length);
  }

  // tip a COMMENT: tally to the comment's author, stat on the comment's own id (notified at settle).
  void _tallyCommentTip(Map<String, dynamic> c) {
    final acct = (c['account'] ?? '') as String;
    if (acct == _account) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard, content: Text("You can't tip your own comment")));
      return;
    }
    final amt = _settings.defaultTip;
    if (!_guardTip(amt)) return;
    final handle = (c['handle'] ?? '') as String;
    final cid = (c['cid'] ?? '') as String;
    setState(() {
      _pending[acct] = (_pending[acct] ?? 0) + amt;
      _handleOf[acct] = handle;
    });
    if (cid.isNotEmpty) Api.tipstat(cid, _rawOf(amt));
    // no notification here — a tip is a pledge until it settles; the creator is notified at SETTLE.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200),
        backgroundColor: kCard,
        content: Text('◈ +${fmtXno(amt)} XNO tallied to @$handle (comment) — off-chain')));
    _maybeAutoSettle(acct, handle);
  }

  // ---- per-viewer mute / block (client-side, reversible) ----
  bool _hidden(String account) =>
      account != _account && (_muted.contains(account) || _blocked.contains(account));

  void _toggleMute(String account, String handle) {
    final on = _muted.contains(account);
    setState(() => on ? _muted.remove(account) : _muted.add(account));
    MuteStore.save(_muted);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kCard,
        content: Text(on ? 'Unmuted @$handle' : 'Muted @$handle — hidden from your feed, silently')));
  }

  void _toggleBlock(String account, String handle) {
    final on = _blocked.contains(account);
    setState(() {
      if (on) {
        _blocked.remove(account);
      } else {
        _blocked.add(account);
        if (_follows.remove(account)) _publishFollows(); // block also drops the follow
      }
    });
    BlockStore.save(_blocked);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kCard,
        content: Text(on
            ? 'Unblocked @$handle'
            : 'Blocked @$handle — hidden, unfollowed, and their DMs won’t reach you')));
  }

  // pay-to-pin a post's media: pay the independent public relays so they keep it from being evicted.
  // The payment (a real XNO send per relay) is the user's tap — the app signs it on-device.
  void _pinPost(Post p) {
    final cid = p.media ?? '';
    if (cid.isEmpty) return;
    double xno = 0.01;
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      isScrollControlled: true,
      builder: (_) {
        bool pinning = false;
        Map<String, dynamic>? result;
        return StatefulBuilder(builder: (ctx, setSheet) {
          final days = xno * 30000; // mirrors the relay's XC_PIN_DAYS_PER_XNO default
          return Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 22 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: const [
                Icon(Icons.push_pin, color: kAccent, size: 20),
                SizedBox(width: 8),
                Text('Keep this alive', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              ]),
              const SizedBox(height: 4),
              const Text('Pay the independent relays a little XNO and they protect this content from '
                  'eviction — pay-to-pin. The more you pay, the longer it stays. Unpaid content is dropped '
                  'as the cache fills; this is how the network keeps what people value.',
                  style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 14),
              const Text('Amount per relay', style: TextStyle(color: kDim, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [0.01, 0.05, 0.10].map((o) {
                final on = (o - xno).abs() < 1e-9;
                return GestureDetector(
                  onTap: () => setSheet(() => xno = o),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                        color: on ? kAccent : kCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: on ? kAccent : kLine)),
                    child: Text('${o.toStringAsFixed(2)} XNO',
                        style: TextStyle(color: on ? Colors.black : kText, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                );
              }).toList()),
              const SizedBox(height: 10),
              Text('≈ ${days.toStringAsFixed(0)} days of pinning per relay',
                  style: const TextStyle(color: kAccent, fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              if (result != null)
                Text(
                    result!['ok'] == true
                        ? '📌 pinned on ${result!['pinned']}/${result!['relays']} relay(s) for ~${((result!['days'] ?? 0) as num).toStringAsFixed(0)} days'
                            '${p.account == _account ? ' · your post stays visible that long, even offline' : ''}'
                        : 'pin failed: ${result!['error'] ?? 'unknown'}',
                    style: TextStyle(
                        color: result!['ok'] == true ? const Color(0xFF4DD0A7) : const Color(0xFFEF6C9B),
                        fontSize: 13, fontWeight: FontWeight.w600))
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: pinning ? null : () async {
                      setSheet(() => pinning = true);
                      final r = await Api.pin(cid, xno, reservedXno: _pendingTotal());
                      // issuer head-extension: on YOUR OWN post, also keep its head (so the post stays
                      // VISIBLE, not just its media kept) for the pinned span — even while you're offline.
                      if (r?['ok'] == true && p.account == _account) {
                        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                        await Api.extendHead(_account, now + (days * 86400).round());
                      }
                      if (!ctx.mounted) return;
                      setSheet(() { pinning = false; result = r; });
                      await _load();
                    },
                    style: FilledButton.styleFrom(
                        backgroundColor: kAccent, foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                    child: pinning
                        ? const SizedBox(height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Pin & pay', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ),
              const SizedBox(height: 8),
              Text(pinning ? 'signing on-device · delegating proof-of-work…'
                          : 'mainnet · real XNO · one send per relay · PoW delegated',
                  textAlign: TextAlign.center, style: const TextStyle(color: kDim, fontSize: 11)),
            ]),
          );
        });
      },
    );
  }

  // ---- private bookmarks (on-device) ----
  void _toggleBookmark(Post p) {
    final on = _bookmarks.contains(p.id);
    setState(() => on ? _bookmarks.remove(p.id) : _bookmarks.add(p.id));
    BookmarkStore.save(_bookmarks);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1300),
        backgroundColor: kCard,
        content: Text(on ? 'Removed from bookmarks' : '🔖 Saved to bookmarks — private, on-device')));
  }

  void _openBookmarks() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
          title: const Text('Bookmarks', style: TextStyle(color: kText, fontWeight: FontWeight.w800)),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(24),
            child: Container(width: double.infinity, color: const Color(0xFF07130E),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: const Text('🔖 private · on-device · never published',
                  textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF4DD0A7), fontSize: 11.5, fontWeight: FontWeight.w600))),
          )),
      body: Builder(builder: (_) {
        final saved = _posts.where((p) => _bookmarks.contains(p.id)).toList();
        if (saved.isEmpty) {
          return const Center(child: Padding(padding: EdgeInsets.all(40),
              child: Text('No bookmarks yet.\nTap ⋯ on any post → Bookmark.',
                  textAlign: TextAlign.center, style: TextStyle(color: kDim, height: 1.5))));
        }
        return ListView.separated(
          itemCount: saved.length,
          separatorBuilder: (_, __) => Container(color: kLine, height: 1),
          itemBuilder: (_, i) => _profileCard(saved[i]),
        );
      }),
    )));
  }

  // Manage hidden words (Threads-style): add/remove words that filter posts from your feed.
  void _manageHiddenWords() {
    final ctl = TextEditingController();
    showModalBottomSheet(
      context: context, backgroundColor: kBg, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void add() {
          final w = ctl.text.trim();
          if (w.isEmpty || _mutedWords.contains(w)) { ctl.clear(); return; }
          setState(() => _mutedWords = [..._mutedWords, w]);
          MutedWordsStore.save(_mutedWords);
          ctl.clear(); setSheet(() {});
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(18, 16, 18, 22 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Hidden words', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 4),
            const Text('Posts containing any of these are hidden from your feed — private, on-device.',
                style: TextStyle(color: kDim, fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctl, onSubmitted: (_) => add(), style: const TextStyle(color: kText),
                  decoration: const InputDecoration(
                      hintText: 'Add a word or phrase', hintStyle: TextStyle(color: kDim),
                      filled: true, fillColor: kCard,
                      border: OutlineInputBorder(borderSide: BorderSide.none)),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: add,
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  child: const Text('Add', style: TextStyle(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 14),
            if (_mutedWords.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No hidden words yet.', style: TextStyle(color: kDim)))
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final w in _mutedWords)
                  Chip(
                    backgroundColor: kCard, label: Text(w, style: const TextStyle(color: kText)),
                    deleteIconColor: kDim,
                    side: const BorderSide(color: kLine),
                    onDeleted: () {
                      setState(() => _mutedWords = _mutedWords.where((x) => x != w).toList());
                      MutedWordsStore.save(_mutedWords);
                      setSheet(() {});
                    },
                  ),
              ]),
          ]),
        );
      }),
    );
  }

  // Report = a trust-scoped, reversible flag (NOT a dislike/downvote). Feeds moderation.
  void _reportPost(Post p) {
    setState(() => _reported.add(p.id));                 // hide on this device immediately
    Api.report(p.id, p.media ?? '').then((_) {           // publish the signed report to the relays
      if (mounted) Future.delayed(const Duration(seconds: 1), () { if (mounted) _refreshLabels(); });
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: kCard,
        content: Text('reported to the community + hidden from your feed — enough reports take it '
            'down for everyone (reversible)')));
  }

  // Delete your own post: confirm, optimistically remove it, then republish your thread without it.
  void _deletePost(Post p) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Delete post?', style: TextStyle(color: kText, fontWeight: FontWeight.w700)),
        content: const Text('Your thread is republished without it, so it drops from the relays. '
            'This can’t be undone.', style: TextStyle(color: kDim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: kDim))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _posts = _posts.where((x) => x.id != p.id).toList());   // optimistic
              final ok = await Api.deletePost(p.id, p.handle);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  backgroundColor: kCard,
                  content: Text(ok ? 'deleted — your thread was republished without it'
                                   : 'delete failed — restoring')));
              Future.delayed(Duration(seconds: ok ? 3 : 0), () { if (mounted) _load(); });  // reconcile / restore
            },
            child: const Text('Delete', style: TextStyle(color: Color(0xFFEF6C9B), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // Edit your own post: prefilled dialog, optimistic text swap, then republish the thread with the change.
  void _editPost(Post p) {
    final ctl = TextEditingController(text: p.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Edit post', style: TextStyle(color: kText, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctl, autofocus: true, maxLines: null, minLines: 1,
          style: const TextStyle(color: kText),
          decoration: const InputDecoration(hintText: 'Your post', hintStyle: TextStyle(color: kDim)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: kDim))),
          TextButton(
            onPressed: () async {
              final next = ctl.text.trim();
              Navigator.pop(ctx);
              if (next.isEmpty || next == p.text) return;
              final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
              setState(() => _posts = _posts
                  .map((x) => x.id == p.id ? Post.fromJson({...x.toJson(), 'text': next, 'edited': ts}) : x)
                  .toList());                                                   // optimistic
              final ok = await Api.editPost(p.id, next, p.handle);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  backgroundColor: kCard,
                  content: Text(ok ? 'edited — your thread was republished'
                                   : 'edit failed — restoring')));
              Future.delayed(Duration(seconds: ok ? 3 : 0), () { if (mounted) _load(); });  // reconcile / restore
            },
            child: const Text('Save', style: TextStyle(color: kAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // Pin one of your own posts to the top of your profile (X-style). Re-publishes your profile with a
  // separately-signed pinned marker.
  Future<void> _pinToProfile(Post p) async {
    final ok = await Api.setPinned(p.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kCard,
        content: Text(ok ? 'pinned to your profile' : 'could not pin — try again')));
  }

  Future<void> _refreshLabels() async {                  // pull the updated community-report labels
    try {
      final l = await Api.labels();
      if (mounted) setState(() => _labelers = l);
    } catch (_) {}
  }

  // build the on-device signer from the local seed, then load follows (needs the account).
  Future<void> _bootWallet() async {
    final seed = await WalletStore.get();
    if (seed != null) {
      final w = NanoWallet(seed);
      if (mounted) setState(() => _wallet = w);
      Api.headKeepUntil = await HeadKeep.get(w.account);   // resume any active keep-alive (issuer pin)
      final backed = await BackupStore.get(w.account);     // seed confirmed backed up? (footgun guard)
      if (mounted) setState(() => _needsBackup = !backed);
      _autoReceive();                                     // claim anything waiting, at launch
    }
    Api.dmKeyRegister();   // publish our signed DM public key so peers can encrypt to us
    _initFollows();
    _outbox = await Outbox.load();          // restore anything queued offline in a previous session
    if (mounted) setState(() {});
    _flushOutbox();                          // and try to send it now (best-effort; no-op if offline)
    // Defer the update check a few seconds so it's OFF the launch burst (the banner isn't urgent). Keeps
    // the startup requests down to the essentials; the 4h periodic timer still covers ongoing checks.
    Future.delayed(const Duration(seconds: 4), () { if (mounted) _autoCheckUpdate(); });
  }

  // AUTO-UPDATE CHECK: on launch, ask the relays for a newer signed release and, if there is one the user
  // hasn't already dismissed, surface a banner. The manual wallet→"App updates" flow still exists; this
  // just means an update reaches people without them going looking for it.
  Future<void> _autoCheckUpdate() async {
    // In a browser there is no APK to fetch and no OS installer to hand it to — the page IS the
    // current version, and reloading is the update. Offering one would download a file nothing can
    // install, so the whole self-update path is Android-only.
    if (kIsWeb) return;
    try {
      final r = await Api.releaseCheck();
      if (r == null || r['update'] != true) return;
      final v = '${r['version']}';
      if (await UpdateDismiss.suppressed(v)) return;   // dismissed this version within the last day
      if (mounted) setState(() => _update = r);
    } catch (_) {}
  }

  // ---- OFFLINE OUTBOX: queue posts composed offline, auto-flush on reconnect ----
  // Replay one queued compose intent through the normal Api path. Returns false on any failure
  // (offline / node error) so the caller keeps it queued and retries later.
  Future<bool> _sendJob(Map<String, dynamic> job) async {
    String mediaCid = '';
    final b64 = job['mediaB64'] as String?;
    if (b64 != null && b64.isNotEmpty) {
      mediaCid = await Api.blobPut(base64Decode(b64)) ?? '';
      if (mediaCid.isEmpty) return false;                     // media upload needs the network
    }
    final segs = (job['segments'] as List).cast<String>();
    final pollCsv = ((job['poll'] as List?)?.cast<String>() ?? const <String>[]).join('|');
    final baseTs = job['ts'] as int?;
    // publish under a channel identity if one was chosen: sign with the channel's derived key + its handle
    final channel = (job['channel'] as String?) ?? '';
    final signer = (channel.isNotEmpty && gWallet != null) ? gWallet!.channelWallet(channel) : null;
    final postHandle = channel.isNotEmpty ? _channelHandle(channel) : (job['handle'] as String);
    String prev = '';
    for (int i = 0; i < segs.length; i++) {
      // A post's id is 'u<ts>' (seconds), so every segment MUST get a distinct ts — else a queued thread
      // (all segments share the job's single ts) collapses to one id and the reply chain breaks. +i keeps
      // order and makes each unique. (Also fixes a fast online thread posting >1 segment in the same second.)
      final id = await Api.post(segs[i], handle: postHandle, signer: signer,
          media: i == 0 ? mediaCid : '', mediaKind: i == 0 ? (job['mediaKind'] as String? ?? '') : '',
          // first segment threads under the post being replied to (X-style reply); later segments chain
          // to the previous segment so a multi-part reply stays a self-thread under that first reply.
          quote: i == 0 ? (job['quote'] as String? ?? '') : '',
          replyTo: i == 0 ? (job['reply_to'] as String? ?? '') : prev,
          title: i == 0 ? (job['title'] as String? ?? '') : '', poll: i == 0 ? pollCsv : '',
          ts: baseTs == null ? null : baseTs + i);
      if (id.isEmpty) return false;
      prev = id;
    }
    return true;
  }

  // Send queued posts oldest-first; stop at the first that won't go (still offline) and keep the rest.
  Future<void> _flushOutbox() async {
    if (_flushing || _outbox.isEmpty || gWallet == null) return;
    _flushing = true;
    int sent = 0;
    try {
      while (_outbox.isNotEmpty) {
        final ok = await _sendJob(_outbox.first);
        if (!ok) break;                                        // still offline / failed — try again later
        _outbox.removeAt(0);
        await Outbox.saveAll(_outbox);
        sent++;
        if (mounted) setState(() {});
      }
    } finally {
      _flushing = false;
    }
    if (sent > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kCard,
            content: Text('sent $sent queued post${sent == 1 ? '' : 's'}')));
      }
      await _load();                                           // pull the now-sent posts into the feed
    }
  }

  void _discardQueued(Map<String, dynamic> job) {
    setState(() => _outbox.remove(job));
    Outbox.saveAll(_outbox);
  }

  // load local follows, then merge the portable (signed, relay-published) list so a
  // restore on another phone brings the graph back. Republish the union.
  Future<void> _initFollows() async {
    final local = await FollowStore.get();
    if (mounted) setState(() => _follows = local);
    final acc = _wallet?.account;
    if (acc == null) return;
    final remote = (await Api.followsGet(acc)).toSet();
    final union = {...local, ...remote};
    _follows = union;
    if (mounted) setState(() {});
    await FollowStore.save(union);
    // HEAL the portable graph: if the relay's published copy is missing anything we hold locally — the
    // v2 signing migration dropped old-format follow records, or an earlier publish never landed — then
    // re-sign & republish the union so Following works and the graph survives a reinstall / other device.
    // (Previously this bailed on an empty remote and never pushed local up, so follows stayed local-only.)
    if (union.isNotEmpty && union.length != remote.length) {
      await _publishFollows();
    }
  }

  // on-device signed: the app signs the follow list locally; the node only verifies + relays.
  Future<void> _publishFollows() async {
    await FollowStore.save(_follows);
    final w = _wallet;
    if (w == null) return;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final follows = _follows.toList()..sort();
    final s = w.signMsg(w.followMsg(ts, follows));
    await Api.followsPub({'account': w.account, 'follows': follows, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']});
  }

  void _toggleFollow(String account) {
    setState(() {
      if (_follows.contains(account)) {
        _follows.remove(account);
      } else {
        _follows.add(account);
      }
    });
    _publishFollows();
  }

  void _showNotifs() {
    // Opening the bell marks everything shown so far as SEEN: the unread badge resets to 0 and only
    // notifications that arrive AFTER now count again (mirrors the DM seen-watermark). Persisted so it
    // survives restarts.
    final nowTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    setState(() => _notifSeenTs = nowTs);
    SharedPreferences.getInstance().then((sp) => sp.setInt('notif_seen_ts', nowTs));
    // drop notifications from accounts you've muted or blocked
    final hiddenHandles = {..._muted, ..._blocked}.map(_handleFor).toSet();
    final notifs = _notifs.where((n) => !hiddenHandles.contains('${n['from']}')).toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      builder: (_) => Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Icons.notifications_none, color: kAccent, size: 20),
            SizedBox(width: 8),
            Text('Notifications', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
          ]),
          const SizedBox(height: 4),
          const Text('delivered by relay push (stands in for APNs/FCM) — no persistent connection',
              style: TextStyle(color: kDim, fontSize: 11)),
          const SizedBox(height: 12),
          if (notifs.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('nothing new', style: TextStyle(color: kDim)))
          else
            ...notifs.map((n) {
              // Name the action from the notification's kind — it used to always say "mentioned you",
              // so a tip or a like was mislabelled (users reported "it says mentioned but it's a tip").
              final k = '${n['kind'] ?? ''}';
              final verb = k == 'tip' ? 'tipped your post'
                  : k == 'like' ? 'liked your post'
                  : k == 'comment' ? 'commented on your post'
                  : k == 'follow' ? 'followed you'
                  : 'mentioned you';
              // The header now names the action, so drop a verb prefix the text baked in (no "liked … liked:").
              var detail = '${n['text']}';
              for (final p in const ['liked: ', 'commented: ', 'tipped your post ']) {
                if (detail.startsWith(p)) { detail = detail.substring(p.length); break; }
              }
              final from = '${n['from']}';
              final initial = from.isEmpty ? '?' : from.substring(0, 1).toUpperCase();  // never RangeError on empty
              return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CircleAvatar(radius: 16, backgroundColor: avatarColor(from),
                        child: Text(initial,
                            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('@$from $verb · ${timeAgo(n['ts'] ?? 0)}',
                          style: const TextStyle(color: kDim, fontSize: 12)),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(detail, style: const TextStyle(color: kText, fontSize: 14, height: 1.3)),
                      ],
                    ])),
                  ]),
                );
            }),
        ]),
      ),
    );
  }

  void _showWallet() {
    bool reveal = false;
    String seed = '';
    String? rep; // current representative (fetched lazily)
    bool repFetching = false;
    _autoReceive();   // you are about to read the balance — make sure it is the true one
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,     // a grab handle to drag down, and a scrim above to tap away
      backgroundColor: kBg,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        final xno = (double.tryParse(_balance) ?? 0) / 1e30;
        if (rep == null && !repFetching) {
          repFetching = true;
          Api.repGet().then((r) { rep = '${r?['representative'] ?? '—'}'; if (ctx.mounted) setSheet(() {}); });
        }
        String short(String a) => a.length < 24 ? a : '${a.substring(0, 14)}…${a.substring(a.length - 6)}';
        return SafeArea(child: SingleChildScrollView(child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () { Navigator.pop(ctx); _openProfile(_account, _handle); },
              child: Row(children: [
                AuthorAvatar(account: _account, handle: _handle, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    AnimatedBuilder(
                      animation: ProfileCache.I,
                      builder: (_, __) => Text(ProfileCache.I.displayName(_account, _handle),
                          style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                    ),
                    Text('@$_handle · ${xno.toStringAsFixed(5)} XNO', style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                    // Money that is already yours on-chain but not yet pocketed. Auto-receive claims
                    // it within seconds, so this is usually a blink — but while it IS showing, the
                    // balance above is understating what you own, and saying nothing is what made
                    // 13.3 XNO look lost.
                    if (_incomingRaw > BigInt.zero)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(
                              width: 10, height: 10,
                              child: CircularProgressIndicator(strokeWidth: 1.6, color: Color(0xFF4DD0A7))),
                          const SizedBox(width: 6),
                          Text(
                            '+${(_incomingRaw / BigInt.from(10).pow(30)).toStringAsFixed(5)} XNO incoming',
                            style: const TextStyle(
                                color: Color(0xFF4DD0A7), fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ]),
                      ),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: kDim),
              ]),
            ),
            const SizedBox(height: 16),
            Row(children: [
              const Text('Nano account (your identity)', style: TextStyle(color: kDim, fontSize: 12)),
              const Spacer(),
              InkWell(
                onTap: () => _copy(_account, 'Address'),
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(children: [
                    Icon(Icons.copy, size: 14, color: kAccent),
                    SizedBox(width: 4),
                    Text('Copy', style: TextStyle(color: kAccent, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ]),
            const SizedBox(height: 3),
            InkWell(
              onTap: () => _copy(_account, 'Address'),
              child: Text(_account, style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12)),
            ),
            const SizedBox(height: 4),
            Text(_needsBackup ? 'tap to copy · this is your public identity' : 'tap to copy · share it to receive XNO from another wallet',
                style: const TextStyle(color: kDim, fontSize: 11)),
            const SizedBox(height: 14),
            // RECEIVE-GATE: bringing XNO into a wallet with NO backup risks the funds (a random seed, no
            // recovery). So the receive QR is withheld until the seed is confirmed backed up.
            if (_needsBackup)
              InkWell(
                onTap: () { Navigator.pop(ctx); _showBackupSheet(); },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE0A63A).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE0A63A).withOpacity(0.45))),
                  child: Row(children: const [
                    Icon(Icons.lock_outline, size: 18, color: Color(0xFFE0A63A)),
                    SizedBox(width: 10),
                    Expanded(child: Text("Back up your seed to receive XNO — a wallet with no backup can't be recovered. Tap to secure it.",
                        style: TextStyle(color: Color(0xFFE0A63A), fontSize: 12.5, fontWeight: FontWeight.w600))),
                    Icon(Icons.chevron_right, size: 18, color: Color(0xFFE0A63A)),
                  ]),
                ),
              )
            else
              const SizedBox.shrink(),
            // The QR used to sit inline HERE as well as behind Request — the same code twice, and a
            // 176px scan target competing with a full-screen one. It lives in the Request sheet now:
            // one place, big enough to actually scan across a table.
            const SizedBox(height: 14),
            // representative row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
              child: Row(children: [
                const Icon(Icons.how_to_vote_outlined, size: 18, color: kDim),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Representative', style: TextStyle(color: kText, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  Text(rep == null ? 'loading…' : (rep == _account ? 'self · ${short(rep!)}' : short(rep!)),
                      style: const TextStyle(color: kDim, fontSize: 11.5, fontFamily: 'monospace')),
                ])),
                TextButton(
                  onPressed: rep == null ? null : () => _showChangeRep(rep!, () {
                    rep = null; if (ctx.mounted) setSheet(() {}); // re-fetch after change
                  }),
                  child: const Text('Change', style: TextStyle(color: kAccent, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            // Transactions. The wallet showed a balance and no way to see how it got there, so an
            // arriving tip was invisible unless you happened to notice the number move.
            InkWell(
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WalletHistoryScreen(handles: _knownHandles())));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const Icon(Icons.receipt_long, color: kAccent, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Transactions',
                        style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  const Icon(Icons.chevron_right, color: kDim),
                ]),
              ),
            ),
            const Divider(height: 1, color: kLine),
            const SizedBox(height: 16),
            // send / receive Nano (mainnet — real XNO)
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () { Navigator.pop(ctx); _showSend(); },
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  label: const Text('Send', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // REQUEST, not "receive". Claiming is automatic now, so a button that ran it was
                // exposing Nano's receivable model as a chore: it read as "fetch my money", did
                // nothing visible for ~7s, and stayed tappable the whole time so a second press
                // forked the frontier. What a person actually wants here is to BE PAID — show them
                // the address to hand over.
                child: OutlinedButton.icon(
                  onPressed: () { Navigator.pop(ctx); _showRequest(); },
                  style: OutlinedButton.styleFrom(foregroundColor: kText,
                      side: const BorderSide(color: kLine)),
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: const Text('Request', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text('mainnet · real XNO · feeless · PoW delegated · safety cap ${kWalletCapXno.toStringAsFixed(0)} XNO',
                style: const TextStyle(color: kDim, fontSize: 11)),
            const SizedBox(height: 12),
            // safety: auto-forward anything above the cap to an external savings address (app holds no key for it)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
              child: Column(children: [
                Row(children: [
                  const Icon(Icons.savings_outlined, size: 18, color: kDim),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Auto-move to savings', style: TextStyle(color: kText, fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text('forward anything over ${kWalletCapXno.toStringAsFixed(0)} XNO to your own wallet',
                        style: const TextStyle(color: kDim, fontSize: 11)),
                  ])),
                  Switch(
                    value: _settings.autoSweep,
                    activeColor: kAccent,
                    onChanged: (v) async {
                      if (v) {
                        final a = _settings.sweepAddr.startsWith('nano_') ? _settings.sweepAddr : await _askSavingsAddr();
                        if (a == null) return;
                        await _saveSweep(on: true, addr: a);
                      } else {
                        await _saveSweep(on: false);
                      }
                      if (ctx.mounted) setSheet(() {});
                    },
                  ),
                ]),
                if (_settings.autoSweep)
                  InkWell(
                    onTap: () async { final a = await _askSavingsAddr(); if (a != null) { await _saveSweep(addr: a); if (ctx.mounted) setSheet(() {}); } },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        const Icon(Icons.arrow_outward, size: 13, color: kAccent),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_settings.sweepAddr.isEmpty ? 'set savings address' : 'to ${short(_settings.sweepAddr)}',
                            style: const TextStyle(color: kAccent, fontFamily: 'monospace', fontSize: 11))),
                        const Icon(Icons.edit, size: 12, color: kDim),
                      ]),
                    ),
                  ),
              ]),
            ),
            if (xno > kWalletCapXno && !_settings.autoSweep) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0x22E0A83E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE0A83E))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: const [
                    Icon(Icons.shield_outlined, size: 16, color: Color(0xFFE0A83E)),
                    SizedBox(width: 6),
                    Text('Over the safety cap', style: TextStyle(color: Color(0xFFE0A83E), fontWeight: FontWeight.w800, fontSize: 13)),
                  ]),
                  const SizedBox(height: 4),
                  Text('You hold ${(xno - kWalletCapXno).toStringAsFixed(2)} XNO above the cap. Move it to your own '
                      'wallet, or turn on auto-move above so it never sits here.',
                      style: const TextStyle(color: kDim, fontSize: 11.5, height: 1.35)),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: FilledButton(
                    onPressed: () { Navigator.pop(ctx); _showSend(); },
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE0A83E), foregroundColor: Colors.black),
                    child: const Text('Move extra to my wallet', style: TextStyle(fontWeight: FontWeight.w800)),
                  )),
                ]),
              ),
            ],
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune, color: kText, size: 20),
              title: const Text('Settings', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('default tip · tip split · notifications', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: kDim),
              onTap: () { Navigator.pop(ctx); _showSettings(); },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bookmark_border, color: kText, size: 20),
              title: const Text('Bookmarks', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('privately saved posts · on-device', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: Text('${_bookmarks.length}', style: const TextStyle(color: kDim, fontSize: 13)),
              onTap: () { Navigator.pop(ctx); _openBookmarks(); },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.visibility_off_outlined, color: kText, size: 20),
              title: const Text('Hidden words', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('hide posts containing certain words · on-device', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: Text('${_mutedWords.length}', style: const TextStyle(color: kDim, fontSize: 13)),
              onTap: () { Navigator.pop(ctx); _manageHiddenWords(); },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dashboard_customize_outlined, color: kText, size: 20),
              title: const Text('Channels', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('your publications · long-form articles', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: Text('${_myChannels.length}', style: const TextStyle(color: kDim, fontSize: 13)),
              onTap: () { Navigator.pop(ctx); _openChannels(); },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update, color: kText, size: 20),
              title: const Text('App updates', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('signed releases over the relays · no app store', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: Text('v$kAppVersion', style: const TextStyle(color: kDim, fontSize: 12, fontFamily: 'monospace')),
              onTap: () {
                Navigator.pop(ctx);
                if (kIsWeb) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      backgroundColor: kCard,
                      content: Text('On the web you are always on the current version — just reload the page.')));
                  return;
                }
                _showUpdates();
              },
            ),
            const SizedBox(height: 6),
            if (!reveal)
              OutlinedButton.icon(
                onPressed: () async {
                  seed = await WalletStore.get() ?? '';
                  setSheet(() => reveal = true);
                },
                style: OutlinedButton.styleFrom(foregroundColor: kText, side: const BorderSide(color: kLine)),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('Show recovery seed'),
              )
            else ...[
              const Text('⚠ recovery seed — anyone with it controls your account. Never share it.',
                  style: TextStyle(color: Color(0xFFE0B64D), fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
                child: SelectableText(seed,
                    style: const TextStyle(color: kAccent, fontFamily: 'monospace', fontSize: 13, height: 1.4)),
              ),
            ],
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await widget.onLogout?.call();
              },
              icon: const Icon(Icons.logout, size: 18, color: Color(0xFFEF6C9B)),
              label: const Text('Switch / restore another wallet',
                  style: TextStyle(color: Color(0xFFEF6C9B))),
            ),
          ]),
        )));
      }),
    );
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200), backgroundColor: kCard,
        content: Text('📋 $what copied to clipboard')));
  }

  // change the account's Nano representative (a change block — moves no value). Dev network.
  void _showChangeRep(String current, VoidCallback onChanged) {
    final ctl = TextEditingController();
    bool saving = false;
    String? err;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: const [
                Icon(Icons.how_to_vote_outlined, color: kAccent, size: 20), SizedBox(width: 8),
                Text('Representative', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              ]),
              const SizedBox(height: 6),
              const Text('Your representative votes in Nano consensus on your balance’s behalf. Changing it '
                  'moves no funds — it’s a change block. Pick an online, reputable rep.',
                  style: TextStyle(color: kDim, fontSize: 12.5, height: 1.45)),
              const SizedBox(height: 10),
              const Text('CURRENT', style: TextStyle(color: kDim, fontSize: 10, letterSpacing: 1)),
              const SizedBox(height: 2),
              SelectableText(current, style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 14),
              TextField(
                controller: ctl,
                style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 13),
                minLines: 1, maxLines: 2,
                decoration: _fieldDeco('New representative (nano_…)'),
              ),
              if (err != null) ...[
                const SizedBox(height: 10),
                Text(err!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12.5)),
              ],
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: saving ? null : () async {
                  final rep = ctl.text.trim();
                  if (!rep.startsWith('nano_') || rep.length < 60) {
                    setSheet(() => err = 'enter a valid nano_ representative address'); return;
                  }
                  setSheet(() { saving = true; err = null; });
                  final r = await Api.repSet(rep);
                  if (!mounted) return;
                  if (r != null && r['ok'] == true) {
                    Navigator.pop(ctx);
                    onChanged();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        backgroundColor: kCard, content: Text('✓ representative changed · 1 change block · no funds moved')));
                  } else {
                    setSheet(() { saving = false; err = (r?['error'] ?? 'change failed').toString(); });
                  }
                },
                style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                child: saving
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Change representative', style: TextStyle(fontWeight: FontWeight.w800)),
              )),
              const SizedBox(height: 8),
              const Text('mainnet · a change block moves no value', style: TextStyle(color: kDim, fontSize: 11)),
            ]),
          ),
        );
      }),
    );
  }

  // send Nano to any address (mainnet). Validation + result handled by the node.
  void _showSend() {
    final toCtl = TextEditingController();
    final amtCtl = TextEditingController(text: _settings.defaultTip.toStringAsFixed(2));
    bool sending = false;
    String? err;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        final xno = (double.tryParse(_balance) ?? 0) / 1e30;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.arrow_upward, color: kAccent, size: 20),
                const SizedBox(width: 8),
                const Text('Send Nano', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                Text('${xno.toStringAsFixed(5)} XNO', style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 14),
              TextField(
                controller: toCtl,
                style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 13),
                minLines: 1, maxLines: 2,
                decoration: _fieldDeco('Recipient address (nano_…)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amtCtl,
                style: const TextStyle(color: kText, fontSize: 15),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _fieldDeco('Amount (XNO)'),
              ),
              if (err != null) ...[
                const SizedBox(height: 10),
                Text(err!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12.5)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: sending ? null : () async {
                    final to = toCtl.text.trim();
                    final amt = double.tryParse(amtCtl.text.trim()) ?? 0;
                    if (!to.startsWith('nano_') || to.length < 60) {
                      setSheet(() => err = 'enter a valid nano_ address'); return;
                    }
                    if (amt <= 0) { setSheet(() => err = 'enter an amount greater than 0'); return; }
                    // reserve XNO already tallied for un-settled tips, so a send can't spend it
                    final free = xno - _pendingTotal();
                    if (amt > free + 1e-9) {
                      setSheet(() => err = _pendingTotal() > 1e-9
                          ? 'only ${free.toStringAsFixed(3)} XNO free — ${_pendingTotal().toStringAsFixed(2)} reserved for pending tips'
                          : 'amount exceeds your balance');
                      return;
                    }
                    setSheet(() { sending = true; err = null; });
                    final r = await Api.send(to, amt.toStringAsFixed(6), reservedXno: _pendingTotal());
                    await _load();
                    if (!mounted) return;
                    if (r != null && r['ok'] == true) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          backgroundColor: kCard,
                          content: Text('⬆ sent ${amt.toStringAsFixed(2)} XNO · 1 Nano block · PoW delegated')));
                    } else {
                      setSheet(() { sending = false; err = (r?['error'] ?? 'send failed').toString(); });
                    }
                  },
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  child: sending
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Send', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 8),
              const Text('mainnet · real XNO · feeless · double-check the address',
                  style: TextStyle(color: kDim, fontSize: 11)),
            ]),
          ),
        );
      }),
    );
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: kDim),
        filled: true,
        fillColor: kCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kLine)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kAccent)),
      );

  // Settings: default tip, tip-split %, notification toggles. Persisted; used everywhere.
  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        void persist() { SettingsStore.save(_settings); setState(() {}); }
        Widget section(String t) => Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(t, style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 14)),
            );
        Widget chip(String label, bool on, VoidCallback tap) => GestureDetector(
              onTap: () { tap(); setSheet(() {}); persist(); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                    color: on ? kAccent : kCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: on ? kAccent : kLine)),
                child: Text(label, style: TextStyle(color: on ? Colors.black : kText, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            );
        Widget toggle(String label, String sub, bool val, void Function(bool) set) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(color: kText, fontSize: 14.5)),
                  Text(sub, style: const TextStyle(color: kDim, fontSize: 11.5)),
                ])),
                Switch(
                    value: val,
                    activeThumbColor: kAccent,
                    onChanged: (v) { set(v); setSheet(() {}); persist(); }),
              ]),
            );
        final creator = _settings.creatorSplit;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (_, scroll) => Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: ListView(controller: scroll, children: [
              Row(children: const [
                Icon(Icons.tune, color: kAccent, size: 20),
                SizedBox(width: 8),
                Text('Settings', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
              ]),

              section('Default tip'),
              const Text('The amount added each time you tap Tip.', style: TextStyle(color: kDim, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [0.001, 0.005, 0.01, 0.05, 0.10, 0.25, 1.0].map((o) =>
                chip('${fmtXno(o)} XNO', (o - _settings.defaultTip).abs() < 1e-9,
                    () => _settings.defaultTip = o)).toList()),

              section('Tip split'),
              const Text('Every tip is split immutably on-chain when it settles — the creator, '
                  'the relay that served the media, and whoever reposted it each get a cut.',
                  style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 10),
              _splitBar(creator, _settings.reposterSplit, _settings.relaySplit),
              const SizedBox(height: 12),
              _sliderRow('Relay (media host)', _settings.relaySplit, (v) {
                if (v + _settings.reposterSplit <= 90) _settings.relaySplit = v;
              }, setSheet, persist),
              _sliderRow('Reposter (booster)', _settings.reposterSplit, (v) {
                if (v + _settings.relaySplit <= 90) _settings.reposterSplit = v;
              }, setSheet, persist),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Creator keeps $creator%', style: const TextStyle(color: Color(0xFF4DD0A7), fontWeight: FontWeight.w700, fontSize: 13)),
              ),

              section('Notifications'),
              const Text('Tell the creator when their post gets engagement.', style: TextStyle(color: kDim, fontSize: 12)),
              const SizedBox(height: 6),
              toggle('Likes', 'Android alert when someone likes your post', _settings.notifyLike, (v) => _settings.notifyLike = v),
              toggle('Comments', 'Android alert when someone comments', _settings.notifyComment, (v) => _settings.notifyComment = v),
              toggle('Tips', 'Android alert when someone tips you', _settings.notifyTip, (v) => _settings.notifyTip = v),
              toggle('Messages', 'Android alert when a DM arrives', _settings.notifyDm, (v) => _settings.notifyDm = v),
              toggle('Auto-receive', 'pocket incoming XNO without asking (what other Nano wallets do)',
                  _settings.autoReceive, (v) => _settings.autoReceive = v),
              toggle('Read receipts', 'let people see when you have read their messages',
                  _settings.readReceipts, (v) => _settings.readReceipts = v),

              section('Privacy'),
              toggle('Show when I\'m online',
                  'a live green dot while your app is open. Off (the default) keeps your activity private — nobody can poll for whether you\'re awake.',
                  _settings.showPresence, (v) => _settings.showPresence = v),
              const SizedBox(height: 6),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block, color: kText, size: 20),
                title: const Text('Muted & blocked accounts', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
                subtitle: Text('${_muted.length} muted · ${_blocked.length} blocked', style: const TextStyle(color: kDim, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: kDim),
                onTap: () { Navigator.pop(ctx); _showMutedBlocked(); },
              ),

              section('Feed cache'),
              const Text('How many posts to keep on this device. The feed opens instantly from here on '
                  'launch and then fetches only what\'s new — older posts beyond this are dropped, like a '
                  'relay bounding its own store instead of keeping everything forever.',
                  style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [100, 300, 500, 1000, 2000].map((n) =>
                  chip('$n posts', _settings.feedCacheSize == n,
                      () { _settings.feedCacheSize = n; _persistFeed(); })).toList()),

              section('Connection'),
              const Text('The relay/engine this app talks to. Point it at a hosted node (e.g. a Fly.io '
                  'relay) so a phone and an emulator can share one network.', style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined, color: kText, size: 20),
                title: const Text('Endpoint', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
                subtitle: Text(kBase, style: const TextStyle(color: kDim, fontSize: 12, fontFamily: 'monospace')),
                trailing: const Icon(Icons.edit, color: kDim, size: 18),
                onTap: () { Navigator.pop(ctx); _showEndpoint(); },
              ),
              const SizedBox(height: 4),
              const _DiscoveryTile(),
            ]),
          ),
        );
      }),
    );
  }

  // the relay panel: tap the 📡 strip → each relay's live strength + rolling reliability.
  void _showRelays() {
    // signal strength from latency: 3 bars < 150ms, 2 < 600ms, 1 otherwise; 0 = down.
    int bars(Map r) {
      if (r['up'] != true) return 0;
      final ms = (r['ms'] ?? 9999) as int;
      return ms < 150 ? 3 : (ms < 600 ? 2 : 1);
    }
    Color barColor(int b) => b >= 3
        ? const Color(0xFF4DD0A7)
        : b == 2
            ? kAccent
            : b == 1
                ? const Color(0xFFE0A83E)
                : const Color(0xFFEF6C9B);
    String host(String u) => u.replaceFirst(RegExp(r'^https?://'), '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<Map<String, dynamic>?> f = Api.relaydir();
        // Auto-discover public mesh nodes from the hubs this directory lists — no config, no secret.
        Future<List<Map<String, dynamic>>> meshF = f.then((d) async {
          final urls = ((d?['health'] as List?) ?? const [])
              .map((h) => '${h['url']}')
              .where((u) => u.startsWith('https'))
              .toList();
          await MeshReach.autoDiscoverFrom(urls);
          return MeshReach.discoveredInfo;
        });
        return FutureBuilder<Map<String, dynamic>?>(
          future: f,
          builder: (_, snap) {
            // Drop persistently-dead relays: a ledger-announced relay that is down AND has 0% uptime in
            // the rolling window (never answered a probe) is just noise — e.g. an old lhr.life tunnel a
            // peer abandoned. Anything reachable now, or reachable at some point in the window (a
            // flapping relay, reliability > 0), stays so a brief blip isn't hidden.
            final health = ((snap.data?['health'] as List?) ?? const []).where((h) {
              final m = h as Map;
              return m['up'] == true || ((m['reliability'] as num?) ?? 0) > 0;
            }).toList();
            final rvs = (snap.data?['rendezvous'] as List?) ?? const [];
            final up = health.where((h) => h['up'] == true).length;
            final onLedger = health.where((h) => h['onchain'] == true).length;
            final loading = snap.connectionState != ConnectionState.done;
            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.settings_input_antenna, color: kAccent, size: 20),
                  const SizedBox(width: 8),
                  const Text('Relays', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                  const Spacer(),
                  if (!loading)
                    Text('$up/${health.length} up', style: const TextStyle(color: Color(0xFF4DD0A7), fontWeight: FontWeight.w700, fontSize: 13)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setSheet(() => f = Api.relaydir()),
                    icon: const Icon(Icons.refresh, color: kDim, size: 20),
                  ),
                ]),
                const SizedBox(height: 4),
                const Text('Your app reads from all of these in parallel and keeps the highest signed version. '
                    'One relay slow or down doesn’t matter — the others serve.',
                    style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
                const SizedBox(height: 14),
                if (loading)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
                else
                  ...health.map((r) {
                    final b = bars(r);
                    final ms = r['ms'];
                    final rel = r['reliability'];
                    final samples = r['samples'] ?? 0;
                    final url = '${r['url']}';
                    final isNode = url.contains('127.0.0.1') || url.contains('localhost');
                    final onChain = r['onchain'] == true;
                    final label = isNode ? 'this node’s relay' : host(url);
                    final badge = onChain ? 'ledger' : (isNode ? 'node' : 'bootstrap');
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                      child: Row(children: [
                        // signal bars
                        SizedBox(
                          width: 26,
                          child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min,
                            children: List.generate(3, (i) => Container(
                              width: 5, height: 6.0 + i * 5,
                              margin: const EdgeInsets.only(right: 2),
                              decoration: BoxDecoration(
                                color: i < b ? barColor(b) : kLine,
                                borderRadius: BorderRadius.circular(1)),
                            )),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w700))),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(5), border: Border.all(color: kLine)),
                                child: Text(badge, style: const TextStyle(color: kDim, fontSize: 9, fontWeight: FontWeight.w700)),
                              ),
                            ]),
                            const SizedBox(height: 3),
                            Text(
                              r['up'] == true
                                  ? '${ms}ms · ${rel != null ? '${(rel * 100).round()}% reliable' : 'live'}${samples > 0 ? ' · $samples samples' : ''}'
                                  : 'unreachable${rel != null ? ' · ${(rel * 100).round()}% reliable' : ''}',
                              style: TextStyle(color: r['up'] == true ? kDim : const Color(0xFFEF6C9B), fontSize: 11),
                            ),
                          ]),
                        ),
                      ]),
                    );
                  }),
                // Public mesh nodes — relays with no public address, discovered THROUGH the hubs above.
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: meshF,
                  builder: (_, ms) {
                    final nodes = ms.data ?? const [];
                    if (nodes.isEmpty) return const SizedBox.shrink();
                    String hubHost(String via) =>
                        via.replaceFirst(RegExp(r'^https?://'), '').split('/r/').first;
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: nodes.map((n) {
                      final acct = '${n['account']}';
                      final shortA = acct.length > 22 ? '${acct.substring(0, 14)}…${acct.substring(acct.length - 6)}' : acct;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF8b5cf6))),
                        child: Row(children: [
                          const Icon(Icons.hub_outlined, color: Color(0xFF8b5cf6), size: 18),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(shortA, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w700))),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(5), border: Border.all(color: kLine)),
                                child: const Text('mesh · public', style: TextStyle(color: Color(0xFF8b5cf6), fontSize: 9, fontWeight: FontWeight.w700)),
                              ),
                            ]),
                            const SizedBox(height: 3),
                            Text('no address of its own · via ${hubHost('${n['via']}')}',
                                style: const TextStyle(color: kDim, fontSize: 11)),
                          ])),
                        ]),
                      );
                    }).toList());
                  },
                ),
                const SizedBox(height: 4),
                Text('$up serving you now · $onLedger self-announced on the XNO ledger · ${rvs.length} keyless rendezvous. '
                    'Strength = latency, reliability = recent uptime.',
                    style: const TextStyle(color: kDim, fontSize: 11, height: 1.4)),
                if (!loading && onLedger == 0 && up > 0) ...[
                  const SizedBox(height: 8),
                  Text('No relay has self-announced on the ledger yet, so discovery isn’t SPOF-free — '
                      'the app is using this node’s own relay. Announce an independent relay to add resilience.',
                      style: const TextStyle(color: Color(0xFFE0A83E), fontSize: 11, height: 1.4)),
                ],
              ]),
            );
          },
        );
      }),
    );
  }

  // edit the relay/engine endpoint (persisted; applied live)
  void _showEndpoint() {
    final ctl = TextEditingController(text: kBase);
    final secCtl = TextEditingController(text: MeshReach.secret);
    final hubCtl = TextEditingController(
        text: MeshReach.hubs.isEmpty ? kDefaultBase : MeshReach.hubs.join(', '));
    String meshStatus = '';
    Color meshStatusColor = kDim;
    bool meshBusy = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: const [
              Icon(Icons.dns_outlined, color: kAccent, size: 20), SizedBox(width: 8),
              Text('Endpoint', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
            ]),
            const SizedBox(height: 6),
            const Text('e.g. http://10.0.2.2:8787 (emulator → this Mac) or https://your-relay.fly.dev',
                style: TextStyle(color: kDim, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 13),
              keyboardType: TextInputType.url,
              decoration: _fieldDeco('https://…'),
            ),
            const SizedBox(height: 14),
            Row(children: [
              TextButton(
                onPressed: () async {
                  ctl.text = kDefaultBase;
                  (await SharedPreferences.getInstance()).remove('xchat_endpoint');
                },
                child: const Text('Reset to default', style: TextStyle(color: kDim)),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  final url = ctl.text.trim();
                  if (!url.startsWith('http')) return;
                  kBase = url;
                  await (await SharedPreferences.getInstance()).setString('xchat_endpoint', url);
                  // seedless node: nothing to activate — the app keeps the key, the node just relays.
                  if (!mounted) return;
                  Navigator.pop(context);
                  await _load();
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      backgroundColor: kCard, content: Text('connected to $url')));
                },
                style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                child: const Text('Save & connect', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 20),
            const Divider(color: kLine, height: 1),
            const SizedBox(height: 18),
            Row(children: const [
              Icon(Icons.hub_outlined, color: kAccent, size: 20), SizedBox(width: 8),
              Text('Mesh node', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
            ]),
            const SizedBox(height: 6),
            const Text('Reach a relay that has no public address of its own — it dials into a public hub. '
                'Leave the secret empty to auto-discover PUBLIC nodes the hub lists (no code). Enter a '
                'secret to reach a PRIVATE node shared with you. The hub only ever sees an opaque token.',
                style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
            const SizedBox(height: 12),
            const Text('Rendezvous secret', style: TextStyle(color: kDim, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            TextField(
              controller: secCtl,
              style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 13),
              decoration: _fieldDeco('shared secret'),
            ),
            const SizedBox(height: 10),
            const Text('Hub(s), comma-separated', style: TextStyle(color: kDim, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            TextField(
              controller: hubCtl,
              style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 13),
              keyboardType: TextInputType.url,
              decoration: _fieldDeco('https://hub.fly.dev'),
            ),
            if (meshStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(meshStatus, style: TextStyle(color: meshStatusColor, fontSize: 12.5, height: 1.4, fontFamily: 'monospace')),
            ],
            const SizedBox(height: 14),
            Row(children: [
              TextButton(
                onPressed: () async {
                  secCtl.clear();
                  await MeshReach.save('', []);
                  setSheet(() { meshStatus = 'mesh reach cleared'; meshStatusColor = kDim; });
                },
                child: const Text('Clear', style: TextStyle(color: kDim)),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: meshBusy ? null : () async {
                  final hubs = hubCtl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                  final secret = secCtl.text.trim();
                  await MeshReach.save(secret, hubs);
                  if (hubs.isEmpty) {
                    setSheet(() { meshStatus = 'enter at least one hub'; meshStatusColor = const Color(0xFFE0A83E); });
                    return;
                  }
                  String shortAcct(String a) => a.length > 20 ? '${a.substring(0, 12)}…${a.substring(a.length - 6)}' : a;
                  if (secret.isEmpty) {
                    // PUBLIC discovery — no secret. Ask the hubs which nodes are attached.
                    setSheet(() { meshBusy = true; meshStatus = 'discovering public nodes on the hub…'; meshStatusColor = kDim; });
                    await MeshReach.discoverVia(hubs);
                    final found = await MeshReach.probeDiscovered();
                    if (found.isEmpty) {
                      setSheet(() { meshBusy = false; meshStatus = '✗ this hub lists no public nodes right now'; meshStatusColor = const Color(0xFFEF6C9B); });
                      return;
                    }
                    final lines = found.map((f) => '✓ ${shortAcct('${f['account']}')}  type=${f['type']} ver=${f['ver'] ?? '?'}').join('\n');
                    setSheet(() {
                      meshBusy = false;
                      meshStatus = 'discovered ${found.length} public node(s) — no code:\n$lines\n  added to your relay set';
                      meshStatusColor = const Color(0xFF4DD0A7);
                    });
                    return;
                  }
                  // PRIVATE — derive the token from the secret.
                  setSheet(() { meshBusy = true; meshStatus = 'reaching node through hub…'; meshStatusColor = kDim; });
                  final info = await MeshReach.probe();
                  if (info == null) {
                    setSheet(() { meshBusy = false; meshStatus = '✗ no node answered through the hub (is it dialed in?)'; meshStatusColor = const Color(0xFFEF6C9B); });
                    return;
                  }
                  setSheet(() {
                    meshBusy = false;
                    meshStatus = '✓ reached node ${shortAcct('${info['account']}')}\n  type=${info['type']} ver=${info['ver'] ?? '?'}\n  the hub is routing to it now';
                    meshStatusColor = const Color(0xFF4DD0A7);
                  });
                },
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: Text(meshBusy ? 'working…' : 'Save & reach'),
              ),
            ]),
          ]),
        ),
        ),
      )),
    );
  }

  // manage the per-viewer mute / block lists (unmute / unblock)
  void _showMutedBlocked() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Widget row(String account, bool isBlock) {
          final handle = _handleFor(account);
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AuthorAvatar(account: account, handle: handle, radius: 18),
            title: AnimatedBuilder(
              animation: ProfileCache.I,
              builder: (_, __) => Text(ProfileCache.I.displayName(account, handle),
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 14)),
            ),
            subtitle: Text('@$handle', style: const TextStyle(color: kDim, fontSize: 12)),
            trailing: OutlinedButton(
              onPressed: () {
                if (isBlock) { _toggleBlock(account, handle); } else { _toggleMute(account, handle); }
                setSheet(() {});
              },
              style: OutlinedButton.styleFrom(foregroundColor: kText, side: const BorderSide(color: kLine),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
              child: Text(isBlock ? 'Unblock' : 'Unmute', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          );
        }
        return DraggableScrollableSheet(
          expand: false, initialChildSize: 0.7, maxChildSize: 0.95, minChildSize: 0.4,
          builder: (_, scroll) => Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: ListView(controller: scroll, children: [
              Row(children: const [
                Icon(Icons.block, color: kAccent, size: 20), SizedBox(width: 8),
                Text('Muted & blocked', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
              const SizedBox(height: 4),
              const Text('Per-viewer controls — this filters your own view; nothing is deleted from the network.',
                  style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const Padding(padding: EdgeInsets.only(top: 18, bottom: 4),
                  child: Text('Blocked', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 14))),
              if (_blocked.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No one blocked', style: TextStyle(color: kDim, fontSize: 13))),
              ..._blocked.map((a) => row(a, true)),
              const Padding(padding: EdgeInsets.only(top: 18, bottom: 4),
                  child: Text('Muted', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 14))),
              if (_muted.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No one muted', style: TextStyle(color: kDim, fontSize: 13))),
              ..._muted.map((a) => row(a, false)),
            ]),
          ),
        );
      }),
    );
  }

  // self-update: check the relays for a newer signed, content-addressed release; download +
  // verify (publisher signature on the record, sha256 on the bytes) before offering to install.
  void _showUpdates() {
    String phase = 'checking'; // checking | current | available | downloading | ready | error
    Map<String, dynamic> rel = {};
    Map<String, dynamic> fetched = {};
    String fmtMB(num b) => '${(b / 1048576).toStringAsFixed(1)} MB';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> check() async {
          setSheet(() => phase = 'checking');
          final r = await Api.releaseCheck();
          if (r == null || r['ok'] != true) {
            setSheet(() => phase = 'error');
          } else if (r['update'] == true) {
            setSheet(() { rel = r; phase = 'available'; });
          } else {
            setSheet(() { rel = r; phase = 'current'; });
          }
        }

        Future<void> download() async {
          setSheet(() => phase = 'downloading');
          try {
            final want = '${rel['sha256']}';
            // hash-verified CDN mirror first (fast binary), relays as the decentralized fallback
            final bytes = await Api.fetchReleaseApk('${rel['cid']}', want, mirrorUrl: rel['url'] as String?);
            if (bytes == null) {
              setSheet(() => phase = 'available');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    backgroundColor: kCard, content: Text('download failed hash check — not installing')));
              }
              return;
            }
            final dir = await getTemporaryDirectory();
            final f = File('${dir.path}/xchat-v${rel['version']}.apk');
            await f.writeAsBytes(bytes, flush: true);
            setSheet(() { fetched = {'size': bytes.length, 'path': f.path, 'sha256_ok': true}; phase = 'ready'; });
          } catch (e) {
            setSheet(() => phase = 'available');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  backgroundColor: kCard, content: Text('download failed: $e')));
            }
          }
        }

        Future<void> install() async {                            // hand the verified APK to the OS installer
          if (!kIsWeb && Platform.isIOS) {
            showDialog(
              context: ctx,
              builder: (_) => AlertDialog(
                backgroundColor: kCard,
                title: const Text('iOS blocks this step', style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.w800)),
                content: const Text('The build is downloaded and its publisher signature + SHA-256 are verified, but Apple '
                    'gates install (App Store / EU marketplaces / AltStore). That’s the one layer that isn’t censorship-free.',
                    style: TextStyle(color: kDim, fontSize: 13.5, height: 1.5)),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx),
                    child: const Text('Got it', style: TextStyle(color: kAccent, fontWeight: FontWeight.w700)))],
              ),
            );
            return;
          }
          final path = '${fetched['path'] ?? ''}';
          if (path.isEmpty) return;
          final res = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
          if (res.type != ResultType.done && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                backgroundColor: kCard,
                content: Text('Couldn’t open the installer (${res.message}). Allow “Install unknown apps” for Ӿ Chat, then tap Install again.')));
          }
        }

        // run the check once when the sheet first builds
        if (phase == 'checking' && rel.isEmpty && fetched.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (phase == 'checking' && rel.isEmpty) check();
          });
        }

        final pub = '${rel['publisher'] ?? ''}';
        final pubShort = pub.isEmpty ? '' : '${pub.substring(0, 14)}…${pub.substring(pub.length - 6)}';

        Widget verifiedRow(String label) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                const Icon(Icons.verified_user, size: 16, color: Color(0xFF4DD0A7)),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 13))),
              ]),
            );

        return Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.system_update, color: kAccent, size: 20),
              const SizedBox(width: 8),
              const Text('App updates', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
              const Spacer(),
              Text('v$kAppVersion', style: const TextStyle(color: kDim, fontSize: 13, fontFamily: 'monospace')),
            ]),
            const SizedBox(height: 6),
            const Text('Delivered by the network itself — a signed, content-addressed release on the relays. No app store in the path.',
                style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
            const SizedBox(height: 18),

            if (phase == 'checking')
              const Row(children: [
                SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
                SizedBox(width: 12),
                Text('Checking the relays…', style: TextStyle(color: kText, fontSize: 14)),
              ])
            else if (phase == 'error')
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Could not reach the relays to check for a release.', style: TextStyle(color: kText, fontSize: 14)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: check,
                    style: OutlinedButton.styleFrom(foregroundColor: kAccent, side: const BorderSide(color: kLine)),
                    child: const Text('Try again')),
              ])
            else if (phase == 'current')
              Row(children: const [
                Icon(Icons.check_circle, color: Color(0xFF4DD0A7), size: 20),
                SizedBox(width: 10),
                Expanded(child: Text('You’re on the latest signed release.', style: TextStyle(color: kText, fontSize: 14))),
              ])
            else ...[
              // available / downloading / ready — show the release
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('v${rel['version']}', style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0x1A3E9BFF), borderRadius: BorderRadius.circular(6)),
                      child: Text('new · ${fmtMB((rel['size'] ?? 0) as num)}', style: const TextStyle(color: kAccent, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('${rel['changelog'] ?? ''}', style: const TextStyle(color: kDim, fontSize: 13, height: 1.4)),
                  const SizedBox(height: 8),
                  const Divider(color: kLine, height: 18),
                  const Text('PUBLISHER', style: TextStyle(color: kDim, fontSize: 10, letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Text(pubShort, style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12)),
                  verifiedRow('Publisher signature verified'),
                  if (phase == 'ready') verifiedRow('Downloaded from relay cache · SHA-256 matches (${fmtMB((fetched['size'] ?? 0) as num)})'),
                ]),
              ),
              const SizedBox(height: 16),
              if (phase == 'available')
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: download,
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download & verify', style: TextStyle(fontWeight: FontWeight.w800)),
                ))
              else if (phase == 'downloading')
                const Row(children: [
                  SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
                  SizedBox(width: 12),
                  Text('Downloading from the relays…', style: TextStyle(color: kText, fontSize: 14)),
                ])
              else if (phase == 'ready')
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: install,
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF4DD0A7), foregroundColor: Colors.black),
                  icon: Icon(!kIsWeb && Platform.isIOS ? Icons.apple : Icons.android, size: 18),
                  label: Text(!kIsWeb && Platform.isIOS ? "Install (iOS gated)" : "Install", style: const TextStyle(fontWeight: FontWeight.w800)),
                )),
              const SizedBox(height: 10),
              const Text('GitHub is only a mirror — the publisher signature is the root of trust. A takedown of any relay doesn’t stop updates.',
                  style: TextStyle(color: kDim, fontSize: 11, height: 1.4)),
            ],
          ]),
        );
      }),
    );
  }

  Widget _splitBar(int creator, int reposter, int relay) {
    Widget seg(int flex, Color c, String label) => flex <= 0
        ? const SizedBox.shrink()
        : Expanded(
            flex: flex,
            child: Container(
              height: 34,
              alignment: Alignment.center,
              color: c,
              child: FittedBox(child: Text('$label $flex%',
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 11))),
            ));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Row(children: [
        seg(creator, const Color(0xFF4DD0A7), 'Creator'),
        seg(reposter, const Color(0xFFE0B64D), 'Reposter'),
        seg(relay, kAccent, 'Relay'),
      ]),
    );
  }

  Widget _sliderRow(String label, int val, void Function(int) set, StateSetter setSheet, VoidCallback persist) =>
      Row(children: [
        SizedBox(width: 150, child: Text(label, style: const TextStyle(color: kText, fontSize: 13))),
        Expanded(
          child: Slider(
            value: val.toDouble(),
            min: 0, max: 50, divisions: 50,
            activeColor: kAccent,
            label: '$val%',
            onChanged: (v) { set(v.round()); setSheet(() {}); },
            onChangeEnd: (_) => persist(),
          ),
        ),
        SizedBox(width: 38, child: Text('$val%', textAlign: TextAlign.right, style: const TextStyle(color: kDim, fontSize: 13))),
      ]);

  void _showSupporter() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final active = _supporterActive;
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.bolt, color: kAccent, size: 20),
                const SizedBox(width: 8),
                const Text('Supporter mode', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                Switch(
                    value: _supporterOn,
                    activeThumbColor: kAccent,
                    onChanged: (v) {
                      setState(() => _supporterOn = v);
                      setSheet(() {});
                      _syncSupporter();
                    }),
              ]),
              const Text('Propagate signed heads across the relay mesh for others — outbound only (no inbound needed), and only while charging and on Wi-Fi, so it never costs your battery.',
                  style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
              const SizedBox(height: 14),
              _gateRow('Supporter mode', _supporterOn),
              _gateRow('Charging', _charging),
              _gateRow('On Wi-Fi', _wifi),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: active ? const Color(0x1A4DD0A7) : kCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: active ? const Color(0xFF4DD0A7) : kLine)),
                child: Text(
                    !_supporterOn
                        ? 'Off — not contributing'
                        : active
                            ? '⚡ Contributing now — relaying heads & pinning content across the mesh · $_relayed synced this session'
                            : 'Standing by — will contribute when charging + on Wi-Fi',
                    style: TextStyle(
                        color: active ? const Color(0xFF4DD0A7) : kDim,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _gateRow(String label, bool on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18, color: on ? const Color(0xFF4DD0A7) : kDim),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: kText, fontSize: 14)),
        ]),
      );

  Future<void> _load({bool failedOver = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Cold start: paint the PERSISTED feed immediately (instant, no network), then below fetch ONLY
    // posts newer than the newest cached one and MERGE — instead of re-downloading the first page on
    // every launch and throwing the cache away.
    if (_posts.isEmpty) {
      final cached = await Api.loadCachedPosts();
      if (cached.isNotEmpty && mounted && _posts.isEmpty) {
        setState(() => _posts = cached);
      }
    }
    try {
      // Slim launch: fetch ONLY what the first paint needs — the feed, identity, and moderation labels.
      // With a warm cache the feed fetch is INCREMENTAL (since = newest we already hold), so a relaunch
      // pulls just the new posts; an empty cache (first run) fetches the first page. Notifications +
      // engagement counts load just after (see _loadSecondary) — a lighter startup burst.
      final haveTs = _newestTs();
      final incremental = _posts.isNotEmpty && haveTs > 0;
      final results = await Future.wait([
        incremental ? Api.feed(since: haveTs - 1) : Api.feed(limit: _pageSize),
        Api.me(),
        Api.labels(),
      ]);
      final fd = results[0] as FeedData;
      final me = results[1] as Map<String, dynamic>;
      final labelers = results[2] as List<Labeler>;
      setState(() {
        if (incremental) {
          // MERGE new posts into the persisted timeline (dedupe by id) — never replace what we cached.
          final seen = _posts.map((p) => p.id).toSet();
          final fresh = fd.posts.where((p) => !seen.contains(p.id)).toList();
          if (fresh.isNotEmpty) {
            _posts = [...fresh, ..._posts]..sort((a, b) => b.ts.compareTo(a.ts));
          }
        } else {
          // First run / empty cache. Never blank a good feed with a momentarily-empty one (e.g. a
          // just-restarted node whose feed cache is still warming).
          if (fd.posts.isNotEmpty || _posts.isEmpty) _posts = fd.posts;
        }
        _newPosts.clear();
        // (fd.onchainBlocks is always 0 — the feed is off-chain. The header's "Nano txns" count comes
        //  from the user's own on-chain block count instead; see _refreshTxCount.)
        if (fd.posts.isNotEmpty) {
          _relaysUp = fd.relaysUp;
          _relaysTotal = fd.relaysTotal;
        }
        _handle = me['handle'] ?? 'you.xno';
        _account = me['account'] ?? '';
        _balance = me['balance']?.toString() ?? '0';
        _labelers = labelers;
        _loading = false;
      });
      _persistFeed();   // keep the on-device cache current, bounded to feedCacheSize
      _syncSupporter(); // reflect current supporter state now that the account is known
      _initProfile();   // pull our own profile (name/avatar) into the cache
      _refreshTxCount(); // header "Nano txns" = your on-chain block count (now the account is known)
      _maybeSweep();    // keep only the safety-cap float here; forward the rest to savings
      _loadSecondary(); // notifications + engagement counts, AFTER first paint (off the launch burst)
    } catch (e) {
      // The current endpoint failed — try to fail over to a healthy one from the list, then retry ONCE.
      if (!failedOver && await resolveEndpoint()) {
        return _load(failedOver: true);
      }
      setState(() {
        _loading = false;
        // Keep showing the cached feed if we have one; only hard-error on a genuinely empty screen.
        if (_posts.isEmpty) _error = 'could not reach the ledger engine\n($kBase)';
      });
    }
  }

  // Secondary, non-first-paint data: the notification badge + engagement counts. Loaded just after the
  // feed renders so the launch fires 3 requests instead of 5 (lighter burst on the node, faster first frame).
  Future<void> _loadSecondary() async {
    try {
      _engage = await Api.engagement();
      if (mounted) setState(() {});
    } catch (_) {}
    // Seed a censorship-resistant fallback from the ledger while the current endpoint is healthy, so a
    // later takedown of the default nodes can't strand this install. Only until we've cached an endpoint
    // BEYOND the baked-in defaults — keeps the launch burst light and public RPCs unhammered.
    if (kEndpoints.length <= kBootstrapEndpoints.length) {
      unawaited(healEndpointsFromLedger(switchBase: false));
    }
    unawaited(resolveWorkBase()); // pick a fast-PoW (work:local) node for tip settlement, if any
    _refreshNotifs();    // notifications + raise Android alerts for new like/comment/tip
    _refreshDmBadge();   // mail-icon unread count + launcher badge (fire-and-forget)
    // Open the push stream here rather than in initState: this runs once the wallet exists and kBase
    // has settled on a reachable node, and a stream opened against the wrong base just fails and
    // backs off — burning the first two reconnect steps before it can possibly work.
    final me = gWallet?.account;
    if (me != null) DmPush.start(me);
    Api.announcement().then((a) { if (mounted) setState(() => _announcement = a); });  // coordinated-event banner
  }

  // Poll relay notifications; raise an ANDROID system notification for each NEW like/comment/tip whose
  // toggle is on. First run baselines to the newest existing so pre-install history never alerts (that
  // was a real bug once). Also refreshes the in-app _notifs list.
  Future<void> _refreshNotifs() async {
    if (gWallet == null) return;
    final list = await Api.notify();
    // Same reasoning as the DM badge: this fires every ~24s and replaced the list object every time,
    // so the feed rebuilt whether or not a notification had arrived. Compare cheaply — count plus the
    // newest timestamp is enough to catch anything that would change what is drawn.
    int newest(List<Map<String, dynamic>> l) {
      var m = 0;
      for (final n in l) { final t = (n['ts'] as num?)?.toInt() ?? 0; if (t > m) m = t; }
      return m;
    }
    if (mounted && (list.length != _notifs.length || newest(list) != newest(_notifs))) {
      setState(() => _notifs = list);
    }
    final p = await SharedPreferences.getInstance();
    final seen = p.getInt('notif_seen_ts') ?? -1;
    if (seen < 0) {                                    // first run → baseline, don't alert for history
      var mx = 0;
      for (final n in list) { final ts = (n['ts'] as num?)?.toInt() ?? 0; if (ts > mx) mx = ts; }
      await p.setInt('notif_seen_ts', mx);
      return;
    }
    var maxTs = seen;
    for (final n in list) {
      final ts = (n['ts'] as num?)?.toInt() ?? 0;
      if (ts <= seen) continue;
      if (ts > maxTs) maxTs = ts;
      final kind = '${n['kind']}';
      final on = kind == 'like' ? _settings.notifyLike
          : kind == 'comment' ? _settings.notifyComment
          : kind == 'tip' ? _settings.notifyTip
          : false;                                     // only the 3 user-activatable types
      if (!on) continue;
      // A tip alert is not a hint that money MIGHT be waiting — it is the sender telling us they paid.
      // Treat it as the trigger it is; the 12s backstop then has nothing left to find.
      if (kind == 'tip') _autoReceive();
      final title = kind == 'tip' ? '◈ New tip' : kind == 'like' ? '❤ New like' : '💬 New comment';
      Notifs.show('${n['from']}$ts'.hashCode & 0x7fffffff, title, '${n['text']}');
    }
    if (maxTs > seen) await p.setInt('notif_seen_ts', maxTs);
  }

  // Auto-forward anything above the safety cap to the user's external savings address (which this
  // app holds no key for), so the most a bad app build could ever touch is the small in-app float.
  bool _sweeping = false;
  Future<void> _maybeSweep() async {
    if (_sweeping || !_settings.autoSweep) return;
    final addr = _settings.sweepAddr.trim();
    if (!addr.startsWith('nano_') || addr.length < 60 || addr == _account) return;
    final xno = (double.tryParse(_balance) ?? 0) / 1e30;
    // NEVER sweep XNO pledged to un-settled tips — subtract the reservation from the sweepable excess,
    // and pass it to send() as a second guard. Without this, the sweep could forward tip funds to savings
    // and leave every pending tip permanently unsettleable ("insufficient balance").
    final reserved = _pendingTotal();
    final excess = xno - kWalletCapXno - reserved;
    if (excess <= 0.0001) return;
    _sweeping = true;
    try {
      final r = await Api.send(addr, excess.toStringAsFixed(6), reservedXno: reserved);
      if (r != null && r['ok'] == true) {
        await _load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              backgroundColor: kCard,
              content: Text('🛡 auto-moved ${excess.toStringAsFixed(2)} XNO above the cap to your savings')));
        }
      }
    } catch (_) {} finally {
      _sweeping = false;
    }
  }

  Future<void> _saveSweep({bool? on, String? addr}) async {
    setState(() {
      if (on != null) _settings.autoSweep = on;
      if (addr != null) _settings.sweepAddr = addr;
    });
    await SettingsStore.save(_settings);
    _maybeSweep();
  }

  Future<String?> _askSavingsAddr() async {
    final ctl = TextEditingController(text: _settings.sweepAddr);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Savings address', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('A Nano address in your OWN wallet — this app holds no key for it. Anything above the '
              'cap is auto-sent here, so a bad app build can never touch it.',
              style: TextStyle(color: kDim, fontSize: 12, height: 1.35)),
          const SizedBox(height: 10),
          TextField(controller: ctl, maxLines: 2,
              style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12),
              decoration: _fieldDeco('nano_…')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: kDim))),
          FilledButton(
            onPressed: () {
              final a = ctl.text.trim();
              if (a.startsWith('nano_') && a.length >= 60 && a != _account) Navigator.pop(context, a);
            },
            style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
            child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _compose({Post? quotedPost, Post? replyToPost}) async {
    final res = await showModalBottomSheet<ComposeResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => ComposeSheet(handle: _handle, account: _account, quotedPost: quotedPost,
          replyToPost: replyToPost, channels: _myChannels, people: _knownHandles()),
    );
    if (res == null || res.segments.isEmpty) return;
    // Build the compose intent. The head signs a node-assigned CID+seq that only exist after the node
    // assembles the thread, so a post can't be fully signed offline — instead we hold the intent and
    // replay it (Api.post) when we're back online, keeping the compose timestamp so order is preserved.
    final job = <String, dynamic>{
      'lid': 'o${DateTime.now().millisecondsSinceEpoch}',
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'handle': _handle,
      'segments': res.segments,
      'title': res.title,
      'quote': res.quote,
      'reply_to': replyToPost?.id ?? '',   // X-style reply: this post threads under replyToPost
      'mediaKind': res.mediaBytes != null ? res.mediaKind : '',
      'mediaB64': res.mediaBytes != null ? base64Encode(res.mediaBytes!) : '',
      'poll': res.pollOptions,
      'channel': res.channel,
    };
    final n = res.segments.length;

    // OFFLINE → queue immediately (don't lose the post). Flushes automatically on reconnect.
    if (!await _onlineNow()) {
      setState(() => _outbox.insert(0, job));
      await Outbox.saveAll(_outbox);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text('you\'re offline — queued · will send when you\'re back online')));
      return;
    }

    if (res.mediaBytes != null && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(milliseconds: 1200), backgroundColor: kCard, content: Text('uploading media…')));
    final ok = await _sendJob(job);
    if (!ok) {
      // online but the send failed (e.g. dropped mid-flight) → queue it rather than lose it
      setState(() => _outbox.insert(0, job));
      await Outbox.saveAll(_outbox);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 5), backgroundColor: kCard,
          content: Text('couldn\'t reach the relays — queued · will retry when you\'re back online')));
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text(res.pollOptions.isNotEmpty
                  ? '📊 poll posted · signed · 0 Nano blocks'
                  : res.title.isNotEmpty
                      ? '📄 published your article · signed · 0 Nano blocks'
                      : res.quote.isNotEmpty
                          ? 'quoted & posted off-chain · 0 Nano blocks'
                          : n > 1
                              ? '🧵 posted a $n-post thread · signed · 0 Nano blocks'
                              : 'signed & posted off-chain · 0 Nano blocks')));
    }
    await _load();
    // the node caches the feed for ~5s, so a just-posted item can miss the immediate reload — a
    // delayed full reload (not the quiet poll) makes YOUR OWN post appear in the timeline directly,
    // rather than hidden behind the "new posts" pill meant for other people's posts.
    Future.delayed(const Duration(seconds: 6), () { if (mounted) _load(); });
  }

  // quote a post (opens compose with the post embedded)
  void _quotePost(Post p) => _compose(quotedPost: p);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          onPressed: _showWallet,
          // your real avatar (live/animated or photo), not just the handle's initial
          icon: AuthorAvatar(account: _account, handle: _handle, radius: 15),
        ),
        titleSpacing: 0,
        title: Row(mainAxisSize: MainAxisSize.min, children: const [
          NanoMark(size: 24),
          SizedBox(width: 6),
          Text('Chat',
              style: TextStyle(
                  color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
        ]),
        actions: [
          // encrypted direct messages
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _openDms,
            icon: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.mail_outline, size: 21, color: kText),
              if (_dmUnread > 0)
                Positioned(
                  right: -3, top: -3,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: Color(0xFFEF6C9B), shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                    child: Text('$_dmUnread',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          ),
          // push wakeups: bell with unread count
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _showNotifs,
            icon: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.notifications_none, size: 21, color: kText),
              if (_notifUnread > 0)
                Positioned(
                  right: -3, top: -3,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: Color(0xFFEF6C9B), shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                    child: Text('$_notifUnread',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          ),
          // pending tips → the settle menu. Shown when something is waiting, a policy is on, OR there
          // is settled history — so the Transactions receipt trail stays reachable after the tally clears.
          if (_pending.isNotEmpty || _autoSettle || _txLog.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Stack(clipBehavior: Clip.none, children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: _showSettle,
                  tooltip: 'Tips to settle',
                  icon: const Icon(Icons.paid_outlined, size: 21, color: kAccent),
                ),
                if (_pending.isNotEmpty)
                  Positioned(
                    right: 1, top: 3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                      decoration: const BoxDecoration(color: Color(0xFFEF6C9B), shape: BoxShape.circle),
                      child: Text('${_pending.length}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
          // supporter mode
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _showSupporter,
            icon: Icon(Icons.bolt,
                size: 21, color: _supporterActive ? const Color(0xFF4DD0A7) : kText),
          ),
          // moderation: cycle the reputation-weighted threshold (or off)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              onTap: _cycleMod,          // always tappable: set your filter strength; it bites as reports land
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.shield_outlined,
                      size: 18,
                      color: _thresh[_modIdx] > 1 ? kDim : kAccent),
                  const SizedBox(width: 4),
                  Text(_threshLbl[_modIdx],
                      style: TextStyle(
                          color: _thresh[_modIdx] > 1 ? kDim : kAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(27),
            child: Column(children: [
              InkWell(
                onTap: _showRelays,      // tap the strip → the relay panel (per-relay strength + reliability)
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFF07130E),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(
                      child: Text(
                          '⛓ ${_onchainBlocks} Nano txn${_onchainBlocks == 1 ? '' : 's'}  ·  ${_posts.length} posts off-chain  ·  📡 ${_relaysUp}/${_relaysTotal} relays',
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF4DD0A7), fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 3),
                    const Icon(Icons.chevron_right, size: 14, color: Color(0xFF4DD0A7)),
                  ]),
                ),
              ),
              Container(color: kLine, height: 1),
            ])),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kAccent,
        onPressed: _compose,
        child: const Icon(Icons.add, color: Colors.black, size: 30),
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          backgroundColor: kBg,
          selectedItemColor: kAccent,
          unselectedItemColor: kDim,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.dynamic_feed_outlined), activeIcon: Icon(Icons.dynamic_feed), label: 'Channels'),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Discover'),
          ],
        ),
      ]),
      // only blank to a spinner on the FIRST load (nothing to show yet). A refresh with posts already
      // on screen keeps the timeline visible and updates in place — the RefreshIndicator shows its own
      // spinner — so the display is never lost.
      body: (_loading && _posts.isEmpty)
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          // A cold start while OFFLINE fails the feed load, but if there are QUEUED posts we must still
          // show them (the feed with its pending cards) instead of a bare error — else a restart hides
          // your unsent posts. Send-now + pull-to-refresh retry; Settings holds the server-address editor.
          : (_error != null && _outbox.isEmpty)
              ? _ErrorView(msg: _error!, onRetry: _load, onEndpoint: _showEndpoint)
              : _tab == 2
                  ? DiscoverScreen(
                      initialQuery: _discoverQ,
                      myAccount: _account,
                      posts: _posts.where((p) => !_hidden(p.account)).toList(),
                      authors: _authors(),
                      follows: _follows,
                      engage: _engage,
                      liked: _liked,
                      reposted: _reposted,
                      onToggleFollow: _toggleFollow,
                      pendingOf: (a) => _pending[a] ?? 0,
                      commentCountOf: (pid) => _commentCount[pid] ?? 0,
                      onTipPost: _tallyTip,
                      onLikePost: _toggleLike,
                      onRepostPost: _toggleRepost,
                      onReportPost: _reportPost,
                      onCommentPost: _openComments,
                      onOpenProfile: _openProfile,
                      cardBuilder: _profileCard)
                  : _tab == 1
                      ? ChannelsScreen(onOpenChannel: _openProfile)
                      : _homeBody(),
    );
  }

  // a queued (offline) post, pinned at the top of the feed until it sends. Shows what's waiting and
  // lets the user send it now (when back online) or discard it.
  Widget _queuedCard(Map<String, dynamic> job) {
    const warn = Color(0xFFE0A63A);
    final segs = (job['segments'] as List).cast<String>();
    final hasMedia = (job['mediaB64'] as String? ?? '').isNotEmpty;
    final title = (job['title'] as String? ?? '');
    return Container(
      color: warn.withOpacity(0.06),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 20, backgroundColor: kAccent.withOpacity(0.3),
              child: Text(_handle.isNotEmpty ? _handle[0].toUpperCase() : 'Y',
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          const SizedBox(width: 10),
          Flexible(child: Text(_handle, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold))),
          const SizedBox(width: 6),
          const Text('· queued', style: TextStyle(color: kDim, fontSize: 13)),
        ]),
        const SizedBox(height: 6),
        if (title.isNotEmpty)
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Text(segs.first + (segs.length > 1 ? '  +${segs.length - 1} more' : ''),
            maxLines: 4, overflow: TextOverflow.ellipsis),
        if (hasMedia)
          const Padding(padding: EdgeInsets.only(top: 4),
              child: Text('📎 media attached', style: TextStyle(color: kDim, fontSize: 13))),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.cloud_off, size: 15, color: warn),
          const SizedBox(width: 6),
          const Expanded(child: Text('pending · will send when you\'re online',
              style: TextStyle(color: warn, fontSize: 12.5))),
          TextButton(
              onPressed: _flushing ? null : () async {
                if (await _onlineNow()) {
                  _flushOutbox();
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      backgroundColor: kCard, content: Text('still offline — it\'ll send automatically when you reconnect')));
                }
              },
              child: const Text('Send now')),
          TextButton(
              onPressed: () => _discardQueued(job),
              child: const Text('Discard', style: TextStyle(color: kDim))),
        ]),
      ]),
    );
  }

  Widget _updateBanner() {
    final r = _update!;
    return Material(
      color: kAccent.withOpacity(0.14),
      child: InkWell(
        onTap: _showUpdates,   // the full download+verify+install flow
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            const Icon(Icons.system_update, size: 18, color: kAccent),
            const SizedBox(width: 10),
            Expanded(child: Text('Update available · v${r['version']} — tap to install',
                style: const TextStyle(color: kAccent, fontWeight: FontWeight.w600, fontSize: 13.5))),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18, color: kDim),
              tooltip: 'Dismiss',
              onPressed: () async {
                await UpdateDismiss.set('${r['version']}');   // don't nag again for this version
                if (mounted) setState(() => _update = null);
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget _backupBanner() {
    const warn = Color(0xFFE0A63A);
    return Material(
      color: warn.withOpacity(0.16),
      child: InkWell(
        onTap: _showBackupSheet,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: const [
            Icon(Icons.warning_amber_rounded, size: 18, color: warn),
            SizedBox(width: 10),
            Expanded(child: Text("Back up your recovery seed — it's the only way to recover this wallet. Tap to secure it.",
                style: TextStyle(color: warn, fontWeight: FontWeight.w600, fontSize: 13))),
            Icon(Icons.chevron_right, size: 18, color: warn),
          ]),
        ),
      ),
    );
  }

  // Show-seed → verify flow for an EXISTING wallet that never confirmed a backup (the footgun guard).
  // REQUEST FUNDS: the address someone needs in order to pay you, as a QR and as text. This is what
  // "Receive" means in a wallet people already know how to use — not a button that claims blocks.
  // Anything sent here is pocketed automatically (see _autoReceive), so there is no follow-up step
  // and nothing for the user to remember.
  void _showRequest() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: kBg,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Request XNO',
                  style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 6),
              const Text('Scan or copy. It arrives on its own — nothing to tap afterwards.',
                  textAlign: TextAlign.center, style: TextStyle(color: kDim, fontSize: 12.5)),
              const SizedBox(height: 18),
              // A white quiet-zone is part of the QR spec, not decoration: scanners need the contrast,
              // and on this app's black background a bare QR is unreadable by most phone cameras.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(
                  data: 'nano:$_account',            // the nano: URI other wallets already parse
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
              const SizedBox(height: 18),
              // Plain Text, not SelectableText: the latter painted NOTHING here under Impeller on the
              // emulator — no exception, just an empty gap where a 65-char address should be. Selection
              // buys nothing anyway when there is a Copy button right below it, so this trades a widget
              // that can silently fail to render for one that cannot.
              Text(_account,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kText, fontSize: 12.5, fontFamily: 'monospace', height: 1.45)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () { _copy(_account, 'Address'); Navigator.pop(ctx); },
                    style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy address', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
              // The single most important thing to say at the moment money is about to arrive: this
              // account is PUBLIC and PERMANENT on the Nano ledger, and how it gets funded is what ties
              // it — or doesn't — to a real name. Shown every time, not once, because the deanonymising
              // mistake (a withdrawal from a KYC exchange) can happen at any funding, not just the first.
              // Tap opens the full explanation. See docs/ANONYMITY.md §1 "Identity is money".
              const SizedBox(height: 14),
              InkWell(
                onTap: () { Navigator.pop(ctx); _showFundingPrivacy(); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                      color: const Color(0xFF4DD0A7).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF4DD0A7).withValues(alpha: 0.32))),
                  child: Row(children: [
                    const Icon(Icons.public, size: 18, color: Color(0xFF4DD0A7)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Public ledger: funding this account from a KYC exchange can link it to your real name.',
                          style: TextStyle(color: kText, fontSize: 12.5, height: 1.35)),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: Color(0xFF4DD0A7)),
                  ]),
                ),
              ),
              // The backup nag belongs HERE — at the moment you invite money in — rather than in front
              // of a claim. Blocking a claim never protected anything: the funds are already assigned
              // to this account on-chain, so losing the seed loses them whether or not they were
              // pocketed. What actually helps is saying so before more arrives.
              if (_needsBackup) ...[
                const SizedBox(height: 14),
                InkWell(
                  onTap: () { Navigator.pop(ctx); _showBackupSheet(); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                        color: const Color(0xFFE0A63A).withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE0A63A).withValues(alpha: 0.45))),
                    child: Row(children: [
                      const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFE0A63A)),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Back up your seed first — without it this wallet cannot be recovered.',
                            style: TextStyle(color: Color(0xFFE0A63A), fontSize: 12.5)),
                      ),
                      const Icon(Icons.chevron_right, size: 18, color: Color(0xFFE0A63A)),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  // The full funding-privacy explanation, opened from the note on the receive sheet and once at
  // wallet creation. Deliberately plain and non-alarmist: it describes how a public ledger works and
  // the one mistake that undoes pseudonymity, rather than promising anonymity the app cannot give.
  // Mirrors docs/ANONYMITY.md — "pseudonymous, with an audit trail on a public ledger".
  void _showFundingPrivacy() {
    Widget para(String s) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(s, style: const TextStyle(color: kDim, fontSize: 13.5, height: 1.5)),
        );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: kBg,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: const [
                Icon(Icons.public, size: 20, color: Color(0xFF4DD0A7)),
                SizedBox(width: 10),
                Text('Your account is public',
                    style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
              const SizedBox(height: 16),
              para('Your identity here is a Nano account. The Nano ledger is public and permanent — anyone can look up this account\'s balance and every payment it has ever sent or received, forever.'),
              para('If you fund it from an exchange that knows who you are (any KYC exchange), that withdrawal ties this account to your legal name. If you move funds between this account and another one of yours, the two become linkable as well.'),
              para('To stay pseudonymous: fund this account in a way that isn\'t tied to your name, and keep it separate from accounts that are. What you post and who you message is end-to-end encrypted — but the money is not, because the ledger is shared by everyone.'),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                    color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
                child: const Text('This is how a public ledger works — not something the app can hide for you.',
                    style: TextStyle(color: kDim, fontSize: 12.5, height: 1.4)),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                  child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _showBackupSheet() {
    final w = _wallet;
    if (w == null) return;
    final seed = w.seed;
    String phase = 'show';
    List<int> vpos = [];
    final vctl = [TextEditingController(), TextEditingController(), TextEditingController()];
    String? verr;
    bool saved = false;
    Widget bigBtn(String label, bool enabled, VoidCallback? onTap) => SizedBox(width: double.infinity,
        child: ElevatedButton(onPressed: enabled ? onTap : null,
            style: ElevatedButton.styleFrom(backgroundColor: enabled ? kAccent : kLine, foregroundColor: enabled ? Colors.black : kDim,
                padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))));
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: phase == 'show'
              ? [
                  const Text('Back up your recovery seed', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 20)),
                  const SizedBox(height: 8),
                  const Text('This 64-character seed IS your wallet. Write it down and keep it secret — anyone with it controls your account, and nobody can recover it for you.',
                      style: TextStyle(color: kDim, fontSize: 13, height: 1.5)),
                  const SizedBox(height: 16),
                  Container(width: double.infinity, padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                      child: SelectableText(seed, style: const TextStyle(color: kAccent, fontFamily: 'monospace', fontSize: 15, height: 1.5, letterSpacing: 1))),
                  const SizedBox(height: 14),
                  InkWell(onTap: () => setSheet(() => saved = !saved), child: Row(children: [
                    Icon(saved ? Icons.check_box : Icons.check_box_outline_blank, color: saved ? kAccent : kDim),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('I have written it down and stored it safely', style: TextStyle(color: kText, fontSize: 14))),
                  ])),
                  const SizedBox(height: 16),
                  bigBtn('Continue', saved, () {
                    final rnd = math.Random();
                    vpos = [rnd.nextInt(21), 21 + rnd.nextInt(21), 42 + rnd.nextInt(22)];
                    for (final c in vctl) { c.clear(); }
                    setSheet(() { verr = null; phase = 'verify'; });
                  }),
                ]
              : [
                  const Text('Confirm your backup', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 20)),
                  const SizedBox(height: 8),
                  const Text('Enter the character at each position from your written seed (hidden here on purpose).',
                      style: TextStyle(color: kDim, fontSize: 13, height: 1.5)),
                  const SizedBox(height: 18),
                  for (int i = 0; i < vpos.length; i++) Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(children: [
                    SizedBox(width: 116, child: Text('Character #${vpos[i] + 1}', style: const TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: vctl[i], maxLength: 1, textAlign: TextAlign.center,
                        style: const TextStyle(color: kAccent, fontFamily: 'monospace', fontSize: 20, letterSpacing: 2),
                        decoration: InputDecoration(counterText: '', filled: true, fillColor: kCard,
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kLine)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kAccent))))),
                  ])),
                  if (verr != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(verr!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 13))),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setSheet(() => phase = 'show'),
                      child: const Text('View seed again', style: TextStyle(color: kDim)))),
                  const SizedBox(height: 6),
                  bigBtn('Confirm', true, () async {
                    for (int i = 0; i < vpos.length; i++) {
                      if (vctl[i].text.trim().toLowerCase() != seed[vpos[i]].toLowerCase()) {
                        setSheet(() => verr = "That doesn't match. Check your written seed.");
                        return;
                      }
                    }
                    await BackupStore.set(w.account, true);
                    if (mounted) setState(() => _needsBackup = false);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        backgroundColor: kCard, content: Text('✓ backup confirmed — your wallet is recoverable from your seed')));
                  }),
                ],
              ),
            ),
          ),
        ),
      );
  }

  Widget _homeBody() {
    final posts = _homeFeed == 0 ? _forYouPosts() : _homePosts();
    return Column(children: [
      if (_announcement != null) _AnnouncementMarquee(text: _announcement!),
      if (_needsBackup) _backupBanner(),
      if (_update != null) _updateBanner(),
      // For You / Following segmented header (X-style), with a transparency ⓘ
      Container(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
        child: Row(children: [
          _feedTabBtn('For You', 0),
          _feedTabBtn('Following', 1),
          if (_homeFeed == 0)
            IconButton(
              onPressed: _showRankingInfo,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.tune, size: 19, color: kDim),
              tooltip: 'How your feed is ranked',
            ),
        ]),
      ),
      Expanded(
        // the timeline, with a floating "N new posts" pill overlaid at the top (X-style). New posts
        // are held in _newPosts and only merged in when the reader taps the pill — so the scroll
        // position never jumps under them.
        child: Stack(children: [
          RefreshIndicator(
            color: kAccent,
            backgroundColor: kCard,
            onRefresh: _load,
            child: ListView.separated(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              // queued (offline) posts are pinned at the very top until they send
              itemCount: _outbox.length + posts.length + 1,
              separatorBuilder: (_, __) => Container(color: kLine, height: 1),
              itemBuilder: (_, i) {
                if (i < _outbox.length) {
                  return KeyedSubtree(
                      key: ValueKey(_outbox[i]['lid']), child: _queuedCard(_outbox[i]));
                }
                final j = i - _outbox.length;
                if (j == posts.length) {
                  return (_homeFeed == 1 && _follows.isEmpty)
                      ? const _DiscoverHint()
                      : const _LedgerFooter();
                }
                // stable identity per post so a feed refresh matches elements by post, not by slot —
                // without this the list recycles cards across posts and their media gets mismatched.
                // clean single card per post; tap it to open the full conversation (X-style thread view).
                return KeyedSubtree(key: ValueKey(posts[j].id), child: _profileCard(posts[j]));
              },
            ),
          ),
          if (_newPosts.isNotEmpty && _homeFeed == 0)
            Positioned(top: 10, left: 0, right: 0, child: Center(child: _newPostsPill())),
        ]),
      ),
    ]);
  }

  Widget _newPostsPill() {
    final n = _newPosts.length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _showNewPosts,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: kAccent,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.arrow_upward, size: 15, color: Colors.black),
            const SizedBox(width: 6),
            Text('$n new post${n == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      ),
    );
  }

  Widget _feedTabBtn(String label, int i) {
    final on = _homeFeed == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _homeFeed = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: on ? kAccent : Colors.transparent, width: 2.5))),
          child: Center(child: Text(label,
              style: TextStyle(color: on ? kText : kDim, fontWeight: on ? FontWeight.w800 : FontWeight.w600, fontSize: 15))),
        ),
      ),
    );
  }

  // transparency: show exactly how "For You" ranks, and let the viewer tune it
  void _showRankingInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        void persist() { SettingsStore.save(_settings); setState(() {}); }
        Widget chip(String label, int val) {
          final on = _settings.forYouFreshness == val;
          return GestureDetector(
            onTap: () { _settings.forYouFreshness = val; setSheet(() {}); persist(); },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                  color: on ? kAccent : kCard, borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: on ? kAccent : kLine)),
              child: Text(label, style: TextStyle(color: on ? Colors.black : kText, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: const [
              Icon(Icons.tune, color: kAccent, size: 20), SizedBox(width: 8),
              Text('How your feed is ranked', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
            ]),
            const SizedBox(height: 6),
            const Text('No black box. “For You” scores every post by a formula you can see — and change. '
                'Nothing is hidden; muted/blocked people are simply left out.',
                style: TextStyle(color: kDim, fontSize: 12.5, height: 1.45)),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
              child: const Text(
                  'score  =  engagement  +  recency  +  follow-boost\n\n'
                  'engagement = likes×1 + reposts×2 + comments×1.5 + tips×20\n'
                  'recency    = newer posts score higher\n'
                  'follow-boost = +3 if you follow the author',
                  style: TextStyle(color: kText, fontFamily: 'monospace', fontSize: 12, height: 1.5)),
            ),
            const Padding(padding: EdgeInsets.only(top: 18, bottom: 8),
                child: Text('Emphasis', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 14))),
            Row(children: [
              chip('Popular', 0), const SizedBox(width: 8),
              chip('Balanced', 1), const SizedBox(width: 8),
              chip('Latest', 2),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: kAccent,
              value: _settings.forYouBoostFollows,
              onChanged: (v) { _settings.forYouBoostFollows = v; setSheet(() {}); persist(); },
              title: const Text('Boost people you follow', style: TextStyle(color: kText, fontSize: 14.5)),
              subtitle: const Text('lift posts from accounts you follow', style: TextStyle(color: kDim, fontSize: 11.5)),
            ),
          ]),
        );
      }),
    );
  }
}

// Shows how relays were found. When the engine resolves the set off the XNO ledger, this proves
// there's no hardcoded relay URL: one anchor XNO address → the ledger → the live relay set.
class _DiscoveryTile extends StatefulWidget {
  const _DiscoveryTile();
  @override
  State<_DiscoveryTile> createState() => _DiscoveryTileState();
}

class _DiscoveryTileState extends State<_DiscoveryTile> {
  late Future<Map<String, dynamic>?> _f;
  @override
  void initState() {
    super.initState();
    _f = Api.relaydir();
  }

  String _short(String a) => a.length > 22 ? '${a.substring(0, 14)}…${a.substring(a.length - 6)}' : a;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _f,
      builder: (_, snap) {
        final onChain = snap.data != null && snap.data!['source'] == 'xno-scan';
        final relays = (snap.data?['relays'] as List?) ?? const [];
        final rvs = (snap.data?['rendezvous'] as List?) ?? const [];
        final loading = snap.connectionState != ConnectionState.done;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: onChain ? kAccent.withOpacity(0.5) : kLine),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(loading ? Icons.hourglass_empty : (onChain ? Icons.hub : Icons.link_off),
                  color: onChain ? kAccent : kDim, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loading
                      ? 'Scanning the XNO ledger for relays…'
                      : (onChain ? 'Relays self-announced on the XNO ledger' : 'Relays from configured endpoint'),
                  style: TextStyle(color: onChain ? kText : kDim, fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ),
              if (onChain)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: kAccent.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                  child: const Text('no SPOF', style: TextStyle(color: kAccent, fontWeight: FontWeight.w800, fontSize: 10)),
                ),
            ]),
            if (onChain) ...[
              const SizedBox(height: 8),
              Text('${relays.length} relay${relays.length == 1 ? '' : 's'}, each self-announced on its own chain — '
                  'found by scanning ${rvs.length} keyless rendezvous point${rvs.length == 1 ? '' : 's'} (no owner, no directory).',
                  style: const TextStyle(color: kDim, fontSize: 11, height: 1.35)),
              if (rvs.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('rendezvous: ${_short(rvs.first as String)}${rvs.length > 1 ? ' +${rvs.length - 1} more' : ''}',
                    style: const TextStyle(color: kText, fontFamily: 'monospace', fontSize: 10)),
              ],
            ] else if (!loading) ...[
              const SizedBox(height: 6),
              const Text('No relays self-announced on the ledger yet — using the endpoint above.',
                  style: TextStyle(color: kDim, fontSize: 11, height: 1.3)),
            ],
          ]),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  final VoidCallback? onEndpoint;
  const _ErrorView({required this.msg, required this.onRetry, this.onEndpoint});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const NanoMark(size: 54),
          const SizedBox(height: 16),
          Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: kDim, height: 1.4)),
          const SizedBox(height: 8),
          const Text('On a phone, 10.0.2.2 only works in the emulator — set the server to your '
              'computer’s LAN address (e.g. http://192.168.x.x:8788).',
              textAlign: TextAlign.center, style: TextStyle(color: kDim, fontSize: 12, height: 1.4)),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onEndpoint,
            style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: const Text('Set server address', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(foregroundColor: kAccent, side: const BorderSide(color: kAccent)),
              child: const Text('Retry')),
        ]),
      ),
    );
  }
}

// the batched settle bar: tips accrued off-chain; one direct send per creator on tap.
// A gear opens the auto-settle policy; when a policy is on, its rule is shown here.
class _SettleBar extends StatelessWidget {
  final Map<String, double> pending;
  final Future<void> Function() onSettle;
  final bool auto;
  final double threshold;
  final VoidCallback onConfigure;
  const _SettleBar(
      {required this.pending,
      required this.onSettle,
      required this.auto,
      required this.threshold,
      required this.onConfigure});
  @override
  Widget build(BuildContext context) {
    final total = pending.values.fold<double>(0, (a, b) => a + b);
    final n = pending.length;
    final empty = pending.isEmpty;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: const BoxDecoration(
            color: kCard, border: Border(top: BorderSide(color: kLine))),
        child: Row(children: [
          const XnoGlyph(size: 20, color: kAccent, weight: 0.16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      empty
                          ? 'Auto-settle is on'
                          : '${total.toStringAsFixed(2)} XNO tallied to $n creator${n == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: kText, fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(
                      auto
                          ? 'auto-settles each creator at ≥${threshold.toStringAsFixed(2)} XNO — or settle now'
                          : 'off-chain so far — settle sends one direct Nano block each',
                      style: const TextStyle(color: kDim, fontSize: 11)),
                ]),
          ),
          IconButton(
            onPressed: onConfigure,
            icon: Icon(Icons.tune, size: 20, color: auto ? kAccent : kDim),
            tooltip: 'Auto-settle policy',
          ),
          if (!empty)
            ElevatedButton(
              onPressed: onSettle,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20))),
              child: const Text('Settle',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

class _DiscoverHint extends StatelessWidget {
  const _DiscoverHint();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(22),
        alignment: Alignment.center,
        child: const Text(
            '👋 you follow no one yet.\nFollowing shows only people you follow — tap Discover to find some, or switch to For You.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kDim, fontSize: 12, height: 1.6)),
      );
}

// Discover: search people + posts, and follow accounts. Search is the "search engine".
// DM inbox: decrypted conversations, newest first. The relays only ever hold ciphertext.
class DmInboxScreen extends StatefulWidget {
  final String Function(String account) handleOf;
  final bool Function(String account) isBlocked;
  final Future<void> Function(String account, String handle) onOpen;
  const DmInboxScreen({super.key, required this.handleOf, required this.isBlocked, required this.onOpen});
  @override
  State<DmInboxScreen> createState() => _DmInboxScreenState();
}

class _DmInboxScreenState extends State<DmInboxScreen> {
  List<Map<String, dynamic>> _convos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _showCachedThenRefresh();
  }

  List<GroupChat> _groups = [];

  /// Paint the on-device store first (instant), then refresh from the network. A returning user's
  /// conversations are already on disk, so making them watch a cold-fetch spinner to see them was
  /// pure waited-for-nothing. Only drops the spinner if the cache actually has something — an empty
  /// cache keeps the spinner rather than flashing "No messages" before the fetch answers.
  Future<void> _showCachedThenRefresh() async {
    final cached = await Api.dmInboxCached();
    if (mounted && _loading && cached.isNotEmpty) {
      setState(() {
        _convos = cached.where((x) => !widget.isBlocked('${x['peer']}')).toList();
        _groups = GroupChat.extract(cached);
        _loading = false;
      });
    }
    await _load();
  }

  Future<void> _load() async {
    final c = await Api.dmInbox();
    if (mounted) setState(() {
      _convos = c.where((x) => !widget.isBlocked('${x['peer']}')).toList();
      // Groups are derived from the SAME messages, before the block filter — a group you are in is
      // not dissolved because you blocked one of its members; their envelopes simply stop arriving.
      _groups = GroupChat.extract(c);
      _loading = false;
    });
    // PREFETCH every peer's profile the moment the list loads, rather than waiting for each row's
    // avatar to lazily fetch as it scrolls into view. Without this the inbox paints each conversation
    // under its owner's DEFAULT handle ('you.xno' — which most accounts share) and only resolves to
    // the real name a beat later, so a thread that reads "Jiован" in its header shows as "you.xno" in
    // the list. ensure() de-dups and no-ops once cached, so this is cheap and idempotent.
    for (final x in _convos) {
      ProfileCache.I.ensure('${x['peer']}');
    }
    for (final g in _groups) {
      for (final m in g.members) {
        ProfileCache.I.ensure(m);
      }
    }
  }

  /// The name this person is shown under everywhere else in the app.
  ///
  /// NOT the posting handle: most accounts still carry the default 'you.xno', so a member picker
  /// built on handles lists three different people as "you.xno" while the conversation right above
  /// it says "Jiován". Same source as the inbox rows, plus the account discriminator so two people
  /// who chose the same display name are still distinguishable — which in a member picker is the
  /// difference between messaging your friend and messaging a stranger.
  String _handleOf(String account) {
    final h = widget.handleOf(account);
    final n = ProfileCache.I.displayName(account, h);
    return n.isNotEmpty && n != 'you.xno' ? n : '${h.isEmpty ? "account" : h} ·${acctTag(account)}';
  }

  Future<void> _newGroup() async {
    final peers = _convos.map((c) => '${c['peer']}').toList();
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Message someone first — a group is built from people you can already '
              'reach.')));
      return;
    }
    final nameCtl = TextEditingController();
    final picked = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('New group', style: TextStyle(color: kText)),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtl,
                style: const TextStyle(color: kText),
                decoration: const InputDecoration(
                    hintText: 'Group name', hintStyle: TextStyle(color: kDim)),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in peers)
                      CheckboxListTile(
                        dense: true,
                        value: picked.contains(p),
                        onChanged: (v) => setD(() =>
                            v == true ? picked.add(p) : picked.remove(p)),
                        title: Text(_handleOf(p),
                            style: const TextStyle(color: kText, fontSize: 14)),
                      ),
                  ],
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel', style: TextStyle(color: kDim))),
            TextButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Create', style: TextStyle(color: kAccent))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty || picked.isEmpty) return;
    final me = gWallet?.account;
    if (me == null) return;
    // The creator is always a member. Not a courtesy — the sender re-reads their own history off a
    // relay like everyone else, so a group you cannot address yourself is one you cannot re-read.
    final members = <String>{me, ...picked}.toList()..sort();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final gid = NanoWallet.groupId(me, name, ts);
    // A group only exists once a message announces it: there is no group record to publish, so the
    // first message IS the creation. Sending it here means the others see the group immediately
    // rather than when you first happen to speak.
    final r = await Api.groupSend(gid, name, members, 'created the group');
    if (!mounted) return;
    if (r['ok'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${r['error'] ?? 'could not create the group'}')));
      return;
    }
    await _load();
    if (!mounted) return;
    final g = _groups.firstWhere((x) => x.gid == gid,
        orElse: () => GroupChat(gid, name, members, [], ts));
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GroupChatScreen(group: g, handleOf: _handleOf)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        title: const Text('Messages', style: TextStyle(color: kText, fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            onPressed: _newGroup,
            tooltip: 'New group',
            icon: const Icon(Icons.group_add_outlined, color: kText),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Container(width: double.infinity, color: const Color(0xFF07130E),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: const Text('🔐 end-to-end encrypted · relays hold only ciphertext',
                textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF4DD0A7), fontSize: 11.5, fontWeight: FontWeight.w600))),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : (_convos.isEmpty && _groups.isEmpty)
              ? const Center(child: Padding(padding: EdgeInsets.all(40),
                  child: Text('No messages yet.\nOpen someone’s profile and tap Message.',
                      textAlign: TextAlign.center, style: TextStyle(color: kDim, height: 1.5))))
              : RefreshIndicator(
                  color: kAccent, backgroundColor: kCard, onRefresh: _load,
                  child: ListView.separated(
                    // Groups first, then one-to-one. Both are conversations; the header is what
                    // stops a group reading as a person with an odd name.
                    itemCount: _groups.length + _convos.length,
                    separatorBuilder: (_, __) => Container(color: kLine, height: 1),
                    itemBuilder: (_, idx) {
                      if (idx < _groups.length) {
                        final g = _groups[idx];
                        return ListTile(
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    GroupChatScreen(group: g, handleOf: _handleOf)));
                            _load();
                          },
                          leading: CircleAvatar(
                            radius: 22,
                            backgroundColor: kCard,
                            child: const Icon(Icons.groups_outlined, color: kAccent, size: 22),
                          ),
                          title: Text(g.name.isEmpty ? 'Group' : g.name,
                              style: const TextStyle(
                                  color: kText, fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              '${g.members.length} members · ${g.msgs.length} messages',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: kDim, fontSize: 13)),
                          trailing: Text(timeAgo(g.newestTs),
                              style: const TextStyle(color: kDim, fontSize: 12)),
                        );
                      }
                      final i = idx - _groups.length;
                      final c = _convos[i];
                      final peer = '${c['peer']}';
                      final handle = widget.handleOf(peer);
                      final msgs = (c['messages'] as List?) ?? [];
                      // Skip control messages when picking what to preview. The THREAD hides them,
                      // but this list did not, so a conversation whose most recent event was a
                      // reaction or a read receipt advertised itself as
                      // `You: xchat:ctl/1 read {"u":1786897878}` — machine text, on the one screen
                      // you see before opening anything. The envelope's whole promise is that a
                      // client which meets one never shows it to a reader; that has to hold on every
                      // surface, not just the one it was written for.
                      final visible = msgs
                          .cast<Map<String, dynamic>>()
                          .where((m) => !hiddenInDm('${m['text']}'))
                          .toList();
                      final last = visible.isEmpty ? null : visible.last;
                      return ListTile(
                        onTap: () async {
                          await widget.onOpen(peer, handle);
                          _load();
                        },
                        leading: AuthorAvatar(account: peer, handle: handle, radius: 22),
                        title: AnimatedBuilder(
                          animation: ProfileCache.I,
                          // _handleOf, not the bare display name: when the profile has not loaded and
                          // the handle is the shared default 'you.xno', it appends the account
                          // discriminator so the row is distinguishable instead of reading like a
                          // conversation with yourself. Once the profile resolves both show the same
                          // real name ("Jiован").
                          builder: (_, __) => Text(_handleOf(peer),
                              style: const TextStyle(color: kText, fontWeight: FontWeight.w700)),
                        ),
                        subtitle: last == null ? null : Text(
                            '${last['outgoing'] == true ? 'You: ' : ''}${last['text']}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kDim, fontSize: 13.5)),
                        trailing: last == null ? null : Text(timeAgo((last['ts'] ?? 0) as int),
                            style: const TextStyle(color: kDim, fontSize: 12)),
                      );
                    },
                  ),
                ),
    );
  }
}

// one encrypted conversation: message bubbles + a composer. Send goes through the engine,
// which encrypts to the peer's published X25519 key before it ever touches a relay.
class DmChatScreen extends StatefulWidget {
  final String peer, handle, myAccount;
  const DmChatScreen({super.key, required this.peer, required this.handle, required this.myAccount});
  @override
  State<DmChatScreen> createState() => _DmChatScreenState();
}

class _DmChatScreenState extends State<DmChatScreen> {
  List<Map<String, dynamic>> _msgs = [];
  // Messages typed here but not yet echoed back by the relay. Shown immediately, greyed with a clock,
  // so sending doesn't feel like the message vanished for a second — the thing every chat app does.
  final List<Map<String, dynamic>> _pending = [];
  bool _loading = true, _sending = false, _emoji = false;
  String? _err;
  Map<String, dynamic>? _replyTo;     // the message being replied to, until it is sent or cancelled
  // In-thread search. Free now: Phase 1 keeps every message decrypted on the device, so finding one
  // is a string match over memory — no request, and nothing a relay could answer even if we asked it.
  bool _searching = false;
  String _query = '';
  final _searchCtl = TextEditingController();
  // Jump-to-original. A key per rendered message lets Scrollable.ensureVisible do the work with
  // variable-height bubbles, which an offset calculation cannot. ListView.builder only builds near
  // the viewport, so a target further away has no context yet — hence the coarse scroll first.
  final _scroll = ScrollController();
  final Map<String, GlobalKey> _msgKeys = {};
  String? _flashId;                 // briefly outlined after a jump, so the eye lands on it
  final _ctl = TextEditingController();
  Timer? _poll;
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
  String _peerPk = '';                // the peer's DM key, needed to decrypt attachments
  // Decrypted attachments, by cid. The thread re-polls every 5s and rebuilds on every keystroke, so
  // without this each image would be re-fetched and re-decrypted constantly — visible as photos that
  // blink out and reload while you type. `null` value = fetched and failed, so we stop retrying it.
  final Map<String, Uint8List?> _imgCache = {};
  final Set<String> _imgLoading = {};

  // Quote wire format. The reference to the original rides INSIDE the sealed plaintext as "> "
  // prefixed lines — never as a field on the envelope. A reply_to column would hand the relay the
  // shape of every conversation for free, and this app's whole claim is that relays hold ciphertext
  // and nothing else. It also degrades: someone on an older build sees a readable quoted block
  // rather than markup they can't parse, which matters while real people are running old installs.
  static const _quoteMax = 160;

  (String?, String) _splitQuote(String text) {
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length && lines[i].startsWith('>')) {
      i++;
    }
    // All quote and no body is NOT a reply. People type "> something" inline for emphasis on one
    // line — seen in this very thread — and parsing that as a quote renders an empty-bodied block
    // that looks broken. Fall back to plain text unless there is something the quote introduces.
    if (i == 0 || i == lines.length) return (null, text);
    final body = lines.skip(i).join('\n').trimLeft();
    if (body.isEmpty) return (null, text);
    // Accept "> x" and ">x" both: the space is a convention, not a guarantee, and other clients differ.
    return (lines.take(i).map((l) => l.startsWith('> ') ? l.substring(2) : l.substring(1)).join('\n'),
            body);
  }

  String _quoteLines(String original) {
    var s = original.replaceAll('\r', '');
    if (s.length > _quoteMax) s = '${s.substring(0, _quoteMax).trimRight()}…';
    return s.split('\n').map((l) => '> $l').join('\n');
  }

  // Who said the quoted thing. Resolved by looking it up in the thread rather than stored, because
  // storing it would mean trusting the sender's claim about who said what.
  String _quoteAuthor(String quote) {
    final needle = quote.endsWith('…') ? quote.substring(0, quote.length - 1) : quote;
    for (final m in [..._msgs, ..._pending].reversed) {
      if (_splitQuote('${m['text']}').$2.startsWith(needle)) {
        return m['outgoing'] == true ? 'You' : ProfileCache.I.displayName(widget.peer, widget.handle);
      }
    }
    return '';                       // quoted a message that is no longer loaded
  }

  @override
  void initState() {
    super.initState();
    _load();
    SettingsStore.get().then((s) { if (mounted) setState(() => _readReceiptsOn = s.readReceipts); });
    SharedPreferences.getInstance().then((p) {
      _sentReadUpTo = p.getInt(_readKey) ?? 0;                    // resume the high-water mark
      final del = p.getStringList(_delKey) ?? const [];          // resume locally-hidden messages
      final ed = p.getString(_editKey);                          // resume my own edits
      final once = p.getStringList(_onceKey) ?? const [];        // resume opened disappearing photos
      if (!mounted) return;
      setState(() {
        _deletedLocal.addAll(del);
        _consumedPhotos.addAll(once);
        if (ed != null && ed.isNotEmpty) {
          try {
            (jsonDecode(ed) as Map).forEach((k, v) => _localEdits['$k'] = '$v');
          } catch (_) {}
        }
      });
    });
    // A conversation that only loads once is a mailbox, not a chat: a reply landed on the relay and
    // you had to back out of the thread and re-open it to see it. Poll while the thread is on screen.
    // Push first, poll as the safety net. While a stream is live the poll drops to 30s, which is
    // what makes a silently-dead stream cost seconds rather than forever — see DmPush.
    DmPush.onNudge = () { if (mounted) _load(quiet: true); };
    final me = gWallet?.account;
    if (me != null) DmPush.start(me);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DmPush.live && DateTime.now().difference(_lastPoll).inSeconds < 30) return;
      _lastPoll = DateTime.now();
      _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Hand the nudge back to the feed screen, which owns it outside a conversation. Leaving this
    // pointing at a disposed State is a callback into a dead widget on the next message.
    DmPush.onNudge = null;
    _ctl.dispose(); _searchCtl.dispose(); _scroll.dispose();
    super.dispose();
  }

  /// Scroll to the message a quote came from, and flash it.
  ///
  /// Two passes on purpose. The list is lazy, so a message far from the viewport has no BuildContext
  /// and ensureVisible has nothing to aim at. Jump to a rough position first — which forces the
  /// target to build — then let ensureVisible land it exactly on the next frame.
  Future<void> _jumpTo(String id) async {
    final rowIndex = _rowIndexOf(id);
    if (rowIndex == null) return;
    final key = _msgKeys[id];
    if (key?.currentContext == null && _scroll.hasClients) {
      final total = _rows().length;
      if (total > 0) {
        final frac = 1 - (rowIndex / total);          // reverse: true, so index 0 is the bottom
        _scroll.jumpTo((_scroll.position.maxScrollExtent * frac)
            .clamp(0.0, _scroll.position.maxScrollExtent));
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(ctx,
          alignment: 0.3, duration: const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    setState(() => _flashId = id);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _flashId = null);
  }

  /// Where a message sits in the rendered rows, so the coarse scroll has something to aim at.
  int? _rowIndexOf(String id) {
    var i = 0;
    for (final m in [..._msgs, ..._pending]) {
      if (hiddenInDm('${m['text']}')) continue;
      if ('${m['id'] ?? ''}' == id) return i;
      i++;
    }
    return null;
  }

  Future<void> _load({bool quiet = false}) async {
    final convos = await Api.dmInbox();
    if (!mounted) return;
    final mine = convos.firstWhere((c) => c['peer'] == widget.peer, orElse: () => {});
    _peerPk = '${mine['peer_pk'] ?? ''}';
    final next = ((mine['messages'] as List?) ?? []).cast<Map<String, dynamic>>();
    // Retire each optimistic bubble once the real one comes back. Match on text + a loose timestamp
    // window: the relay stamps its own receipt time, so requiring equality would leave a permanent
    // duplicate on screen.
    final before = _pending.length;
    _pending.removeWhere((p) => next.any((m) =>
        m['outgoing'] == true && m['text'] == p['text'] &&
        (((m['ts'] as int?) ?? 0) - ((p['ts'] as int?) ?? 0)).abs() <= 120));
    // A quiet poll that changed nothing must not setState — otherwise every 5s it rebuilds the list
    // under the reader and fights a long-press selection.
    if (quiet && next.length == _msgs.length && _pending.length == before && !_loading) return;
    setState(() { _msgs = next; _loading = false; });
    _sendReadReceipt();   // no-op unless the high-water mark actually moved
  }

  Future<void> _send() async {
    final body = _ctl.text.trim();
    if (body.isEmpty || _sending) return;
    final q = _replyTo;
    // Quote the original's BODY, not its raw text: replying to a reply would otherwise nest the
    // old quote inside the new one and grow a staircase down the thread.
    final text = q == null ? body : '${_quoteLines(_splitQuote('${q['text']}').$2)}\n$body';
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    setState(() {
      _sending = true; _err = null; _emoji = false; _replyTo = null;
      _pending.add({'text': text, 'ts': ts, 'outgoing': true, 'pending': true});
      _ctl.clear();                       // clear NOW; the optimistic bubble is the receipt
    });
    final r = await Api.dmSend(widget.peer, text);
    if (!mounted) return;
    if (r != null && r['ok'] == true) {
      await _load();
      if (mounted) setState(() => _sending = false);
    } else {
      // Hand the text back instead of eating it — the composer was cleared optimistically, so a
      // failed send would otherwise destroy what was typed.
      setState(() {
        _sending = false;
        _pending.removeWhere((p) => p['ts'] == ts && p['text'] == text);
        _ctl.text = body;                 // the body back, not the quote markup
        _ctl.selection = TextSelection.collapsed(offset: body.length);
        _replyTo = q;                     // and put the reply target back too
        _err = (r?['error'] ?? 'send failed').toString();
      });
    }
  }

  // Pick a photo and send it. Same picker settings as a post (quality 88 / maxWidth 1600): a modern
  // phone photo is several MB raw, and a DM attachment gets sealed and base64'd on the way to a blob
  // store, so shipping the original would put tens of MB through a relay for one message.
  // Pick a disappearing photo, then choose how long it shows, then send.
  Future<void> _sendDisappearing() async {
    if (_sending) return;
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (x == null || !mounted) return;
    final secs = await _pickDuration();
    if (secs == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    _sendPickedImage(bytes, seconds: secs);
  }

  // The duration chooser for a disappearing photo.
  Future<int?> _pickDuration() {
    return showModalBottomSheet<int>(
      context: context, backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Align(alignment: Alignment.centerLeft,
                child: Text('How long can they view it?',
                    style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15))),
          ),
          for (final s in const [3, 5, 10, 30])
            ListTile(
              leading: const Icon(Icons.timer_outlined, color: kAccent),
              title: Text('$s seconds', style: const TextStyle(color: kText)),
              onTap: () => Navigator.pop(ctx, s),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('It shows on a countdown, then deletes itself. Screen capture is blocked '
                '(not camera-proof).', style: TextStyle(color: kDim, fontSize: 11.5)),
          ),
        ]),
      ),
    );
  }

  Future<void> _sendImage() async {
    if (_sending) return;
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    _sendPickedImage(bytes);
  }

  Future<void> _sendPickedImage(Uint8List bytes, {int? seconds}) async {
    final caption = _ctl.text.trim();     // whatever is already typed rides along as the caption
    setState(() {
      _sending = true; _err = null; _emoji = false;
      _ctl.clear();
    });
    final r = await Api.dmSendImage(widget.peer, bytes, caption, seconds: seconds);
    if (!mounted) return;
    if (r != null && r['ok'] == true) {
      await _load();
      if (mounted) setState(() => _sending = false);
    } else {
      setState(() {
        _sending = false;
        _ctl.text = caption;              // don't eat a caption the send failed to deliver
        _ctl.selection = TextSelection.collapsed(offset: caption.length);
        _err = (r?['error'] ?? 'could not send the image').toString();
      });
    }
  }

  bool _sameDay(int a, int b) {
    final x = DateTime.fromMillisecondsSinceEpoch(a * 1000);
    final y = DateTime.fromMillisecondsSinceEpoch(b * 1000);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  String _clock(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _dayLabel(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day)).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return days < 365 ? '${d.day} ${mo[d.month - 1]}' : '${d.day} ${mo[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        titleSpacing: 0,
        title: _searching
            ? TextField(
                controller: _searchCtl,
                autofocus: true,
                style: const TextStyle(color: kText, fontSize: 16),
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: const InputDecoration(
                    hintText: 'Search this conversation',
                    hintStyle: TextStyle(color: kDim), border: InputBorder.none),
              )
            : Row(children: [
                AuthorAvatar(account: widget.peer, handle: widget.handle, radius: 16),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  AnimatedBuilder(
                    animation: ProfileCache.I,
                    builder: (_, __) => Text(ProfileCache.I.displayName(widget.peer, widget.handle),
                        style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                  const Text('🔐 encrypted', style: TextStyle(color: Color(0xFF4DD0A7), fontSize: 11)),
                ]),
              ]),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search, color: kText),
            tooltip: _searching ? 'Close search' : 'Search this conversation',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) { _searchCtl.clear(); _query = ''; }
            }),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: kAccent))
              : _msgs.isEmpty
                  ? const Center(child: Text('No messages yet — say hi 🔐', style: TextStyle(color: kDim)))
                  // reverse: a chat should open on the NEWEST message. This list had no controller and
                  // no reverse, so every conversation opened at the oldest message and you had to
                  // scroll down to find what was just said. Reversed, index 0 is the bottom, so it
                  // lands on the latest and new messages appear where the eye already is — and it
                  // needs no post-frame scroll hack that fights the keyboard opening.
                  : Builder(builder: (_) {
                      final rows = _rows();
                      return ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.all(14),
                        itemCount: rows.length,
                        itemBuilder: (_, i) => rows[rows.length - 1 - i],
                      );
                    }),
        ),
        if (_err != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(_err!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12.5))),
        _composer(),
      ]),
    );
  }

  // Build the thread as rows (day chips + bubbles) rather than one bubble per message, so consecutive
  // messages from the same person read as a block the way they do in Messenger/WhatsApp instead of a
  // ladder of identical rounded boxes each restating the time.
  List<Widget> _rows() {
    // Control messages are ACTED on, never drawn. Suppressing them here — before grouping, day
    // chips or search — means a reaction can never open a day separator of its own or leave a gap
    // between two messages that belong together. Unknown types are suppressed too: see DmCtl.
    final edits = _edits();
    final del = _deletes();
    var all = <Map<String, dynamic>>[];
    for (final m in [..._msgs, ..._pending]) {
      if (hiddenInDm('${m['text']}')) continue;              // control messages are acted on, not drawn
      final id = '${m['id'] ?? ''}';
      final mine = m['outgoing'] == true;
      // "delete for everyone" (author-side matched) or a local "delete for me" removes the bubble.
      if (del[id] == mine || _deletedLocal.contains(id)) continue;
      // An edit replaces the text and marks it "edited". My own edits apply locally-first (immediate,
      // offline-safe); the peer's edits of their messages arrive as `edit` controls, author-side matched.
      final e = edits[id];
      final editedText = (mine ? _localEdits[id] : null) ?? ((e != null && e.out == mine) ? e.text : null);
      all.add(editedText != null ? {...m, 'text': editedText, 'edited': true} : m);
    }
    if (_query.isNotEmpty) {
      // Search the BODY, not the raw text: a hit inside the "> " quote of a reply would otherwise
      // match the message that quoted it as well as the original, which reads as a duplicate.
      final q = _query.toLowerCase();
      all = all.where((m) {
        final (_, rest) = _splitQuote('${m['text']}');
        final (_, _, body) = _splitImg(rest);
        return body.toLowerCase().contains(q);
      }).toList();
      if (all.isEmpty) {
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('No messages matching “$_query”',
                  style: const TextStyle(color: kDim, fontSize: 14)),
            ),
          )
        ];
      }
    }
    const groupWindow = 300;                    // 5 min: past that, a message starts a new block
    final reacts = _reactions();
    // The newest thing WE sent that they have read. Computed once here rather than per bubble.
    final peerRead = _peerReadUpTo();
    Map<String, dynamic>? readMark;
    if (peerRead > 0) {
      for (final m in all) {
        if (m['outgoing'] != true) continue;
        if (((m['ts'] ?? 0) as int) <= peerRead) readMark = m;
      }
    }
    final rows = <Widget>[];
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      final ts = (m['ts'] as int?) ?? 0;
      final prev = i > 0 ? all[i - 1] : null;
      final next = i + 1 < all.length ? all[i + 1] : null;
      final prevTs = (prev?['ts'] as int?) ?? 0;
      final nextTs = (next?['ts'] as int?) ?? 0;
      final newDay = prev == null || !_sameDay(prevTs, ts);
      if (newDay) rows.add(_dayChip(ts));
      final cont = !newDay && prev['outgoing'] == m['outgoing'] && (ts - prevTs).abs() < groupWindow;
      final endsBlock = next == null || next['outgoing'] != m['outgoing'] ||
          !_sameDay(ts, nextTs) || (nextTs - ts).abs() >= groupWindow;
      rows.add(_bubble(m, cont: cont, showTime: endsBlock, reacts: reacts['${m['id'] ?? ''}']));
      // "Read" goes under the LAST message they have acknowledged, not every one of them. A column
      // of ticks tells you nothing more than a single mark at the high-water line.
      if (readMark != null && identical(m, readMark)) {
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 1, right: 4, bottom: 2),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text('Read', style: TextStyle(color: kDim.withValues(alpha: 0.9), fontSize: 10.5)),
          ),
        ));
      }
    }
    return rows;
  }

  Widget _dayChip(int ts) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kLine)),
            child: Text(_dayLabel(ts),
                style: const TextStyle(color: kDim, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ),
      );

  // REACTIONS, folded out of the control messages already in the thread.
  //
  // One reaction per person per message, last-write-wins. That is Messenger's model rather than
  // Slack's, and it is chosen for the wire as much as the UI: a sender's latest `react` states their
  // CURRENT reaction, so removing one is sending an empty string. No separate remove op, no way for
  // an add and a remove to arrive out of order and leave a reaction nobody made.
  Map<String, Map<String, String>> _reactions() {
    final out = <String, Map<String, String>>{};      // targetId -> {reactor account: emoji}
    final all = [..._msgs]..sort((a, b) => ((a['ts'] ?? 0) as int).compareTo((b['ts'] ?? 0) as int));
    for (final m in all) {
      final c = DmCtl.parse('${m['text']}');
      if (c == null || c.type != 'react') continue;
      final target = '${c.data['m'] ?? ''}';
      final emoji = '${c.data['e'] ?? ''}';
      if (target.isEmpty) continue;
      // Attribute to the SENDER of the control message. A reaction cannot be forged onto someone
      // else because the only way it reaches us is sealed to our key by its author.
      final who = m['outgoing'] == true ? (widget.myAccount) : '${m['from']}';
      final map = out[target] ??= <String, String>{};
      if (emoji.isEmpty) { map.remove(who); } else { map[who] = emoji; }
    }
    // Local overlay so a tap is immediate rather than waiting for the round trip and the next poll.
    for (final e in _pendingReacts.entries) {
      final map = out[e.key] ??= <String, String>{};
      if (e.value.isEmpty) { map.remove(widget.myAccount); } else { map[widget.myAccount] = e.value; }
    }
    return out;
  }

  final Map<String, String> _pendingReacts = {};      // targetId -> emoji I just chose

  // Locally hidden messages ("delete for me") — persisted per conversation so they stay gone across
  // reopens. Distinct from a `delete` control message, which is "delete for everyone".
  final Set<String> _deletedLocal = {};
  // My edits of my OWN messages, applied locally-first and persisted: an edit is a change to MY copy
  // that I also broadcast to the peer, so it must show on my device the instant I make it and survive
  // even if the control message never reaches the peer (offline, or a peer with no reachable mailbox).
  // The `edit` control still fires so the peer's client updates too.
  final Map<String, String> _localEdits = {};
  String get _delKey => 'xchat_dmdel_${widget.peer}';
  String get _editKey => 'xchat_dmedit_${widget.peer}';
  void _persistDeleted() {
    SharedPreferences.getInstance().then((p) => p.setStringList(_delKey, _deletedLocal.toList()));
  }
  void _persistEdits() {
    SharedPreferences.getInstance().then((p) => p.setString(_editKey, jsonEncode(_localEdits)));
  }
  // View-once (disappearing) photos already opened on this device — persisted per conversation so a
  // disappearing photo stays gone across reopens/restarts; the decrypted bytes are dropped on open.
  final Set<String> _consumedPhotos = {};
  String get _onceKey => 'xchat_dmonce_${widget.peer}';
  void _consumePhoto(String id, String cid) {
    setState(() { _consumedPhotos.add(id); _imgCache.remove(cid); });
    SharedPreferences.getInstance().then((p) => p.setStringList(_onceKey, _consumedPhotos.toList()));
  }

  // EDITS + UNSENDS, folded from control messages exactly like reactions. A message can only be edited
  // or unsent by the side that AUTHORED it: an `edit`/`delete` control applies to a target only when
  // its sender is on the same side (outgoing) as that target. A message and its own control always
  // share a side on any given device (both flip together across devices), so `== m['outgoing']` is the
  // whole check — a peer cannot edit or unsend YOUR message, nor you theirs. The control rides the
  // sealed DM channel, so an edit's new text is as private as the original.
  Map<String, ({String text, bool out})> _edits() {
    final out = <String, ({String text, bool out})>{};
    final all = [..._msgs]..sort((a, b) => ((a['ts'] ?? 0) as int).compareTo((b['ts'] ?? 0) as int));
    for (final m in all) {
      final c = DmCtl.parse('${m['text']}');
      if (c == null || c.type != 'edit') continue;
      final t = '${c.data['m'] ?? ''}';
      if (t.isEmpty) continue;
      out[t] = (text: '${c.data['t'] ?? ''}', out: m['outgoing'] == true);   // last edit wins (ts-sorted)
    }
    return out;
  }

  Map<String, bool> _deletes() {
    final out = <String, bool>{};                       // targetId -> authored-by-outgoing
    for (final m in _msgs) {
      final c = DmCtl.parse('${m['text']}');
      if (c == null || c.type != 'delete') continue;
      final t = '${c.data['m'] ?? ''}';
      if (t.isNotEmpty) out[t] = m['outgoing'] == true;
    }
    return out;
  }

  // READ RECEIPTS — one per conversation, never one per message.
  //
  // The receipt says "I have read everything up to <ts>", so opening a thread with twenty unread
  // costs ONE control message instead of twenty. That is not just tidiness: a client older than the
  // envelope renders each control message as a raw line, so a receipt per message would flood the
  // other side's thread with machine text. Batching is what makes the feature safe to ship at all.
  //
  // It is sent only when the high-water mark ADVANCES, so re-opening a thread you have already read
  // sends nothing.
  // PERSISTED per conversation, not held on this screen. As a plain field it reset every time the
  // thread was closed and reopened, so each visit re-sent a receipt for messages already
  // acknowledged — measured: 16 sent, reopen, 17. Over a day of dipping in and out that is precisely
  // the accumulation batching exists to prevent, and every one of them is a raw line in an older
  // client's thread.
  int _sentReadUpTo = 0;
  String get _readKey => 'xchat_read_upto_${widget.peer}';
  bool _readReceiptsOn = true;   // loaded in initState; the DM screen has no Settings of its own

  /// How far the PEER says they have read. Only incoming receipts count — our own say nothing about
  /// them, and trusting an outgoing one would show "Read" the moment we opened our own thread.
  int _peerReadUpTo() {
    var t = 0;
    for (final m in _msgs) {
      if (m['outgoing'] == true) continue;
      final c = DmCtl.parse('${m['text']}');
      if (c == null || c.type != 'read') continue;
      final u = (c.data['u'] is int) ? c.data['u'] as int : int.tryParse('${c.data['u']}') ?? 0;
      if (u > t) t = u;
    }
    return t;
  }

  Future<void> _sendReadReceipt() async {
    if (!_readReceiptsOn) return;
    // Only ever acknowledge messages THEY sent; our own timestamps are not news to them.
    var newest = 0;
    for (final m in _msgs) {
      if (m['outgoing'] == true) continue;
      if (hiddenInDm('${m['text']}')) continue;   // do not acknowledge acknowledgements
      final ts = (m['ts'] ?? 0) as int;
      if (ts > newest) newest = ts;
    }
    if (newest == 0 || newest <= _sentReadUpTo) return;   // nothing new to report
    _sentReadUpTo = newest;
    final r = await Api.dmSend(widget.peer, DmCtl.encode('read', {'u': newest}));
    // Only remember it once it actually went. Recording a mark for a receipt that failed to send
    // would tell the peer nothing and stop us ever retrying.
    if (r != null && r['ok'] == true) {
      (await SharedPreferences.getInstance()).setInt(_readKey, newest);
    } else {
      _sentReadUpTo = 0;
    }
  }

  Future<void> _react(String targetId, String emoji) async {
    // Tapping the reaction you already have removes it — the empty string is how that travels.
    final mine = _reactions()[targetId]?[widget.myAccount] ?? '';
    final next = mine == emoji ? '' : emoji;
    setState(() => _pendingReacts[targetId] = next);
    await Api.dmSend(widget.peer, DmCtl.encode('react', {'m': targetId, 'e': next}));
    await _load();
    if (mounted) setState(() => _pendingReacts.remove(targetId));
  }

  /// The chips under a bubble. Grouped by emoji with a count, so three thumbs read as one 👍 3.
  Widget _reactionChips(Map<String, String> byWho, bool out) {
    final counts = <String, int>{};
    for (final e in byWho.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mine = byWho[widget.myAccount];
    return Padding(
      padding: EdgeInsets.only(top: 3, left: out ? 0 : 6, right: out ? 6 : 0, bottom: 2),
      child: Wrap(
        spacing: 4,
        alignment: out ? WrapAlignment.end : WrapAlignment.start,
        children: [
          for (final e in counts.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(11),
                // Your own reaction is outlined, so you can see at a glance whether the 👍 is yours.
                border: Border.all(color: e.key == mine ? kAccent : kLine),
              ),
              child: Text('${e.key}${e.value > 1 ? ' ${e.value}' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: kText)),
            ),
        ],
      ),
    );
  }

  /// Split an attachment marker off a message body → (cid, seconds, caption). `seconds` is non-null for
  /// a disappearing photo (its view duration). Runs AFTER the quote split, so a reply that carries a
  /// photo works: quote lines, then the marker, then the caption.
  (String?, int?, String) _splitImg(String body) {
    if (body.startsWith(Api.dmImgOnceTag)) {
      final rest = body.substring(Api.dmImgOnceTag.length);   // "<seconds>:<cid>" (+ optional "\n<caption>")
      final nl = rest.indexOf('\n');
      final head = (nl < 0 ? rest : rest.substring(0, nl)).trim();
      final colon = head.indexOf(':');
      if (colon <= 0) return (null, null, body);
      final secs = int.tryParse(head.substring(0, colon));
      final cid = head.substring(colon + 1).trim();
      if (secs == null || cid.isEmpty) return (null, null, body);
      return (cid, secs, nl < 0 ? '' : rest.substring(nl + 1).trimLeft());
    }
    if (!body.startsWith(Api.dmImgTag)) return (null, null, body);
    final nl = body.indexOf('\n');
    final cid = (nl < 0 ? body.substring(Api.dmImgTag.length) : body.substring(Api.dmImgTag.length, nl)).trim();
    if (cid.isEmpty) return (null, null, body);
    return (cid, null, nl < 0 ? '' : body.substring(nl + 1).trimLeft());
  }

  void _wantImage(String cid) {
    if (_imgCache.containsKey(cid) || _imgLoading.contains(cid) || _peerPk.isEmpty) return;
    _imgLoading.add(cid);
    Api.dmImage(cid, _peerPk).then((b) {
      if (!mounted) return;
      _imgLoading.remove(cid);
      setState(() => _imgCache[cid] = b);
    });
  }

  Widget _attachment(String cid, bool out) {
    _wantImage(cid);                       // kicks off exactly one fetch per cid
    final bytes = _imgCache[cid];
    const h = 190.0;
    Widget inner;
    if (!_imgCache.containsKey(cid)) {
      inner = const SizedBox(height: h, width: 190,
          child: Center(child: SizedBox(height: 22, width: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: kAccent))));
    } else if (bytes == null) {
      inner = SizedBox(
        height: h, width: 190,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.image_not_supported_outlined, color: out ? Colors.black54 : kDim, size: 26),
            const SizedBox(height: 5),
            // Say which of the two it is. A relay only keeps blobs for so long, and that is a very
            // different problem from a key mismatch.
            Text('image unavailable', style: TextStyle(fontSize: 11.5, color: out ? Colors.black54 : kDim)),
          ]),
        ),
      );
    } else {
      inner = GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PhotoScreen(bytes: bytes))),
        child: Image.memory(bytes, fit: BoxFit.cover, width: 250),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: inner),
    );
  }

  // A disappearing photo: a covered card the recipient taps to open ONCE, for `seconds` on a countdown,
  // with screen capture blocked. Opening deletes the local copy and marks it gone (persisted). The
  // sender sees the same card and can look once too. The bytes are never rendered inline, so a passing
  // glance at the thread can't reveal it. Client-enforced — the timed viewer states it isn't camera-proof.
  Widget _oncePhoto(Map<String, dynamic> m, String cid, int seconds, bool out) {
    final id = '${m['id'] ?? ''}';
    final consumed = _consumedPhotos.contains(id);
    final fg = out ? Colors.black.withValues(alpha: 0.78) : kText;
    final sub = out ? Colors.black.withValues(alpha: 0.5) : kDim;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: GestureDetector(
        onTap: consumed
            ? null
            : () async {
                final bytes = _imgCache[cid] ?? await Api.dmImage(cid, _peerPk);
                if (!mounted) return;
                if (bytes == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('photo unavailable — it may have already expired')));
                  _consumePhoto(id, cid);                 // gone either way
                  return;
                }
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DisappearingPhotoScreen(bytes: bytes, seconds: seconds)));
                _consumePhoto(id, cid);                   // opened once → delete + mark gone
              },
        child: Container(
          width: 210,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            color: out ? Colors.black.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: out ? Colors.black.withValues(alpha: 0.15) : kLine),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(consumed ? Icons.timer_off_outlined : Icons.timer_outlined,
                size: 22,
                color: consumed ? sub : (out ? Colors.black.withValues(alpha: 0.7) : kAccent)),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                children: [
                  Text(consumed ? 'Photo opened' : 'Disappearing photo · ${seconds}s',
                      style: TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 1),
                  Text(consumed
                          ? 'gone — it showed for ${seconds}s'
                          : (out ? 'they can open it once' : 'tap to view for ${seconds}s'),
                      style: TextStyle(color: sub, fontSize: 11)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // Long-press is how both WhatsApp and Messenger expose per-message actions, so it is where people
  // already look for them.
  void _msgMenu(Map<String, dynamic> m) {
    final (quote, rest) = _splitQuote('${m['text']}');
    final body = rest;
    final (imgCid, _, _) = _splitImg(rest);
    final out = m['outgoing'] == true;
    final id = '${m['id'] ?? ''}';
    // Edit only your own plain-text messages: a reply carries a quote and a photo carries a marker,
    // and reconstructing either from an edit is not worth it for v1 — those keep just delete.
    final canEdit = out && id.isNotEmpty && imgCid == null && quote == null;
    showModalBottomSheet(
      context: context, backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // A quick row first: reacting is the most common thing you want from this menu, and making
          // it one tap rather than a submenu is the difference between using it and not.
          if ('${m['id'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final e in const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () { Navigator.pop(ctx); _react('${m['id']}', e); },
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ]),
            ),
          ListTile(
            leading: const Icon(Icons.reply, color: kAccent),
            title: const Text('Reply', style: TextStyle(color: kText)),
            onTap: () {
              Navigator.pop(ctx);
              setState(() { _replyTo = m; _emoji = false; });
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined, color: kDim),
            title: const Text('Copy', style: TextStyle(color: kText)),
            onTap: () {
              Clipboard.setData(ClipboardData(text: body));
              Navigator.pop(ctx);
            },
          ),
          if (canEdit)
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: kAccent),
              title: const Text('Edit', style: TextStyle(color: kText)),
              onTap: () { Navigator.pop(ctx); _edit(m); },
            ),
          if (out && id.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFEF6C9B)),
              title: const Text('Delete for everyone', style: TextStyle(color: Color(0xFFEF6C9B))),
              onTap: () { Navigator.pop(ctx); _deleteEveryone(m); },
            ),
          if (id.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined, color: kDim),
              title: const Text('Delete for me', style: TextStyle(color: kText)),
              onTap: () { Navigator.pop(ctx); _deleteForMe(id); },
            ),
        ]),
      ),
    );
  }

  Future<void> _edit(Map<String, dynamic> m) async {
    final id = '${m['id'] ?? ''}';
    if (id.isEmpty) return;
    final current = _splitImg(_splitQuote('${m['text']}').$2).$3;   // the plain body
    final ctl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Edit message', style: TextStyle(color: kText, fontSize: 16)),
        content: TextField(
          controller: ctl, autofocus: true, maxLines: null,
          style: const TextStyle(color: kText),
          decoration: const InputDecoration(hintText: 'Message', hintStyle: TextStyle(color: kDim)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: kDim))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save', style: TextStyle(color: kAccent))),
        ],
      ),
    );
    if (ok != true) return;
    final next = ctl.text.trim();
    if (next.isEmpty || next == current) return;
    // Apply on MY device at once and persist it — my edit of my message shouldn't wait on, or be lost
    // to, a failed round trip. Then fire the sealed `edit` control so the peer's client updates too
    // (best-effort, like a reaction); both sides match the target by its ciphertext-derived id.
    setState(() => _localEdits[id] = next);
    _persistEdits();
    await Api.dmSend(widget.peer, DmCtl.encode('edit', {'m': id, 't': next}));
    await _load();
  }

  Future<void> _deleteEveryone(Map<String, dynamic> m) async {
    final id = '${m['id'] ?? ''}';
    if (id.isEmpty) return;
    // Hide it here at once — the control message travels to the peer, but our own thread shouldn't
    // wait on the round trip to reflect the unsend. HONEST LIMIT: this asks the peer's client to drop
    // it; a screenshot or an older build that predates the type keeps their copy. The UI says so.
    setState(() => _deletedLocal.add(id));
    _persistDeleted();
    await Api.dmSend(widget.peer, DmCtl.encode('delete', {'m': id}));
    await _load();
  }

  void _deleteForMe(String id) {
    if (id.isEmpty) return;
    setState(() => _deletedLocal.add(id));
    _persistDeleted();
  }

  /// Message text with the search term marked. Plain Text when nothing is being searched, so the
  /// common case pays nothing for a feature that is off.
  Widget _highlighted(String body, bool out) {
    final base = TextStyle(color: out ? Colors.black : kText, fontSize: 15, height: 1.3);
    if (_query.isEmpty) return Text(body, style: base);
    final q = _query.toLowerCase();
    final lower = body.toLowerCase();
    final spans = <TextSpan>[];
    var i = 0;
    while (true) {
      final at = lower.indexOf(q, i);
      if (at < 0) { spans.add(TextSpan(text: body.substring(i))); break; }
      if (at > i) spans.add(TextSpan(text: body.substring(i, at)));
      spans.add(TextSpan(
        text: body.substring(at, at + q.length),
        style: TextStyle(
            backgroundColor: out ? Colors.black.withValues(alpha: 0.22) : kAccent.withValues(alpha: 0.38),
            fontWeight: FontWeight.w800),
      ));
      i = at + q.length;
    }
    return RichText(text: TextSpan(style: base, children: spans));
  }

  /// The id of the message a quote came from, matched by its text — the same lookup _quoteAuthor
  /// does. Quotes carry the words, not an id, because they must stay readable on a client that knows
  /// nothing about quoting.
  String? _quoteTarget(String quote) {
    final needle = quote.endsWith('…') ? quote.substring(0, quote.length - 1) : quote;
    for (final m in [..._msgs, ..._pending].reversed) {
      if (_splitQuote('${m['text']}').$2.startsWith(needle)) return '${m['id'] ?? ''}';
    }
    return null;
  }

  Widget _quoteBlock(String quote, bool out) {
    final who = _quoteAuthor(quote);
    final target = _quoteTarget(quote);
    // A left accent bar via Row, not BoxDecoration's border: a non-uniform Border with a
    // borderRadius throws at paint time.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: (target == null || target.isEmpty) ? null : () => _jumpTo(target),
        child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Container(width: 3, color: out ? Colors.black54 : kAccent),
            Flexible(
              child: Container(
                color: out ? Colors.black.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.05),
                padding: const EdgeInsets.fromLTRB(7, 5, 7, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                  children: [
                    if (who.isNotEmpty)
                      Text(who, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: out ? Colors.black87 : kAccent)),
                    Text(quote, maxLines: 3, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, height: 1.25,
                            color: out ? Colors.black.withValues(alpha: 0.72) : kDim)),
                  ],
                ),
              ),
            ),
          ]),
        ),
        ),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m,
      {bool cont = false, bool showTime = true, Map<String, String>? reacts}) {
    final out = m['outgoing'] == true;
    final pending = m['pending'] == true;
    final (quote, rest) = _splitQuote('${m['text']}');
    final (imgCid, imgSecs, body) = _splitImg(rest);
    const r16 = Radius.circular(16), r5 = Radius.circular(5);
    return Column(
      crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: pending ? 0.6 : 1,             // "on its way" without a second widget
        key: _msgKeys.putIfAbsent('${m['id'] ?? ''}', () => GlobalKey()),
        child: _SwipeToReply(
          fromRight: out,
          onReply: () => setState(() { _replyTo = m; _emoji = false; }),
          child: GestureDetector(
          onLongPress: () => _msgMenu(m),
          child: Container(
            // Tight inside a block, loose between blocks — the spacing IS the grouping cue.
            margin: EdgeInsets.only(top: cont ? 2 : 8),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            decoration: BoxDecoration(
              color: out ? kAccent : kCard,
              // A jump lands the message on screen; the outline says WHICH one, which scrolling alone
              // does not when several bubbles look alike.
              border: _flashId != null && _flashId == '${m['id'] ?? ''}'
                  ? Border.all(color: const Color(0xFF4DD0A7), width: 2)
                  : null,
              // Only the last bubble of a block keeps its tail; the ones above square off against it.
              borderRadius: BorderRadius.only(
                topLeft: out ? r16 : (cont ? r5 : r16),
                topRight: out ? (cont ? r5 : r16) : r16,
                bottomLeft: out ? r16 : (showTime ? r5 : r16),
                bottomRight: out ? (showTime ? r5 : r16) : r16),
            ),
          // The timestamp was always in the message map — sorted on, even — but never shown, so a DM
          // thread read as one undated block. Clock time, not "16m": relative ages are for a feed you
          // skim, while a conversation you re-read needs to say when something was actually said.
          child: Column(
            crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (quote != null) _quoteBlock(quote, out),
              if (imgCid != null)
                (imgSecs != null ? _oncePhoto(m, imgCid, imgSecs, out) : _attachment(imgCid, out)),
              // A photo sent with no caption should not leave an empty text line under it.
              if (body.isNotEmpty || imgCid == null)
                _highlighted(body, out),
              // Tell the reader the words changed — an edit that rewrote a message silently would be a
              // trust problem, not a feature. WhatsApp/Signal both surface it the same way.
              if (m['edited'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('edited',
                      style: TextStyle(
                          color: out ? Colors.black.withValues(alpha: 0.45) : kDim,
                          fontSize: 9.5, fontStyle: FontStyle.italic)),
                ),
              if (showTime) ...[
                const SizedBox(height: 3),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (pending)
                    Padding(padding: const EdgeInsets.only(right: 3),
                        child: Icon(Icons.schedule, size: 11,
                            color: out ? Colors.black.withValues(alpha: 0.55) : kDim)),
                  Text(_clock((m['ts'] as int?) ?? 0),
                      style: TextStyle(
                          color: out ? Colors.black.withValues(alpha: 0.55) : kDim, fontSize: 10.5)),
                ]),
              ],
            ],
          ),
          ),
          ),
        ),
      ),
        ),
        // Chips sit UNDER the bubble, not inside it: a reaction is a separate act by someone else,
        // and putting it in the bubble would make it look like part of the message.
        if (reacts != null && reacts.isNotEmpty) _reactionChips(reacts, out),
      ],
    );
  }

  // A picker that ships WITH the app, rather than relying on the device keyboard's emoji key. That
  // reliance is what "I can't use emoji in the DM" actually was: on a keyboard where the emoji key is
  // absent or swapped for voice input there is no way in at all, and the fix can't live in our code.
  static const _emojis = [
    '😀','😃','😄','😁','😆','😅','🤣','😂','🙂','🙃','😉','😊','😍','🥰','😘','😗',
    '🤗','🤔','🤨','😐','😑','🙄','😏','😴','🤤','😪','😵','🤯','🥳','😎','🤓','🧐',
    '😕','🙁','😢','😭','😤','😠','😡','🤬','😱','😳','🥵','🥶','😬','🤝','🙏','👍',
    '👎','👌','✌️','🤞','💪','👏','🙌','👀','🔥','✨','⭐','💯','✅','❌','⚡','🎉',
    '❤️','🧡','💛','💚','💙','💜','🖤','💔','💸','🪙','🚀','🛠️','📡','🌐','🔐','👋',
  ];

  void _insertEmoji(String e) {
    final t = _ctl.text;
    final sel = _ctl.selection;
    final start = sel.start < 0 ? t.length : sel.start;
    final end = sel.end < 0 ? t.length : sel.end;
    _ctl.text = t.replaceRange(start, end, e);
    _ctl.selection = TextSelection.collapsed(offset: start + e.length);
    setState(() {});                    // the send button enables off text length
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kLine))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // What you are about to quote, shown before you send rather than after — otherwise the only
          // way to check you picked the right message is to send and look.
          if (_replyTo != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
              child: Row(children: [
                Container(width: 3, height: 32, color: kAccent),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _replyTo!['outgoing'] == true
                            ? 'Replying to yourself'
                            : 'Replying to ${ProfileCache.I.displayName(widget.peer, widget.handle)}',
                        style: const TextStyle(
                            color: kAccent, fontSize: 11.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(_splitQuote('${_replyTo!['text']}').$2,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kDim, fontSize: 12.5)),
                    ],
                  ),
                ),
                IconButton(
                    icon: const Icon(Icons.close, color: kDim, size: 20),
                    onPressed: () => setState(() => _replyTo = null)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                onPressed: () {
                  // Close the system keyboard when opening ours, or the two stack and bury the thread.
                  if (!_emoji) FocusScope.of(context).unfocus();
                  setState(() => _emoji = !_emoji);
                },
                icon: Icon(_emoji ? Icons.keyboard : Icons.emoji_emotions_outlined,
                    color: _emoji ? kAccent : kDim),
                tooltip: _emoji ? 'Keyboard' : 'Emoji',
              ),
              IconButton(
                onPressed: _sending ? null : () => _sendImage(),
                icon: Icon(Icons.image_outlined, color: _sending ? kLine : kDim),
                tooltip: 'Send a photo',
              ),
              // A distinct button + symbol for a DISAPPEARING photo: pick a photo, choose how long it
              // shows, and it self-deletes after the recipient's countdown (with screen capture blocked).
              IconButton(
                onPressed: _sending ? null : _sendDisappearing,
                icon: Icon(Icons.timer_outlined, color: _sending ? kLine : kAccent),
                tooltip: 'Disappearing photo',
              ),
              Expanded(
                child: TextField(
                  controller: _ctl,
                  style: const TextStyle(color: kText, fontSize: 15),
                  minLines: 1, maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onTap: () { if (_emoji) setState(() => _emoji = false); },
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Encrypted message…',
                    hintStyle: TextStyle(color: kDim), border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10)),
                ),
              ),
              _sending
                  ? const Padding(padding: EdgeInsets.all(10),
                      child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
                  : IconButton(
                      onPressed: _send,
                      tooltip: 'Send message',
                      icon: const Icon(Icons.send, color: kAccent)),
            ]),
          ),
          if (_emoji)
            SizedBox(
              height: 210,
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: _emojis.length,
                itemBuilder: (_, i) => InkWell(
                  onTap: () => _insertEmoji(_emojis[i]),
                  borderRadius: BorderRadius.circular(8),
                  child: Center(child: Text(_emojis[i], style: const TextStyle(fontSize: 24))),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// full profile page: banner + avatar + display name + @handle + bio + counts + Posts/Media tabs
class ProfileScreen extends StatefulWidget {
  final String account, handle;
  final bool isMe, isFollowing;
  final List<Post> allPosts;
  final Widget Function(Post) cardBuilder;
  final VoidCallback? onEdit;
  final VoidCallback? onToggleFollow;
  final VoidCallback? onMessage;
  const ProfileScreen({
    super.key,
    required this.account,
    required this.handle,
    required this.isMe,
    required this.allPosts,
    required this.cardBuilder,
    this.isFollowing = false,
    this.onEdit,
    this.onToggleFollow,
    this.onMessage,
  });
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  int _tab = 0; // 0 posts, 1 media

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await Api.profileGet(widget.account);
    if (p != null) ProfileCache.I.put(widget.account, p);
    if (mounted) setState(() { _p = p; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    // rebuild whenever the cache changes (e.g. after Edit profile saves)
    return AnimatedBuilder(animation: ProfileCache.I, builder: (_, __) => _body());
  }

  Widget _body() {
    final cached = ProfileCache.I.of(widget.account);
    // prefer the live cached record for name/avatar/banner/bio; keep counts from either
    final src = {...?_p, ...?cached};
    final display = ((src['display'] ?? '') as String).trim();
    final name = display.isEmpty ? widget.handle : display;
    final bio = ((src['bio'] ?? '') as String).trim();
    final avatar = (src['avatar'] ?? '') as String;
    final banner = (src['banner'] ?? '') as String;
    final following = (src['following'] ?? 0) as int;
    final followers = (src['followers'] ?? 0) as int;
    final pinnedId = '${src['pinned'] ?? ''}';
    final mine = widget.allPosts.where((p) => p.account == widget.account).toList();
    // The pinned post floats to the top of the Posts tab (X-style). Only a post that is actually theirs
    // can pin — a forged id that matches nothing just doesn't show.
    if (pinnedId.isNotEmpty) {
      final idx = mine.indexWhere((p) => p.id == pinnedId);
      if (idx > 0) mine.insert(0, mine.removeAt(idx));
    }
    final media = mine.where((p) => p.media != null || p.kind == 'movie').toList();
    final shown = _tab == 0 ? mine : media;

    return Scaffold(
      backgroundColor: kBg,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : CustomScrollView(slivers: [
              SliverAppBar(
                backgroundColor: kBg,
                pinned: true,
                expandedHeight: 148,
                iconTheme: const IconThemeData(color: kText),
                title: Text(name, style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                flexibleSpace: FlexibleSpaceBar(
                  background: banner.isNotEmpty
                      ? MediaImage(cid: banner, fit: BoxFit.cover)
                      : Container(decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [Color(0xFF10233A), Color(0xFF0A1512)],
                              begin: Alignment.topLeft, end: Alignment.bottomRight))),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(height: 14),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(color: kBg, shape: BoxShape.circle),
                          child: avatar.startsWith('live:')
                              ? LiveAvatar(style: avatar.substring(5), radius: 36)
                              : avatar.isNotEmpty
                                  ? ClipOval(child: SizedBox(width: 72, height: 72, child: MediaImage(cid: avatar, fit: BoxFit.cover)))
                                  : CircleAvatar(radius: 36, backgroundColor: avatarColor(widget.handle),
                                      child: Text(widget.handle.substring(0, 1).toUpperCase(),
                                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 26))),
                        ),
                        const Spacer(),
                        if (widget.isMe)
                          OutlinedButton(
                              onPressed: widget.onEdit,
                              style: OutlinedButton.styleFrom(foregroundColor: kText, side: const BorderSide(color: kLine),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                              child: const Text('Edit profile', style: TextStyle(fontWeight: FontWeight.w700)))
                        else ...[
                          OutlinedButton(
                            onPressed: widget.onMessage,
                            style: OutlinedButton.styleFrom(foregroundColor: kText, side: const BorderSide(color: kLine),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                padding: const EdgeInsets.symmetric(horizontal: 16)),
                            child: const Icon(Icons.mail_outline, size: 18),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                              onPressed: widget.onToggleFollow,
                              style: FilledButton.styleFrom(
                                  backgroundColor: widget.isFollowing ? kCard : kText,
                                  foregroundColor: widget.isFollowing ? kText : Colors.black,
                                  side: widget.isFollowing ? const BorderSide(color: kLine) : null,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                              child: Text(widget.isFollowing ? 'Following' : 'Follow', style: const TextStyle(fontWeight: FontWeight.w800))),
                        ],
                    ]),
                    const SizedBox(height: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(name, style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 20)),
                          const SizedBox(width: 6),
                          const Icon(Icons.verified, size: 17, color: kAccent),
                        ]),
                        Text('@${widget.handle} ·${acctTag(widget.account)}',
                            style: const TextStyle(color: kDim, fontSize: 14)),
                        if (bio.isNotEmpty) Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(bio, style: const TextStyle(color: kText, fontSize: 14.5, height: 1.4)),
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          _count(following, 'Following', () => _openFollowList('following')),
                          const SizedBox(width: 20),
                          _count(followers, 'Followers', () => _openFollowList('followers')),
                          const SizedBox(width: 20),
                          _count(mine.length, 'Posts'),
                        ]),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      _tabBtn('Posts', 0),
                      _tabBtn('Media', 1),
                    ]),
                  ]),
                ),
              ),
              if (shown.isEmpty)
                const SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('Nothing here yet', style: TextStyle(color: kDim))))),
              SliverList(delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final p = shown[i];
                  final isPinned = _tab == 0 && pinnedId.isNotEmpty && p.id == pinnedId;
                  return Column(children: [
                    Container(color: kLine, height: 1),
                    if (isPinned)
                      const Padding(
                        padding: EdgeInsets.only(left: 16, top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.push_pin, size: 13, color: kDim),
                            SizedBox(width: 5),
                            Text('Pinned',
                                style: TextStyle(color: kDim, fontSize: 12, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    widget.cardBuilder(p),
                  ]);
                },
                childCount: shown.length,
              )),
            ]),
    );
  }

  Widget _count(int n, String label, [VoidCallback? onTap]) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$n', style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(color: kDim, fontSize: 14)),
          ]),
        ),
      );

  void _openFollowList(String mode) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FollowListScreen(account: widget.account, mode: mode)));

  Widget _tabBtn(String label, int i) {
    final on = _tab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: on ? kAccent : Colors.transparent, width: 2.5))),
          child: Center(child: Text(label,
              style: TextStyle(color: on ? kText : kDim, fontWeight: on ? FontWeight.w800 : FontWeight.w600, fontSize: 15))),
        ),
      ),
    );
  }
}

// CHANNELS tab: a directory of publication identities. Each row shows the channel, its online-reader
// count (followers with a live head — same heartbeat as the green dot) and total readers. Tapping opens
// the channel's profile, where its posts + articles live (they're kept out of the personal feed).
class ChannelsScreen extends StatefulWidget {
  final void Function(String account, String handle) onOpenChannel;
  const ChannelsScreen({super.key, required this.onOpenChannel});
  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  List<Map<String, dynamic>> _chs = [];
  bool _loading = true;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final c = await Api.channels();
    c.sort((a, b) {                                            // most readers first, then most online
      final fa = (a['followers'] as num?)?.toInt() ?? 0, fb = (b['followers'] as num?)?.toInt() ?? 0;
      if (fa != fb) return fb - fa;
      return ((b['online'] as num?)?.toInt() ?? 0) - ((a['online'] as num?)?.toInt() ?? 0);
    });
    if (mounted) setState(() { _chs = c; _loading = false; });
  }
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
        child: const Text('Channels', style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 20)),
      ),
      Expanded(
        child: RefreshIndicator(
          color: kAccent, backgroundColor: kCard, onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: kAccent))
              : _chs.isEmpty
                  ? ListView(children: const [
                      Padding(padding: EdgeInsets.fromLTRB(28, 70, 28, 0), child: Text(
                          'No channels yet.\n\nChannels are publications you can follow — their posts and articles show here, not in your feed.',
                          textAlign: TextAlign.center, style: TextStyle(color: kDim, fontSize: 13.5, height: 1.6)))])
                  : ListView.separated(
                      itemCount: _chs.length,
                      separatorBuilder: (_, __) => const Divider(color: kLine, height: 1),
                      itemBuilder: (_, i) {
                        final c = _chs[i];
                        final acc = '${c['account']}';
                        final name = '${c['display'] ?? ''}';
                        final bio = '${c['bio'] ?? ''}';
                        final online = (c['online'] as num?)?.toInt() ?? 0;
                        final readers = (c['followers'] as num?)?.toInt() ?? 0;
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          onTap: () => widget.onOpenChannel(acc, name.isEmpty ? 'channel' : name),
                          leading: AuthorAvatar(account: acc, handle: name.isEmpty ? '?' : name, radius: 24),
                          title: Text(name.isEmpty ? 'channel' : name,
                              style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
                          subtitle: bio.isEmpty ? null : Text(bio, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: kDim, fontSize: 12.5)),
                          trailing: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(width: 7, height: 7, decoration: BoxDecoration(
                                  color: online > 0 ? const Color(0xFF3BD671) : kDim, shape: BoxShape.circle)),
                              const SizedBox(width: 5),
                              Text('$online online', style: TextStyle(
                                  color: online > 0 ? const Color(0xFF3BD671) : kDim, fontSize: 12, fontWeight: FontWeight.w700)),
                            ]),
                            const SizedBox(height: 3),
                            Text('$readers reader${readers == 1 ? '' : 's'}',
                                style: const TextStyle(color: kDim, fontSize: 11)),
                          ]),
                        );
                      },
                    ),
        ),
      ),
    ]);
  }
}

class DiscoverScreen extends StatefulWidget {
  final List<Post> posts;
  final List<Map<String, String>> authors;
  final Set<String> follows, liked, reposted;
  final Map<String, dynamic> engage;
  final void Function(String account) onToggleFollow;
  final String? initialQuery;      // set when arriving from a tapped mention or hashtag
  final String myAccount;          // exclude self from "who to follow"
  final double Function(String account) pendingOf;
  final int Function(String postId) commentCountOf;
  final void Function(Post) onTipPost, onLikePost, onRepostPost, onReportPost, onCommentPost;
  final void Function(String account, String handle) onOpenProfile;
  const DiscoverScreen(
      {super.key,
      this.initialQuery,
      this.myAccount = '',
      required this.posts,
      required this.authors,
      required this.follows,
      required this.engage,
      required this.liked,
      required this.reposted,
      required this.onToggleFollow,
      required this.pendingOf,
      required this.commentCountOf,
      required this.onTipPost,
      required this.onLikePost,
      required this.onRepostPost,
      required this.onReportPost,
      required this.onCommentPost,
      required this.onOpenProfile,
      required this.cardBuilder});
  final Widget Function(Post) cardBuilder;
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _c = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    // Arriving from a tapped #tag or @handle: land with the search already run, rather than on an
    // empty box the reader has to retype into.
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) { _q = q; _c.text = q; }
  }

  @override
  void didUpdateWidget(DiscoverScreen old) {
    super.didUpdateWidget(old);
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty && q != old.initialQuery) {
      setState(() { _q = q; _c.text = q; });
    }
  }

  double _authorXno(String account) {
    double s = 0;
    for (final p in widget.posts) {
      if (p.account == account) s += ((widget.engage[p.id]?['tips_xno'] ?? 0) as num).toDouble();
    }
    return s;
  }

  Widget _card(Post p) => widget.cardBuilder(p); // reuse the parent's fully-wired card (quote/thread/etc)

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final people = widget.authors
        .where((a) => q.isEmpty || a['handle']!.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => _authorXno(b['account']!).compareTo(_authorXno(a['account']!))); // rank by XNO earned
    final posts = q.isEmpty
        ? <Post>[]
        : widget.posts
            .where((p) =>
                p.text.toLowerCase().contains(q) ||
                p.handle.toLowerCase().contains(q) ||
                (p.title ?? '').toLowerCase().contains(q))
            .toList();
    final trending = q.isEmpty ? _trending() : const <MapEntry<String, int>>[];
    final whoToFollow = q.isEmpty
        ? people
            .where((a) => !widget.follows.contains(a['account']) && a['account'] != widget.myAccount)
            .take(8)
            .toList()
        : const <Map<String, String>>[];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          controller: _c,
          onChanged: (v) => setState(() => _q = v),
          style: const TextStyle(color: kText),
          decoration: InputDecoration(
            hintText: 'Search people and posts',
            hintStyle: const TextStyle(color: kDim),
            prefixIcon: const Icon(Icons.search, color: kDim),
            filled: true,
            fillColor: kCard,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          ),
        ),
      ),
      Expanded(
        child: ListView(children: [
          if (q.isEmpty) ...[
            if (trending.isNotEmpty) ...[
              _section('Trending'),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in trending)
                    ActionChip(
                      backgroundColor: kCard,
                      side: const BorderSide(color: kLine),
                      label: Text('#${t.key}  ${t.value}',
                          style: const TextStyle(color: kAccent, fontWeight: FontWeight.w600, fontSize: 13)),
                      onPressed: () { _c.text = '#${t.key}'; setState(() => _q = '#${t.key}'); },
                    ),
                ]),
              ),
            ],
            if (whoToFollow.isNotEmpty) ...[
              _section('Who to follow'),
              ...whoToFollow.map((a) => _person(a['account']!, a['handle']!)),
            ],
            _section('Top earners'),
            ...people.map((a) => _person(a['account']!, a['handle']!)),
          ] else ...[
            _section('People (${people.length})'),
            ...people.map((a) => _person(a['account']!, a['handle']!)),
            _section('Posts (${posts.length})'),
            ...posts.map((p) => _card(p)),
            if (posts.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('no posts match', style: TextStyle(color: kDim))),
          ],
          const SizedBox(height: 20),
        ]),
      ),
    ]);
  }

  // Top hashtags across the loaded feed — a lightweight, client-side "Trending" (no backend needed).
  List<MapEntry<String, int>> _trending() {
    final counts = <String, int>{};
    final re = RegExp(r'#([A-Za-z0-9_]{2,30})');
    for (final p in widget.posts) {
      for (final m in re.allMatches(p.text)) {
        final tag = m.group(1)!.toLowerCase();
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final out = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return out.take(10).toList();
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(t,
            style: const TextStyle(color: kDim, fontWeight: FontWeight.w700, fontSize: 13)),
      );

  Widget _person(String account, String handle) {
    final following = widget.follows.contains(account);
    return InkWell(
      onTap: () => widget.onOpenProfile(account, handle),
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        AuthorAvatar(account: account, handle: handle, radius: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedBuilder(
              animation: ProfileCache.I,
              builder: (_, __) => Text(ProfileCache.I.displayName(account, handle),
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w700)),
            ),
            Builder(builder: (_) {
              final earned = _authorXno(account);
              return earned > 0
                  ? Text('◈ ${earned.toStringAsFixed(2)} XNO earned',
                      style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 12, fontWeight: FontWeight.w600))
                  : Text('${account.substring(0, 14)}…',
                      style: const TextStyle(color: kDim, fontSize: 11, fontFamily: 'monospace'));
            }),
          ]),
        ),
        OutlinedButton(
          onPressed: () => widget.onToggleFollow(account),
          style: OutlinedButton.styleFrom(
            backgroundColor: following ? kBg : kText,
            foregroundColor: following ? kText : Colors.black,
            side: BorderSide(color: following ? kLine : kText),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: Text(following ? 'Following' : 'Follow',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ]),
    ));
  }
}

class _LedgerFooter extends StatelessWidget {
  const _LedgerFooter();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
      alignment: Alignment.center,
      child: const Text(
          '✍ every post above is a signed off-chain event — 0 Nano blocks.\nthe ledger is only touched to settle tips.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kDim, fontSize: 12, height: 1.5)),
    );
  }
}

// ---- post card ----
class PostCard extends StatefulWidget {
  final Post post;
  final PostMod? softFlag;
  final double pending;
  final Map<String, dynamic> engage;
  final bool liked, reposted;
  final int commentCount;
  final VoidCallback onTip, onLike, onRepost, onReport, onComment;
  final VoidCallback? onOpenProfile, onQuote, onOpenThread, onMute, onBlock, onBookmark, onPin, onDelete, onEdit, onReply, onPinProfile;
  /// Tapping an @handle or a #tag inside the body. The card cannot resolve either itself — a handle
  /// maps to an account only in the feed's view of the network — so it reports and lets the caller act.
  final void Function(String handle)? onTapHandle;
  final void Function(String tag)? onTapTag;
  final bool muted, blocked, bookmarked;
  final Post? quoted; // resolved quoted post (for a quote-post), rendered inline
  final bool inThread; // part of an author thread → show a thread affordance
  final int replyCount;       // number of reply-posts to this post (X-style reply counter on the bubble)
  final String replyingToHandle; // if this post is itself a reply, the handle it replies to ('' if none/unknown)
  final bool expanded;        // start with full post text shown (the focused post at the top of a thread)
  final String repostedBy; // handle of the resharer who spread this to you (X-style header)
  const PostCard(
      {super.key,
      required this.post,
      this.softFlag,
      this.pending = 0,
      this.engage = const {},
      this.liked = false,
      this.reposted = false,
      this.commentCount = 0,
      required this.onTip,
      this.onLike = _noop,
      this.onRepost = _noop,
      this.onReport = _noop,
      this.onComment = _noop,
      this.onOpenProfile,
      this.onQuote,
      this.onOpenThread,
      this.onTapHandle,
      this.onTapTag,
      this.onMute,
      this.onBlock,
      this.onBookmark,
      this.onPin,
      this.onDelete,
      this.onEdit,
      this.onPinProfile,
      this.muted = false,
      this.blocked = false,
      this.bookmarked = false,
      this.quoted,
      this.inThread = false,
      this.onReply,
      this.replyCount = 0,
      this.replyingToHandle = '',
      this.expanded = false,
      this.repostedBy = ''});
  static void _noop() {}
  @override
  State<PostCard> createState() => _PostCardState();
}

/// A held-open connection to the node that says "there is something for you", so a DM lands when it
/// is sent rather than when we next get round to asking.
///
/// The polling it replaces was 5s inside a thread and 12s for the badge, and that interval IS the
/// product — a reply that can take twelve seconds to appear reads as a mailbox, not a conversation.
///
/// THE STREAM CARRIES A NUDGE, NEVER CONTENT. The ciphertext still arrives by /api/dm_inbox, so
/// there is exactly one decryption path and the store and gossip-overlap logic are untouched. A bug
/// in here can delay a message; it cannot corrupt or leak one.
///
/// Polling is NOT removed, only slowed. A node that is older than this endpoint, a proxy that
/// buffers the stream to death, a network that drops it silently — all of them end with a client
/// that believes it has push and receives nothing. The slow poll is what makes those failures cost
/// seconds instead of forever.
class DmPush {
  static http.Client? _client;
  static StreamSubscription<String>? _sub;
  static String _account = '';
  static int _fails = 0;
  static Timer? _retry;
  static bool _wanted = false;

  /// True while a stream is actually established — the callers that slow their polling down check
  /// this, so believing it wrongly is the one thing that would make delivery worse than before.
  static bool live = false;

  /// Called on every nudge. The receiver decides what to fetch; this class never touches messages.
  static void Function()? onNudge;

  static void start(String account) {
    if (account.isEmpty) return;
    if (_wanted && _account == account && (live || _retry != null)) return;
    _account = account;
    _wanted = true;
    _connect();
  }

  static void stop() {
    _wanted = false;
    live = false;
    _retry?.cancel();
    _retry = null;
    _sub?.cancel();
    _sub = null;
    _client?.close();     // closes the socket, which is what actually ends the request on the node
    _client = null;
  }

  static Future<void> _connect() async {
    if (!_wanted) return;
    _retry?.cancel();
    _retry = null;
    _sub?.cancel();
    _client?.close();
    final c = http.Client();
    _client = c;
    try {
      final req = http.Request('GET', Uri.parse('$kBase/api/dm_events?account=$_account'));
      req.headers['Accept'] = 'text/event-stream';
      final resp = await c.send(req).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        // 503 is the node shedding load and 404 is a node too old to know the endpoint. Neither is
        // worth retrying hard, and neither is an error the reader should ever see: polling covers it.
        _fail();
        return;
      }
      _fails = 0;
      live = true;
      _sub = resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Only the event name is acted on. A payload is deliberately not parsed for anything but
        // its presence — whatever the node says, the client re-fetches through the normal path.
        if (line.startsWith('event: dm')) onNudge?.call();
      }, onDone: _fail, onError: (_) => _fail(), cancelOnError: true);
    } catch (_) {
      _fail();
    }
  }

  static void _fail() {
    live = false;
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
    if (!_wanted || _retry != null) return;
    // Backoff, because the failure that matters is a node that is down or overloaded, and a tight
    // reconnect loop is how a client turns that into a worse outage — the same lesson the relay's
    // tunnel watchdog learned against Cloudflare's rate limiter.
    _fails = (_fails + 1).clamp(1, 6);
    final wait = Duration(seconds: [2, 4, 8, 15, 30, 60][_fails - 1]);
    _retry = Timer(wait, () {
      _retry = null;
      _connect();
    });
  }
}

/// Hand a URL to the system browser. EXTERNAL, deliberately: an in-app webview would put our chrome
/// around somebody else's page, which is exactly the shape a phishing page wants, and it would carry
/// our cookies and our process into content we did not write.
Future<void> openLink(String url) async {
  final u = Uri.tryParse(url);
  // Belt and braces. scanBody's grammar cannot emit anything but http/https, so this can only fire if
  // a future caller passes a URL from somewhere else — and `javascript:`/`intent:` handed to the OS
  // launcher is the one mistake here worth making structurally impossible.
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return;
  try {
    await launchUrl(u, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No browser installed, or the OS refused. Nothing useful to say to the reader.
  }
}

/// The card under a post that shows what its link actually leads to.
///
/// The NODE fetches the page, not this phone. If each reader unfurled for themselves, every host
/// anyone linked to would collect the IP and the read-time of everyone who scrolled past — anyone
/// could post a link and harvest a list of who read their post. The full argument is at the top of
/// backend/xc_unfurl.py.
///
/// FEED ONLY. A DM is end-to-end encrypted, so asking the node to preview a link inside one would
/// hand the node a URL out of a conversation it is specifically not able to read. Nothing wires this
/// into the DM path, and nothing should.
///
/// No image yet, deliberately. An og:image is a URL on the linked site, so painting it here would
/// reintroduce the very IP leak the node-side fetch exists to avoid — the picture has to be proxied
/// through the node before it can be shown, which is its own piece of work.
class LinkPreview extends StatefulWidget {
  const LinkPreview({super.key, required this.url});
  final String url;

  // Process-wide, because the same link appears in a post, in its thread view and again after a
  // refresh, and each of those is a fresh widget. Null means "asked, nothing to show" — cached just
  // as firmly as a hit, so a bad link is not re-requested on every scroll past it.
  static final Map<String, Map<String, dynamic>?> _cache = {};
  static final Map<String, Future<Map<String, dynamic>?>> _inflight = {};

  static Future<Map<String, dynamic>?> lookup(String url) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    // Single-flight: a feed page can hold the same link several times and they all build at once.
    return _inflight.putIfAbsent(url, () async {
      try {
        final r = await http
            .get(Uri.parse('$kBase/api/unfurl?url=${Uri.encodeQueryComponent(url)}'))
            .timeout(const Duration(seconds: 12));
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        // `busy` is the node shedding load, not a verdict on the link — don't cache it as one.
        if (d['retry'] == true) return null;
        final ok = d['ok'] == true && '${d['title'] ?? ''}'.isNotEmpty;
        _cache[url] = ok ? d : null;
        return _cache[url];
      } catch (_) {
        return null;                      // offline or slow: no card, and try again next build
      } finally {
        _inflight.remove(url);
      }
    });
  }

  @override
  State<LinkPreview> createState() => _LinkPreviewState();
}

class _LinkPreviewState extends State<LinkPreview> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LinkPreview old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final d = await LinkPreview.lookup(widget.url);
    if (mounted) setState(() => _d = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    // Nothing while it loads and nothing when it fails. A placeholder that later vanishes reflows the
    // whole feed under the reader's thumb, and a post with no card looks exactly like it did before
    // previews existed — which is the correct fallback.
    if (d == null) return const SizedBox.shrink();
    final title = '${d['title'] ?? ''}';
    final desc = '${d['desc'] ?? ''}';
    final site = '${d['site'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        button: true,
        link: true,
        // Read as one thing. Left to its own devices this is three loose text nodes inside a tappable
        // box, so it announces as an unexplained fragment, then a headline, then a sentence.
        label: 'Link${site.isEmpty ? '' : ' to $site'}: $title'
            '${desc.isEmpty ? '' : '. $desc'}',
        child: ExcludeSemantics(
        child: InkWell(
        onTap: () => openLink(widget.url),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            border: Border.all(color: kLine),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (site.isNotEmpty)
              Text(site.toLowerCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kDim, fontSize: 12)),
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: kText, fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.25)),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kDim, fontSize: 13, height: 1.25)),
            ],
          ]),
        ),
      ),
        ),
      ),
    );
  }
}

class _PostCardState extends State<PostCard> {
  // TapGestureRecognizers in a TextSpan are NOT owned by the span: they leak unless disposed. Held
  // here and cleared on every rebuild, which is the whole reason this lives in a StatefulWidget.
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  /// Post body with links, mentions and tags marked and tappable. Plain text when none appears, so the
  /// common post pays nothing.
  Widget _richBody(String text, TextStyle base) {
    final tokens = scanBody(text);
    if (!tokens.any((t) => t.kind != BodyKind.text)) return Text(text, style: base, maxLines: null);
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final spans = <TextSpan>[];
    for (final t in tokens) {
      if (t.kind == BodyKind.text) {
        spans.add(TextSpan(text: t.text));
        continue;
      }
      final rec = TapGestureRecognizer()
        ..onTap = () {
          switch (t.kind) {
            case BodyKind.link:
              openLink(t.value);
            case BodyKind.mention:
              widget.onTapHandle?.call(t.value);
            case BodyKind.tag:
              widget.onTapTag?.call(t.value);
            case BodyKind.text:
              break;
          }
        };
      _taps.add(rec);
      spans.add(TextSpan(
        // The text shown is the text WRITTEN. A link never displays one destination and opens
        // another — the reader's only defence against a hostile post is that the URL is the URL.
        text: t.text,
        style: const TextStyle(color: kAccent, fontWeight: FontWeight.w600),
        recognizer: rec,
      ));
    }
    return RichText(text: TextSpan(style: base, children: spans));
  }

  late bool _expanded = widget.expanded;   // start expanded (full text) for the focused post in a thread
  // Local optimistic like state so the thumb-up responds INSTANTLY on tap — even inside a pushed route
  // (the Thread/conversation screen) that doesn't rebuild when the parent's like set changes. Without
  // this, liking a comment/reply in the conversation gave no visible feedback and read as "not working".
  late bool _likedNow = widget.liked;
  @override
  void didUpdateWidget(PostCard old) {
    super.didUpdateWidget(old);
    if (widget.liked != old.liked) _likedNow = widget.liked;   // reflect external/authoritative changes
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final e = widget.engage;
    final longText = p.text.length > 220;
    return Container(
      color: kBg,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.repostedBy.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 34, bottom: 4),
          child: Row(children: [
            const Icon(Icons.repeat, size: 14, color: kDim),
            const SizedBox(width: 6),
            Text('${widget.repostedBy} reposted', style: const TextStyle(color: kDim, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: widget.onOpenProfile,
          child: AuthorAvatar(account: p.account, handle: p.handle, radius: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: GestureDetector(
                  onTap: widget.onOpenProfile,
                  child: AnimatedBuilder(
                    animation: ProfileCache.I,
                    builder: (_, __) => Text(ProfileCache.I.displayName(p.account, p.handle),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kText, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.verified, size: 15, color: kAccent),
              const SizedBox(width: 5),
              Text('·${acctTag(p.account)}',   // account discriminator: distinguishes same-handle accounts
                  style: const TextStyle(color: kDim, fontSize: 11.5, fontFamily: 'monospace')),
              const SizedBox(width: 6),
              Text('· ${timeAgo(p.ts)}', style: const TextStyle(color: kDim, fontSize: 13)),
              if (p.edited > 0)
                const Padding(
                  padding: EdgeInsets.only(left: 5),
                  child: Text('· edited',
                      style: TextStyle(color: kDim, fontSize: 11.5, fontStyle: FontStyle.italic)),
                ),
              const Spacer(),
              if (widget.softFlag != null && widget.softFlag!.flaggers.isNotEmpty) ...[
                _SoftFlag(mod: widget.softFlag!),
                const SizedBox(width: 6),
              ],
              if (p.kind != 'post') _KindBadge(kind: p.kind),
              Semantics(
                button: true,
                label: 'More actions for this post',
                child: ExcludeSemantics(
                  child: InkWell(
                    onTap: () => _menu(context),
                    child: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.more_horiz, size: 18, color: kDim)),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 3),
            // X-style reply context: "Replying to @handle" when this post threads under another
            if (p.replyTo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: GestureDetector(
                  onTap: widget.onOpenThread,
                  child: Text(
                      widget.replyingToHandle.isNotEmpty
                          ? 'Replying to @${widget.replyingToHandle}'
                          : 'Replying to a post',
                      style: const TextStyle(color: kDim, fontSize: 13)),
                ),
              ),
            if (p.kind == 'article' && p.media != null && p.media!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 170),
                    child: SizedBox(
                width: double.infinity,
                child: MediaImage(
                    cid: p.media!, fit: BoxFit.cover, label: 'Header image of an article by ${p.handle}')),
                  ),
                ),
              ),
            if (p.kind == 'article' && p.title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(p.title!,
                    style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 16, height: 1.3)),
              ),
            // tap the post body → open the full conversation (the entire post + all replies), X-style
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpenThread,
              child: (longText && !_expanded)
                  // Collapsed: plain Text, because maxLines+ellipsis belongs to Text and a truncated
                  // tappable span offers links whose end the reader cannot see.
                  ? Text(p.text,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kText, fontSize: 15, height: 1.35))
                  : _richBody(p.text,
                      const TextStyle(color: kText, fontSize: 15, height: 1.35)),
            ),
            // "Show more" EXPANDS the text in place. It used to open the thread instead, on the reasoning
            // that an inline expand would fight the open-thread tap on the body. It doesn't — the body
            // still opens the thread, and this is a separate target. What the old behaviour actually did
            // was strand you: inside a thread, a long REPLY is not the focused post, so it stayed
            // truncated and its "Show more" pushed ANOTHER thread view of the same conversation, showing
            // the same truncated reply. There was no way to read a long reply at all.
            if (longText && !_expanded)
              GestureDetector(
                onTap: () => setState(() => _expanded = true),
                child: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Show more',
                      style: TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            // A card for the first link, when the post has nothing else to show. Skipped when the
            // post already carries its own media — two rectangles competing under one sentence, and
            // the author's photo is the one they chose. Skipped while collapsed too: the card would
            // preview a link the reader cannot yet see in the truncated text.
            if (p.media == null && !(longText && !_expanded))
              Builder(builder: (_) {
                final link = firstLink(p.text);
                return link == null ? const SizedBox.shrink() : LinkPreview(url: link);
              }),
            // photo / GIF attachment (Image.memory animates GIFs)
            if (p.kind == 'photo' && p.media != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PhotoScreen(cid: p.media!))),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 380),
                      child: SizedBox(
                          width: double.infinity,
                          child: MediaImage(
                              cid: p.media!,
                              fit: BoxFit.cover,
                              label: 'Photo in a post by ${p.handle}')),
                    ),
                  ),
                ),
              ),
            if (p.kind == 'movie' && p.media != null) _MoviePreview(post: p),
            // poll
            if (p.poll != null && p.poll!.isNotEmpty)
              PollView(pollId: p.id, options: p.poll!),
            // embedded quoted post (quote-post)
            if (widget.quoted != null)
              QuotedCard(post: widget.quoted!, onTap: widget.onOpenThread),
            if (p.quote != null && widget.quoted == null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(border: Border.all(color: kLine), borderRadius: BorderRadius.circular(12)),
                child: const Text('quoted post unavailable', style: TextStyle(color: kDim, fontSize: 13)),
              ),
            // (the "Show this thread" link was removed — tapping the post already opens its conversation
            // + comments, so the separate affordance was redundant.)
            const SizedBox(height: 8),
            _Actions(
              reposts: (e['reposts'] ?? 0) as int,
              replies: widget.replyCount,
              tipsXno: ((e['tips_xno'] ?? 0) as num).toDouble(),
              liked: _likedNow,
              // optimistic count so the number moves too: base ± the pending local toggle
              likes: ((e['likes'] ?? 0) as int) + (_likedNow == widget.liked ? 0 : (_likedNow ? 1 : -1)),
              reposted: widget.reposted,
              pending: widget.pending,
              views: (e['views'] ?? 0) as int,
              onReply: widget.onReply,
              onLike: () { setState(() => _likedNow = !_likedNow); widget.onLike(); },
              onRepost: widget.onRepost,
              onQuote: widget.onQuote,
              onTip: widget.onTip,
            ),
          ]),
        ),
      ]),
      ]),
    );
  }

  void _menu(BuildContext context) {
    final h = widget.post.handle;
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Comments live on as a lightweight "quiet reply" tier alongside the X-style reply-posts —
          // reachable here from the overflow so the primary bubble stays the reply action.
          ListTile(
            leading: const Icon(Icons.mode_comment_outlined, color: kText),
            title: Text(widget.commentCount > 0 ? 'Comments (${widget.commentCount})' : 'Comments',
                style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
            subtitle: const Text('quiet replies attached under this post',
                style: TextStyle(color: kDim, fontSize: 11)),
            onTap: () { Navigator.pop(context); widget.onComment(); },
          ),
          if (widget.onBookmark != null)
            ListTile(
              leading: Icon(widget.bookmarked ? Icons.bookmark : Icons.bookmark_border, color: kAccent),
              title: Text(widget.bookmarked ? 'Remove bookmark' : 'Bookmark',
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('save privately to read later — never published',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onBookmark!(); },
            ),
          ListTile(
            leading: const Icon(Icons.ios_share, color: kText),
            title: const Text('Share', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
            subtitle: const Text('send this post out via the system share sheet',
                style: TextStyle(color: kDim, fontSize: 11)),
            onTap: () {
              Navigator.pop(context);
              final p = widget.post;
              Share.share('@${p.handle}: ${p.text}\n\nvia ӾChat');
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined, color: kText),
            title: const Text('Copy text', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.post.text));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  backgroundColor: kCard, content: Text('copied')));
            },
          ),
          if (widget.onMute != null)
            ListTile(
              leading: Icon(widget.muted ? Icons.volume_up_outlined : Icons.volume_off_outlined, color: kText),
              title: Text(widget.muted ? 'Unmute @$h' : 'Mute @$h',
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: Text(widget.muted ? 'show their posts again' : 'hide their posts from your feed, silently',
                  style: const TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onMute!(); },
            ),
          if (widget.onBlock != null)
            ListTile(
              leading: Icon(widget.blocked ? Icons.block : Icons.block_outlined, color: const Color(0xFFEF6C9B)),
              title: Text(widget.blocked ? 'Unblock @$h' : 'Block @$h',
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: Text(widget.blocked
                  ? 'let their posts and DMs reach you again'
                  : 'hide them, unfollow, and drop their DMs (your view only)',
                  style: const TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onBlock!(); },
            ),
          if (widget.onPin != null)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined, color: kAccent),
              title: const Text('Pin content', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('pay a little XNO so the relays keep this alive — pay-to-pin',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onPin!(); },
            ),
          if (widget.onPinProfile != null)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined, color: kAccent),
              title: const Text('Pin to profile', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('float this post to the top of your profile',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onPinProfile!(); },
            ),
          if (widget.onEdit != null)
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: kAccent),
              title: const Text('Edit post', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('rewrite the text and republish — shows an “edited” mark',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onEdit!(); },
            ),
          if (widget.onDelete != null)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFEF6C9B)),
              title: const Text('Delete post', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('republish your thread without it — it drops from the relays',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onDelete!(); },
            ),
          if (widget.onDelete == null)                       // don't report your own post
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: Color(0xFFEF6C9B)),
              title: const Text('Report', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('a trust-scoped flag for moderation — not a downvote, and reversible',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                widget.onReport();
              },
            ),
        ]),
      ),
    );
  }
}

// small amber hint: flagged by a labeler, but below the viewer's threshold
class _SoftFlag extends StatelessWidget {
  final PostMod mod;
  const _SoftFlag({required this.mod});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: const Color(0x33E0B64D),
          borderRadius: BorderRadius.circular(6)),
      child: Text('⚠ ${mod.verdict} ${(mod.frac * 100).round()}%',
          style: const TextStyle(
              color: Color(0xFFE0B64D),
              fontSize: 10,
              fontWeight: FontWeight.w700)),
    );
  }
}

// a post hidden by the viewer's chosen moderation — collapsed, never deleted.
class HiddenPostTile extends StatelessWidget {
  final Post post;
  final PostMod mod;
  final VoidCallback onShow;
  const HiddenPostTile(
      {super.key, required this.post, required this.mod, required this.onShow});
  @override
  Widget build(BuildContext context) {
    final names = mod.flaggers.map((l) => l.name).join(' + ');
    return Container(
      color: kBg,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.visibility_off_outlined, color: kDim, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Post from @${post.handle} hidden',
                style: const TextStyle(
                    color: kText, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 3),
            Text(
                'labeled “${mod.verdict}” by $names · ${(mod.frac * 100).round()}% of reputation',
                style: const TextStyle(color: kDim, fontSize: 12, height: 1.35)),
            if (mod.reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(mod.reason,
                    style: const TextStyle(
                        color: kDim, fontSize: 11, height: 1.3)),
              ),
            const SizedBox(height: 8),
            InkWell(
              onTap: onShow,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    border: Border.all(color: kLine),
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('Show anyway',
                    style: TextStyle(
                        color: kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final String kind;
  const _KindBadge({required this.kind});
  @override
  Widget build(BuildContext context) {
    final label = kind == 'article'
        ? 'ARTICLE'
        : kind == 'movie'
            ? 'MOVIE'
            : kind.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          border: Border.all(color: kLine),
          borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: const TextStyle(
              color: kDim,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: .5)),
    );
  }
}

// A content-addressed image fetched via the engine (IPFS or relay cache). Content-addressed means
// the CID *is* the bytes, so bytes can be cached forever by CID. This is stateful + per-CID cached
// on purpose: a plain FutureBuilder re-fetches on every rebuild, and in a recycling ListView it would
// show a PREVIOUS slot's image (gaplessPlayback keeps stale bytes) while the new one loads — so images
// "jump" between posts. Here, bytes are keyed to a CID and a stale fetch result is dropped if the
// widget was recycled to a different CID, so a slot only ever shows its own image.
class MediaImage extends StatefulWidget {
  final String cid;
  final BoxFit fit;

  /// What a screen reader says instead of the picture.
  ///
  /// This is a ROLE, not alt text: "a photo in a post by alice" tells you something is there and
  /// whose it is, which is what an unlabelled image fails to do — but it does not describe the
  /// image, and nothing here can. Real alt text has to be written by the author, which means a field
  /// in the composer and a field on the wire. Neither exists yet; see docs/SPEED-AND-GAPS.md.
  final String label;
  const MediaImage({super.key, required this.cid, this.fit = BoxFit.cover, this.label = 'Image'});
  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  // CID -> bytes, shared app-wide. Bounded by BYTES and evicted LEAST-RECENTLY-USED.
  //
  // It used to be a flat 48 entries evicted in insertion order, and every avatar in the feed takes a
  // slot as well as every photo. Once the feed held more images than that, scrolling evicted the ones
  // above you, scrolling back re-fetched them over the network, and they visibly blinked — worse than
  // it sounds, because FIFO can evict an image that is on screen right now while keeping one you
  // scrolled past. A count cap is also the wrong unit: 48 avatars and 48 photos are wildly different
  // amounts of memory. Bound the bytes, keep what is actually being looked at.
  static final Map<String, Uint8List> _cache = {};
  static int _cacheBytes = 0;
  static const int _cacheMaxBytes = 32 * 1024 * 1024;

  static Uint8List? _cacheGet(String cid) {
    final v = _cache.remove(cid);
    if (v != null) _cache[cid] = v;                  // re-insert = most recently used
    return v;
  }

  static void _cachePut(String cid, Uint8List data) {
    final old = _cache.remove(cid);
    if (old != null) _cacheBytes -= old.length;
    _cache[cid] = data;
    _cacheBytes += data.length;
    while (_cacheBytes > _cacheMaxBytes && _cache.isNotEmpty) {
      final k = _cache.keys.first;                   // oldest touched
      _cacheBytes -= (_cache.remove(k)?.length ?? 0);
    }
  }
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() { super.initState(); _resolve(); }

  @override
  void didUpdateWidget(MediaImage old) {
    super.didUpdateWidget(old);
    if (old.cid != widget.cid) { _bytes = null; _loading = false; _resolve(); }  // recycled for another image
  }

  Future<void> _resolve() async {
    final cid = widget.cid;
    final hit = _cacheGet(cid);
    // A cache hit must not flash a spinner: setting _loading=true below and clearing it on the next
    // frame is exactly the blink this is meant to avoid. Paint the bytes we already have, now.
    if (hit != null) { setState(() { _bytes = hit; _loading = false; }); return; }
    setState(() => _loading = true);
    final data = await Api.media(cid);
    if (!mounted || cid != widget.cid) return;   // widget moved to a different CID → drop this result
    if (data != null) _cachePut(cid, data);
    setState(() { _bytes = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Semantics(
        image: true,
        label: widget.label,
        child: Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true),
      );
    }
    // loading → spinner (reads as loading, not broken); resolved-but-null → a plain dark tile
    return Semantics(
      image: true,
      // Loading and failed are different facts and must not both read as silence — an unannounced
      // empty tile is indistinguishable from no image at all.
      label: _loading ? 'Loading ${widget.label}' : '${widget.label} — could not be loaded',
      child: Container(
        color: kCard,
        child: _loading
            ? const Center(
                child: SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kDim)))
            : null,
      ),
    );
  }
}

class _MoviePreview extends StatelessWidget {
  final Post post;
  const _MoviePreview({required this.post});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GestureDetector(
        onTap: post.media == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => VideoScreen(cid: post.media!))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(alignment: Alignment.center, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: post.thumb != null
                ? MediaImage(cid: post.thumb!, label: 'Video thumbnail, post by ${post.handle}')
                : Container(color: kCard),
          ),
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 34),
          ),
          if (post.dur != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(5)),
                child: Text(post.dur!,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
        ]),
      ),
      ),
    );
  }
}

// full-screen video playback (plays the movie by CID via the IPFS gateway)
// Full-screen photo with pinch-zoom. Photos in the feed had no tap handler at all, so a picture
// could only ever be seen at feed size — no way in to read small text in a screenshot, for instance.
// Deliberately no tap-to-dismiss: it fights InteractiveViewer's own pan/scale gestures. Back, or the
// close button, both work.
// Wallet transaction history. A nano_ address tells a human nothing, so each row leads with the
// HANDLE when this device has seen that account post, and always shows the address underneath —
// the pairing is the point: you recognise the name, and can still verify the account it maps to.
class WalletHistoryScreen extends StatefulWidget {
  const WalletHistoryScreen({super.key, this.handles = const {}});
  final Map<String, String> handles;      // account -> handle, from whatever the feed has seen

  @override
  State<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends State<WalletHistoryScreen> {
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await Api.history();
    if (mounted) setState(() => _rows = h);
  }

  String _short(String a) => a.length > 22 ? '${a.substring(0, 13)}…${a.substring(a.length - 6)}' : a;

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        title: const Text('Transactions', style: TextStyle(color: kText, fontWeight: FontWeight.w800)),
      ),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : rows.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Text('No transactions yet.\nTips and payments will show up here.',
                        textAlign: TextAlign.center, style: TextStyle(color: kDim, fontSize: 14, height: 1.5)),
                  ),
                )
              : RefreshIndicator(
                  color: kAccent,
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: kLine),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final incoming = '${r['type']}' == 'receive';
                      final acct = '${r['account'] ?? ''}';
                      final xno = (double.tryParse('${r['amount'] ?? 0}') ?? 0) / 1e30;
                      final ts = (r['ts'] as int?) ?? 0;
                      // Resolve the counterparty's NAME even when they aren't in the current feed. The
                      // `handles` map only covers accounts this device has actually seen post, so a
                      // creator you tipped whose post has since scrolled off — and split-leg recipients
                      // (the relay, a reposter) that never appear in the feed at all — used to render as
                      // a bare nano_ address. ProfileCache.I.ensure() fetches the account's signed
                      // profile on demand and, being a ChangeNotifier, rebuilds this row when the name
                      // lands. Feed-seen handles stay the instant fallback so known names show with no
                      // round-trip.
                      return AnimatedBuilder(
                        animation: ProfileCache.I,
                        builder: (_, __) {
                          if (acct.isNotEmpty) ProfileCache.I.ensure(acct);
                          final name = ProfileCache.I.displayName(acct, widget.handles[acct] ?? '').trim();
                          final hasName = name.isNotEmpty;
                          return ListTile(
                            leading: Icon(incoming ? Icons.south_west : Icons.north_east,
                                color: incoming ? const Color(0xFF4DD0A7) : kDim, size: 20),
                            title: Text(hasName ? '@$name' : _short(acct),
                                style: const TextStyle(color: kText, fontSize: 14.5, fontWeight: FontWeight.w700)),
                            // Keep the address AND the time visible when a name is present — the
                            // name↔address pairing is the whole point (recognise the name, still verify
                            // the account it maps to), and the timestamp shouldn't vanish just because
                            // the name resolved.
                            subtitle: Text(
                                hasName
                                    ? (ts > 0 ? '${_short(acct)}  ·  ${timeAgo(ts)}' : _short(acct))
                                    : (ts > 0 ? timeAgo(ts) : ''),
                                style: const TextStyle(color: kDim, fontSize: 11.5, fontFamily: 'monospace')),
                            trailing: Text('${incoming ? '+' : '−'}${xno.toStringAsFixed(5)}',
                                style: TextStyle(
                                    color: incoming ? const Color(0xFF4DD0A7) : kText,
                                    fontSize: 14, fontWeight: FontWeight.w800)),
                          );
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

// A tappable Following / Followers list for a profile. Following comes from the account's own signed
// follow record; Followers is the reverse edge scanned across relays. Each row resolves its name via
// ProfileCache and opens that profile on tap.
class FollowListScreen extends StatefulWidget {
  const FollowListScreen({super.key, required this.account, required this.mode});
  final String account;
  final String mode; // 'following' | 'followers'
  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  List<String>? _accts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = widget.mode == 'followers'
        ? await Api.followersGet(widget.account)
        : await Api.followsGet(widget.account);
    if (mounted) setState(() => _accts = a);
  }

  @override
  Widget build(BuildContext context) {
    final accts = _accts;
    final followers = widget.mode == 'followers';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        title: Text(followers ? 'Followers' : 'Following',
            style: const TextStyle(color: kText, fontWeight: FontWeight.w800)),
      ),
      body: accts == null
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : accts.isEmpty
              ? Center(
                  child: Text(followers ? 'No followers yet' : 'Not following anyone yet',
                      style: const TextStyle(color: kDim, fontSize: 14)))
              : ListView.separated(
                  itemCount: accts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: kLine),
                  itemBuilder: (_, i) {
                    final acc = accts[i];
                    return AnimatedBuilder(
                      animation: ProfileCache.I,
                      builder: (_, __) {
                        ProfileCache.I.ensure(acc);
                        final name = ProfileCache.I.displayName(acc, '').trim();
                        final label = name.isNotEmpty
                            ? name
                            : (acc.length > 16 ? '${acc.substring(0, 13)}…' : acc);
                        return ListTile(
                          leading: AuthorAvatar(account: acc, handle: name, radius: 20),
                          title: Text('@$label',
                              style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
                          subtitle: Text('·${acctTag(acc)}',
                              style: const TextStyle(color: kDim, fontSize: 11, fontFamily: 'monospace')),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class PhotoScreen extends StatelessWidget {
  // Either a cid (public post media, fetched by MediaImage) or raw bytes (a DM attachment, which is
  // decrypted on-device and must never be re-fetched as plaintext by cid).
  const PhotoScreen({super.key, this.cid = '', this.bytes})
      : assert(cid != '' || bytes != null, 'PhotoScreen needs a cid or bytes');
  final String cid;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: bytes != null
              ? Image.memory(bytes!, fit: BoxFit.contain)
              : MediaImage(cid: cid, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

// FLAG_SECURE gate (native, via MainActivity). Blocks OS screenshots + screen recording + the recents
// thumbnail while a disappearing photo is on screen. NOT camera-proof — nothing an app does can be.
class SecureScreen {
  static const _ch = MethodChannel('xchat/secure');
  static Future<void> on() async { try { await _ch.invokeMethod('on'); } catch (_) {} }
  static Future<void> off() async { try { await _ch.invokeMethod('off'); } catch (_) {} }
}

// A disappearing photo: shown full-screen for a fixed number of seconds with a live countdown ring,
// then it closes and the caller deletes it. Screen capture is blocked while it's up (see SecureScreen).
class DisappearingPhotoScreen extends StatefulWidget {
  const DisappearingPhotoScreen({super.key, required this.bytes, required this.seconds});
  final Uint8List bytes;
  final int seconds;
  @override
  State<DisappearingPhotoScreen> createState() => _DisappearingPhotoScreenState();
}

class _DisappearingPhotoScreenState extends State<DisappearingPhotoScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    SecureScreen.on();                         // block capture for the life of this screen
    _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds.clamp(1, 120)))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) Navigator.of(context).maybePop();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    SecureScreen.off();                        // re-allow capture everywhere else
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(child: Center(child: Image.memory(widget.bytes, fit: BoxFit.contain))),
          // Countdown ring + remaining seconds, top-right.
          Positioned(
            top: 10, right: 14,
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                final remain = (widget.seconds * (1 - _c.value)).ceil().clamp(0, widget.seconds);
                return SizedBox(
                  width: 46, height: 46,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox(
                      width: 46, height: 46,
                      child: CircularProgressIndicator(
                          value: 1 - _c.value, strokeWidth: 3,
                          backgroundColor: Colors.white24, color: kAccent),
                    ),
                    Text('$remain',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                  ]),
                );
              },
            ),
          ),
          Positioned(
            top: 6, left: 8,
            child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop()),
          ),
          // Honest limit, stated where the viewer sees it.
          Positioned(
            bottom: 12, left: 0, right: 0,
            child: Center(
              child: Text('screen capture blocked · not camera-proof',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 11)),
            ),
          ),
        ]),
      ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  final String cid;
  const VideoScreen({super.key, required this.cid});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  // fetch the movie by CID via the engine (IPFS or relay cache), play from a temp file
  Future<void> _prepare() async {
    // On the web there is no temp directory to stage the bytes in, so the <video> element streams
    // straight from the node instead of us downloading the whole clip first — which also means
    // playback starts without waiting for the full file.
    if (kIsWeb) {
      try {
        final c = VideoPlayerController.networkUrl(Uri.parse('$kBase/api/media?cid=${widget.cid}'))
          ..setLooping(true);
        await c.initialize();
        if (!mounted) {
          c.dispose();
          return;
        }
        setState(() {
          _c = c;
          _ready = true;
        });
        c.play();
      } catch (_) {
        if (mounted) setState(() => _err = 'could not play movie');
      }
      return;
    }
    final bytes = await Api.media(widget.cid);
    if (bytes == null) {
      if (mounted) setState(() => _err = 'movie unavailable');
      return;
    }
    try {
      final tail = widget.cid.substring(widget.cid.length - 12);
      final f = File('${Directory.systemTemp.path}/xc_$tail.mp4');
      await f.writeAsBytes(bytes);
      final c = VideoPlayerController.file(f)..setLooping(true);
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _ready = true;
      });
      c.play();
    } catch (_) {
      if (mounted) setState(() => _err = 'could not play movie');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: kText),
          title: const Text('Movie · played from the relay cache',
              style: TextStyle(color: kText, fontSize: 14))),
      body: Center(
        child: _err != null
            ? Text(_err!, style: const TextStyle(color: kDim))
            : (_ready && _c != null)
                ? GestureDetector(
                    onTap: () => setState(
                        () => _c!.value.isPlaying ? _c!.pause() : _c!.play()),
                    child: AspectRatio(
                        aspectRatio: _c!.value.aspectRatio == 0 ? 16 / 9 : _c!.value.aspectRatio,
                        child: VideoPlayer(_c!)),
                  )
                : const CircularProgressIndicator(color: kAccent),
      ),
    );
  }
}

// A right-to-left scrolling banner, shown ONLY during a coordinated event (a publisher-signed
// announcement the node has verified). Continuous loop; speed is roughly constant regardless of length.
class _AnnouncementMarquee extends StatefulWidget {
  final String text;
  const _AnnouncementMarquee({required this.text});
  @override
  State<_AnnouncementMarquee> createState() => _AnnouncementMarqueeState();
}

class _AnnouncementMarqueeState extends State<_AnnouncementMarquee> with SingleTickerProviderStateMixin {
  static const _style = TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700, height: 1.0);
  late final AnimationController _ac;
  late double _textW;

  @override
  void initState() {
    super.initState();
    _textW = _measure(widget.text);
    final secs = (_textW / 90 + 5).clamp(10, 45).round();   // ~90 px/s, so long and short banners read alike
    _ac = AnimationController(vsync: this, duration: Duration(seconds: secs))..repeat();
  }

  double _measure(String t) {
    final tp = TextPainter(text: TextSpan(text: t, style: _style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    return tp.width;
  }

  @override
  void dispose() { _ac.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30, width: double.infinity,
      color: const Color(0xFFF5C518),   // warning amber — deliberately unlike the normal chrome
      child: ClipRect(
        child: LayoutBuilder(builder: (ctx, cons) {
          final w = cons.maxWidth;
          final total = w + _textW;
          return AnimatedBuilder(
            animation: _ac,
            builder: (_, __) {
              final dx = w - _ac.value * total;   // starts just off the right edge, exits off the left
              return Stack(children: [
                Positioned(
                  left: dx, top: 0, bottom: 0,
                  child: Center(child: Text(widget.text, maxLines: 1, softWrap: false, style: _style)),
                ),
              ]);
            },
          );
        }),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  final int likes, reposts, replies, views;
  final double tipsXno, pending;
  final bool liked, reposted;
  final VoidCallback onLike, onRepost, onTip;
  final VoidCallback? onReply, onQuote;
  const _Actions(
      {required this.likes,
      required this.reposts,
      required this.tipsXno,
      required this.liked,
      required this.reposted,
      required this.onLike,
      required this.onRepost,
      required this.onTip,
      this.replies = 0,
      this.views = 0,
      this.onReply,
      this.onQuote,
      this.pending = 0});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _act(Icons.chat_bubble_outline, replies > 0 ? '$replies' : '', kDim, onReply,
            _say(replies, 'reply', 'replies', 'Reply')),
        Builder(builder: (ctx) => _act(Icons.repeat, reposts > 0 ? '$reposts' : '',
            reposted ? const Color(0xFF4DD0A7) : kDim,
            onQuote == null ? onRepost : () => _repostMenu(ctx),
            // The state belongs in the label: the only cue that you already reposted is the icon's
            // colour, which is exactly the kind of meaning a screen reader cannot reach.
            '${_say(reposts, 'repost', 'reposts', 'Repost')}${reposted ? ', reposted by you' : ''}')),
        _act(liked ? Icons.thumb_up : Icons.thumb_up_outlined, likes > 0 ? '$likes' : '',
            liked ? kAccent : kDim, onLike,
            '${_say(likes, 'like', 'likes', 'Like')}${liked ? ', liked by you' : ''}'),
        // views (impressions) — non-interactive, like X's view counter
        _act(Icons.bar_chart, views > 0 ? _compact(views) : '', kDim, null,
            _say(views, 'view', 'views', 'No views yet')),
        // XNO this post has gathered
        if (tipsXno > 0)
          Semantics(
            label: '${tipsXno.toStringAsFixed(2)} XNO tipped to this post',
            child: ExcludeSemantics(
              child: Row(children: [
                const XnoGlyph(size: 13, color: Color(0xFF4DD0A7), weight: 0.18),
                const SizedBox(width: 4),
                Text(tipsXno.toStringAsFixed(2),
                    style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        // the tip action carries the Ӿ mark — payments are native XNO
        Semantics(
          button: true,
          // The Ӿ glyph is a custom painter, so there is nothing here for a screen reader to read at
          // all — this control was previously silent, and it moves money.
          label: pending > 0 ? 'Tip, ${pending.toStringAsFixed(2)} XNO pending' : 'Tip this post',
          child: ExcludeSemantics(
            child: InkWell(
              onTap: onTip,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(children: [
                  const XnoGlyph(size: 16, color: kAccent, weight: 0.16),
                  const SizedBox(width: 5),
                  Text(pending > 0 ? pending.toStringAsFixed(2) : 'Tip',
                      style: const TextStyle(color: kAccent, fontSize: 13)),
                ]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _repostMenu(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: kBg,
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: Icon(Icons.repeat, color: reposted ? const Color(0xFF4DD0A7) : kText),
          title: Text(reposted ? 'Undo repost' : 'Repost',
              style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
          subtitle: const Text('spread it to your followers; you earn a cut of its tips',
              style: TextStyle(color: kDim, fontSize: 11)),
          onTap: () { Navigator.pop(ctx); onRepost(); },
        ),
        ListTile(
          leading: const Icon(Icons.format_quote, color: kText),
          title: const Text('Quote', style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
          subtitle: const Text('add your own take above the post', style: TextStyle(color: kDim, fontSize: 11)),
          onTap: () { Navigator.pop(ctx); onQuote?.call(); },
        ),
      ])),
    );
  }

  /// One action. `say` is what a screen reader announces — without it this row is five identical
  /// unlabelled targets and a loose number, because an icon carries no text and "3" on its own does
  /// not say three of what.
  Widget _act(IconData icon, String label, Color color, VoidCallback? onTap, String say) {
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      label: say,
      // The glyph has no meaning to announce and the count is already inside `say`; left visible to
      // semantics it is read a second time, as a bare digit with no noun.
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(children: [
              Icon(icon, size: 18, color: color),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 5),
                Text(label, style: TextStyle(color: color, fontSize: 13)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  /// "3 replies", "1 reply", "Reply" — a count that reads as a sentence rather than as a label with
  /// a number stapled on.
  static String _say(int n, String one, String many, String none) =>
      n <= 0 ? none : (n == 1 ? '1 $one' : '$n $many');
}

// ---- comments: signed off-chain replies; each can be tipped like a post ----
class CommentsSheet extends StatefulWidget {
  final Post post;
  final String myHandle, myAccount;
  final double defaultTip;
  final void Function(Map<String, dynamic>) onTipComment;
  final VoidCallback onCommented;
  final bool Function(String account)? isHidden; // mute/block filter for comment authors
  const CommentsSheet(
      {super.key,
      required this.post,
      required this.myHandle,
      required this.myAccount,
      required this.defaultTip,
      required this.onTipComment,
      required this.onCommented,
      this.isHidden});
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final Set<String> _viewedC = {}; // comment cids counted as viewed this session
  final Set<String> _likedC = {};  // comment cids this device has liked (persisted, so it counts once)
  List<Map<String, dynamic>> _comments = [];
  Map<String, dynamic> _eng = {};
  final Map<String, double> _localTip = {}; // comment cid -> XNO bumped this session
  bool _loading = true, _posting = false;
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  Map<String, dynamic>? _replyTo; // the comment being replied to (nested reply)

  @override
  void initState() {
    super.initState();
    EngageStore.likedComments().then((s) { if (mounted) setState(() => _likedC.addAll(s)); });
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Like a comment — mirrors _toggleLike for posts: optimistic count bump, record on the relay keyed by
  // the comment's cid (Api.like is generic over any id), persist so this device counts once, notify author.
  void _toggleLikeComment(Map<String, dynamic> c) {
    final cid = (c['cid'] ?? '') as String;
    if (cid.isEmpty) return;
    final liked = _likedC.contains(cid);
    setState(() {
      liked ? _likedC.remove(cid) : _likedC.add(cid);
      final e = ((_eng[cid] as Map?)?.cast<String, dynamic>()) ?? <String, dynamic>{};
      e['likes'] = ((e['likes'] ?? 0) as num) + (liked ? -1 : 1);
      _eng[cid] = e;
    });
    Api.like(cid, liked ? -1 : 1);
    EngageStore.saveLikedComments(_likedC);
    final acct = (c['account'] ?? '') as String;
    if (!liked && acct.isNotEmpty && acct != widget.myAccount) {
      Api.notifyPush(acct, widget.myHandle, 'like', 'liked your comment');
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([Api.comments(widget.post.id), Api.engagement()]);
    if (!mounted) return;
    final hide = widget.isHidden;
    setState(() {
      _comments = (results[0] as List<Map<String, dynamic>>)
          .where((c) => hide == null || !hide('${c['account']}')).toList();
      _eng = results[1] as Map<String, dynamic>;
      _loading = false;
    });
  }

  void _startReply(Map<String, dynamic> c) {
    setState(() => _replyTo = c);
    _focus.requestFocus();
  }

  // order comments as a reply tree: each reply nested under its parent (depth for indent)
  List<MapEntry<Map<String, dynamic>, int>> _ordered() {
    final byParent = <String, List<Map<String, dynamic>>>{};
    for (final c in _comments) {
      byParent.putIfAbsent((c['parent'] ?? '') as String, () => []).add(c);
    }
    for (final l in byParent.values) {
      l.sort((a, b) => ((a['ts'] ?? 0) as int).compareTo((b['ts'] ?? 0) as int));
    }
    final out = <MapEntry<Map<String, dynamic>, int>>[];
    final seen = <String>{};
    void walk(String parentCid, int depth) {
      for (final c in byParent[parentCid] ?? const []) {
        final cid = (c['cid'] ?? '') as String;
        if (seen.contains(cid)) continue;
        seen.add(cid);
        out.add(MapEntry(c, depth > 2 ? 2 : depth));
        walk(cid, depth + 1);
      }
    }
    walk('', 0);
    // any comment whose parent isn't present → show at root
    for (final c in _comments) {
      final cid = (c['cid'] ?? '') as String;
      if (!seen.contains(cid)) { seen.add(cid); out.add(MapEntry(c, 0)); }
    }
    return out;
  }

  Future<void> _submit() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    final parent = (_replyTo?['cid'] ?? '') as String;
    setState(() => _posting = true);
    final r = await Api.comment(widget.post.id, text, widget.myHandle, parent: parent);
    if (!mounted) return;
    if (r != null && r['ok'] == true) {
      _ctl.clear();
      widget.onCommented();
      setState(() => _replyTo = null);
      await _load();
      setState(() => _posting = false);
    } else {
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard, content: Text('could not post comment — try again')));
    }
  }

  double _tipsOf(String cid) {
    final base = ((_eng[cid]?['tips_xno'] ?? 0) as num).toDouble();
    return base + (_localTip[cid] ?? 0);
  }

  void _tip(Map<String, dynamic> c) {
    widget.onTipComment(c);
    final cid = (c['cid'] ?? '') as String;
    setState(() => _localTip[cid] = (_localTip[cid] ?? 0) + widget.defaultTip);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (_, scroll) => Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                const Icon(Icons.chat_bubble_outline, color: kAccent, size: 20),
                const SizedBox(width: 8),
                Text('Comments${_comments.isEmpty ? '' : ' · ${_comments.length}'}',
                    style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                const Text('signed · off-chain', style: TextStyle(color: kDim, fontSize: 11)),
              ]),
            ),
            Container(color: kLine, height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: kAccent))
                  : _comments.isEmpty
                      ? ListView(controller: scroll, children: const [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Text('No comments yet — be the first',
                                textAlign: TextAlign.center, style: TextStyle(color: kDim)),
                          )
                        ])
                      : Builder(builder: (_) {
                          final ordered = _ordered();
                          return ListView.separated(
                            controller: scroll,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: ordered.length,
                            separatorBuilder: (_, i) =>
                                Container(color: kLine, height: (i + 1 < ordered.length && ordered[i + 1].value > 0) ? 0 : 1),
                            itemBuilder: (_, i) => _tile(ordered[i].key, ordered[i].value),
                          );
                        }),
            ),
            _composer(),
          ]),
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c, int depth) {
    final handle = (c['handle'] ?? 'anon') as String;
    final account = (c['account'] ?? '') as String;
    final text = (c['text'] ?? '') as String;
    final ts = (c['ts'] ?? 0) as int;
    final cid = (c['cid'] ?? '') as String;
    final tips = _tipsOf(cid);
    final views = ((_eng[cid]?['views'] ?? 0) as num).toInt();
    final likes = ((_eng[cid]?['likes'] ?? 0) as num).toInt();
    final liked = _likedC.contains(cid);
    if (cid.isNotEmpty && _viewedC.add(cid)) Api.view(cid); // this comment was rendered → an impression
    return Container(
      color: kBg,
      padding: EdgeInsets.fromLTRB(14.0 + depth * 30, 12, 14, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (depth > 0) Padding(
          padding: const EdgeInsets.only(right: 8, top: 6),
          child: Icon(Icons.subdirectory_arrow_right, size: 15, color: kDim),
        ),
        AuthorAvatar(account: account, handle: handle, radius: depth > 0 ? 14 : 17),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: AnimatedBuilder(
                  animation: ProfileCache.I,
                  builder: (_, __) => Text(ProfileCache.I.displayName(account, handle),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
              const SizedBox(width: 6),
              Text('· ${timeAgo(ts)}', style: const TextStyle(color: kDim, fontSize: 12)),
            ]),
            const SizedBox(height: 2),
            Text(text, style: const TextStyle(color: kText, fontSize: 14, height: 1.35)),
            const SizedBox(height: 6),
            Row(children: [
              if (tips > 0) ...[
                const XnoGlyph(size: 12, color: Color(0xFF4DD0A7), weight: 0.18),
                const SizedBox(width: 4),
                Text(tips.toStringAsFixed(2),
                    style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 14),
              ],
              InkWell(
                onTap: () => _startReply(c),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('Reply', style: TextStyle(color: kDim, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: () => _toggleLikeComment(c),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(children: [
                    Icon(liked ? Icons.thumb_up : Icons.thumb_up_outlined, size: 14, color: liked ? kAccent : kDim),
                    if (likes > 0) ...[
                      const SizedBox(width: 4),
                      Text('$likes', style: TextStyle(color: liked ? kAccent : kDim, fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: () => _tip(c),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(children: [
                    const XnoGlyph(size: 14, color: kAccent, weight: 0.16),
                    const SizedBox(width: 5),
                    Text('Tip', style: const TextStyle(color: kAccent, fontSize: 13)),
                  ]),
                ),
              ),
              if (views > 0) ...[
                const SizedBox(width: 12),
                const Icon(Icons.bar_chart, size: 14, color: kDim),
                const SizedBox(width: 3),
                Text('${_compact(views)}', style: const TextStyle(color: kDim, fontSize: 12)),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kLine))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_replyTo != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
            child: Row(children: [
              Icon(Icons.subdirectory_arrow_right, size: 14, color: kAccent),
              const SizedBox(width: 6),
              Expanded(child: Text('Replying to @${_replyTo!['handle']}',
                  style: const TextStyle(color: kAccent, fontSize: 12.5, fontWeight: FontWeight.w600))),
              InkWell(
                onTap: () => setState(() => _replyTo = null),
                child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 16, color: kDim)),
              ),
            ]),
          ),
        Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              focusNode: _focus,
              style: const TextStyle(color: kText, fontSize: 15),
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: _replyTo != null ? 'Post your reply…' : 'Add a comment…',
                hintStyle: const TextStyle(color: kDim),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
            ),
          ),
          _posting
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
              : IconButton(
                  onPressed: _submit,
                  icon: const Icon(Icons.send, color: kAccent),
                  tooltip: 'Send',
                ),
        ]),
      ),
        ]),
      ),
    );
  }
}

// ---- compose ----
// result of composing: one or more thread segments, an optional quoted post id, and an
// optional article title (a titled post publishes as a long-form article)
class ComposeResult {
  final List<String> segments;
  final String quote;
  final String title;
  final List<String> pollOptions; // non-empty → a poll (segments.first is the question)
  final Uint8List? mediaBytes;    // an attached photo/GIF/video (goes on the first post)
  final String mediaKind;         // 'photo' or 'movie'
  final String channel;           // publish under this channel identity (name); '' = as yourself
  ComposeResult(this.segments, this.quote,
      {this.title = '', this.pollOptions = const [], this.mediaBytes, this.mediaKind = '', this.channel = ''});
}

class ComposeSheet extends StatefulWidget {
  final String handle, account;
  final Post? quotedPost; // when set, this is a quote-post embedding that post
  final Post? replyToPost; // when set, this post is an X-style reply threaded under that post
  final List<String> channels; // the author's channels — an article can be published under one
  final Map<String, String> people; // account -> handle, for @-mention autocomplete (feed-seen accounts)
  const ComposeSheet({super.key, required this.handle, required this.account, this.quotedPost, this.replyToPost, this.channels = const [], this.people = const {}});
  @override
  State<ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<ComposeSheet> {
  String _asChannel = ''; // '' = publish as yourself; else the channel name
  final List<TextEditingController> _cs = [TextEditingController()];
  final _titleCtl = TextEditingController();
  final List<TextEditingController> _pollOpts = [TextEditingController(), TextEditingController()];
  bool _article = false, _poll = false;
  Uint8List? _mediaBytes;   // attached photo/GIF/video
  String _mediaKind = '';   // 'photo' | 'movie'
  final _picker = ImagePicker();

  bool get _isQuote => widget.quotedPost != null;
  bool get _isReply => widget.replyToPost != null;
  bool get _isThread => _cs.length > 1;
  bool get _hasMedia => _mediaBytes != null;

  bool _compressing = false;

  // @-mention autocomplete (X-style): while you type "@part" in a body field, suggest matching handles;
  // picking one inserts "@handle ". The mention renders as a tappable @handle in the feed (onTapHandle).
  TextEditingController? _mentionCtl;      // the body field the mention is being typed in
  int _mentionStart = -1;                  // index of the '@' that opened the token
  String _mentionQuery = '';

  // Find the "@token" the cursor sits in (if any) and drive the suggestion list from it. A mention
  // starts at '@' that is at the field start or preceded by whitespace, and runs to the cursor with no
  // whitespace in between.
  void _onBodyChanged(TextEditingController c) {
    final sel = c.selection;
    final pos = sel.baseOffset;
    if (!sel.isValid || sel.baseOffset != sel.extentOffset || pos < 0 || pos > c.text.length) {
      _clearMention(); return;
    }
    final text = c.text;
    int i = pos - 1;
    while (i >= 0) {
      final ch = text[i];
      if (ch == '@') break;
      if (ch == ' ' || ch == '\n' || ch == '\t') { i = -1; break; }
      i--;
    }
    if (i < 0 || (i > 0 && text[i - 1] != ' ' && text[i - 1] != '\n' && text[i - 1] != '\t')) {
      _clearMention(); return;
    }
    final query = text.substring(i + 1, pos);
    if (query.length > 30) { _clearMention(); return; }
    setState(() { _mentionCtl = c; _mentionStart = i; _mentionQuery = query; });
  }

  void _clearMention() {
    if (_mentionCtl != null || _mentionStart != -1) {
      setState(() { _mentionCtl = null; _mentionStart = -1; _mentionQuery = ''; });
    }
  }

  // account -> the name to mention. Match on the PROFILE DISPLAY NAME (keyholder, Jiован…), because in
  // xchat the feed handle is very often the default 'you.xno' and the display name is what distinguishes
  // people. Inserting the display name is also what resolves: tapping @name opens their profile if it
  // matches, else a Discover search for that name.
  List<MapEntry<String, String>> _mentionMatches() {
    if (_mentionCtl == null) return const [];
    final q = _mentionQuery.toLowerCase();
    final seen = <String>{};
    final out = <MapEntry<String, String>>[];
    for (final e in widget.people.entries) {
      final name = ProfileCache.I.displayName(e.key, e.value).trim();
      final key = name.toLowerCase();
      if (name.isEmpty || key == 'you.xno' || key == 'anon.xno' || seen.contains(key)) continue;
      if (q.isEmpty || key.contains(q)) { seen.add(key); out.add(MapEntry(e.key, name)); }
      if (out.length >= 6) break;
    }
    return out;
  }

  void _applyMention(String handle) {
    final c = _mentionCtl;
    if (c == null || _mentionStart < 0) return;
    final end = c.selection.baseOffset.clamp(0, c.text.length);
    final newText = '${c.text.substring(0, _mentionStart)}@$handle ${c.text.substring(end)}';
    final newPos = _mentionStart + handle.length + 2;   // caret after "@handle "
    c.value = TextEditingValue(
        text: newText, selection: TextSelection.collapsed(offset: newPos.clamp(0, newText.length)));
    _clearMention();
  }

  // One post-body field (a thread segment). Extracted to a method so `c` is a LOCAL captured correctly
  // by onChanged — a closure over the collection-for's `i` would read the loop's final value and index
  // `_cs` out of bounds, silently killing the change handler (and the @-mention detection with it).
  Widget _segRow(int i) {
    final c = _cs[i];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(children: [
        AuthorAvatar(account: widget.account, handle: widget.handle, radius: 20),
        if (i < _cs.length - 1)
          Expanded(child: Container(width: 2, color: kLine, margin: const EdgeInsets.symmetric(vertical: 4))),
      ]),
      const SizedBox(width: 12),
      Expanded(
        child: TextField(
          controller: c,
          autofocus: i == 0 && !_article,
          maxLines: null,
          minLines: _article ? 6 : (i == 0 ? 3 : 1),
          onChanged: (_) => _onBodyChanged(c),
          onTap: () => _onBodyChanged(c),
          style: const TextStyle(color: kText, fontSize: 17, height: 1.4),
          decoration: InputDecoration(
              hintText: _article
                  ? 'Write your article…'
                  : _poll
                      ? 'Ask a question…'
                      : i == 0
                          ? (_isQuote ? 'Add a comment' : 'What’s happening on-chain?')
                          : 'Add another post…',
              hintStyle: const TextStyle(color: kDim),
              border: InputBorder.none),
        ),
      ),
    ]);
  }

  Future<void> _attach(bool video) async {
    final x = video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (x == null) return;

    Uint8List bytes;
    if (video) {
      // On-device compression so more clips fit under the ~6 MB relay pin cap. Falls back to the
      // original bytes if compression fails or isn't supported; the size check below is the backstop.
      setState(() => _compressing = true);
      try {
        final info = await VideoCompress.compressVideo(
            x.path, quality: VideoQuality.MediumQuality, deleteOrigin: false, includeAudio: true);
        final f = info?.file;
        bytes = (f != null) ? await f.readAsBytes() : await x.readAsBytes();
      } catch (_) {
        bytes = await x.readAsBytes();
      } finally {
        if (mounted) setState(() => _compressing = false);
      }
    } else {
      bytes = await x.readAsBytes();
    }

    // relay pin cap is ~6 MB — refuse larger so the blob actually survives the relays
    const capMb = 6;
    if (bytes.length > capMb * 1024 * 1024) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      final what = video ? 'Video' : 'Photo';
      final tip = video
          ? 'Even compressed it’s over $capMb MB — try a shorter clip.'
          : 'Try a smaller image.';
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text('$what is $mb MB — the limit is $capMb MB. $tip')));
      return;
    }
    setState(() { _mediaBytes = bytes; _mediaKind = video ? 'movie' : 'photo'; });
  }

  @override
  void initState() {
    super.initState();
    // Warm the profile cache for @-mention suggestions: matches are keyed on the DISPLAY name, which
    // isn't in the feed handle map, so make sure each candidate's profile is fetched. ensure() dedups.
    for (final acc in widget.people.keys) {
      ProfileCache.I.ensure(acc);
    }
  }

  @override
  void dispose() {
    for (final c in _cs) { c.dispose(); }
    for (final c in _pollOpts) { c.dispose(); }
    _titleCtl.dispose();
    VideoCompress.deleteAllCache();   // compressed clips are already read into memory; drop the disk cache
    super.dispose();
  }

  void _submit() {
    final segs = _cs.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (_poll) {
      final opts = _pollOpts.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
      if (segs.isEmpty || opts.length < 2) return; // need a question + ≥2 options
      Navigator.pop(context, ComposeResult([segs.first], '', pollOptions: opts));
      return;
    }
    // media may go with just an attachment (no text required)
    if (segs.isEmpty && !_hasMedia) return;
    if (segs.isEmpty) segs.add('');
    Navigator.pop(context, ComposeResult(
        _article ? [segs.first] : segs, // an article is a single long-form post
        _isQuote ? widget.quotedPost!.id : '',
        title: _article ? _titleCtl.text.trim() : '',
        mediaBytes: _mediaBytes, mediaKind: _mediaKind,
        channel: _article ? _asChannel : ''));   // articles can be published under a channel
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final btnLabel = _isReply ? 'Reply' : (_isQuote ? 'Quote' : (_article ? 'Publish' : (_isThread ? 'Post all' : 'Post')));
    final segCount = (_article || _poll) ? 1 : _cs.length; // article/poll bodies are single
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel', style: TextStyle(color: kDim))),
            // attach a photo/GIF or a video (not for article/poll)
            if (!_article && !_poll) ...[
              IconButton(
                onPressed: _compressing ? null : () => _attach(false),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.image_outlined, size: 21, color: kAccent),
                tooltip: 'Photo / GIF',
              ),
              IconButton(
                onPressed: _compressing ? null : () => _attach(true),
                visualDensity: VisualDensity.compact,
                icon: _compressing
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: kAccent))
                    : const Icon(Icons.videocam_outlined, size: 21, color: kAccent),
                tooltip: _compressing ? 'Compressing…' : 'Video',
              ),
            ],
            if (_article)
              IconButton(
                onPressed: () => _attach(false),      // cover reuses the media field (kind stays 'article')
                visualDensity: VisualDensity.compact,
                icon: Icon(_hasMedia ? Icons.image : Icons.add_photo_alternate_outlined, size: 21, color: kAccent),
                tooltip: 'Cover image',
              ),
            const Spacer(),
            if (_article && widget.channels.isNotEmpty)
              PopupMenuButton<String>(
                initialValue: _asChannel,
                onSelected: (v) => setState(() => _asChannel = v),
                color: kCard,
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(value: '', child: Text('You', style: TextStyle(color: kText))),
                  for (final c in widget.channels)
                    PopupMenuItem<String>(value: c, child: Text(c, style: const TextStyle(color: kText))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.person_outline, size: 15, color: kAccent),
                    const SizedBox(width: 3),
                    Text(_asChannel.isEmpty ? 'You' : _asChannel,
                        style: const TextStyle(color: kAccent, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    const Icon(Icons.arrow_drop_down, size: 16, color: kAccent),
                  ]),
                ),
              ),
            if (!_isQuote && !_isThread && !_poll)
              // toggle long-form article mode (adds a title)
              IconButton(
                onPressed: () => setState(() => _article = !_article),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.article_outlined, size: 20, color: _article ? kAccent : kDim),
                tooltip: 'Article',
              ),
            if (!_isQuote && !_isThread && !_article)
              // toggle poll mode (question + options)
              IconButton(
                onPressed: () => setState(() => _poll = !_poll),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.bar_chart, size: 22, color: _poll ? kAccent : kDim),
                tooltip: 'Poll',
              ),
            if (!_isQuote && !_article && !_poll)
              IconButton(
                onPressed: () => setState(() => _cs.add(TextEditingController())),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.forum_outlined, size: 20, color: kAccent),
                tooltip: 'Add to thread',
              ),
            const SizedBox(width: 2),
            ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
              child: Text(btnLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_isReply) Padding(
                  padding: const EdgeInsets.only(left: 52, bottom: 8),
                  child: Row(children: [
                    Text('Replying to @${widget.replyToPost!.handle}',
                        style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ),
                if (_article) Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: TextField(
                    controller: _titleCtl,
                    autofocus: true,
                    maxLines: null,
                    maxLength: 100,
                    style: const TextStyle(color: kText, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
                    decoration: const InputDecoration(
                        hintText: 'Article title',
                        hintStyle: TextStyle(color: kDim, fontWeight: FontWeight.w800),
                        border: InputBorder.none, counterText: ''),
                  ),
                ),
                for (int i = 0; i < segCount; i++) _segRow(i),
                if (_hasMedia) Padding(
                  padding: const EdgeInsets.only(left: 52, top: 8),
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: _mediaKind == 'photo'
                          ? Image.memory(_mediaBytes!, width: double.infinity, height: 180, fit: BoxFit.cover)
                          : Container(
                              height: 120, width: double.infinity, color: kCard,
                              child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.movie_outlined, color: kDim, size: 30),
                                SizedBox(height: 6),
                                Text('video attached', style: TextStyle(color: kDim, fontSize: 13)),
                              ]))),
                    ),
                    Positioned(right: 6, top: 6, child: GestureDetector(
                      onTap: () => setState(() { _mediaBytes = null; _mediaKind = ''; }),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                        child: const Icon(Icons.close, color: Colors.white, size: 18)),
                    )),
                  ]),
                ),
                if (_isQuote) Padding(
                  padding: const EdgeInsets.only(left: 52, top: 4),
                  child: QuotedCard(post: widget.quotedPost!),
                ),
                if (_poll) Padding(
                  padding: const EdgeInsets.only(left: 52, top: 6),
                  child: Column(children: [
                    for (int i = 0; i < _pollOpts.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _pollOpts[i],
                              maxLength: 40,
                              style: const TextStyle(color: kText, fontSize: 15),
                              decoration: InputDecoration(
                                hintText: 'Option ${i + 1}',
                                hintStyle: const TextStyle(color: kDim),
                                counterText: '',
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: kLine)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: kAccent)),
                              ),
                            ),
                          ),
                          if (_pollOpts.length > 2)
                            IconButton(
                              onPressed: () => setState(() => _pollOpts.removeAt(i).dispose()),
                              icon: const Icon(Icons.close, size: 18, color: kDim),
                            ),
                        ]),
                      ),
                    if (_pollOpts.length < 4)
                      Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                        onPressed: () => setState(() => _pollOpts.add(TextEditingController())),
                        icon: const Icon(Icons.add, size: 16, color: kAccent),
                        label: const Text('Add option', style: TextStyle(color: kAccent, fontWeight: FontWeight.w600)),
                      )),
                  ]),
                ),
              ]),
            ),
          ),
          // @-mention suggestions, pinned just above the keyboard while you type "@part". Wrapped in an
          // AnimatedBuilder so it fills in as the candidates' profiles (display names) finish loading.
          AnimatedBuilder(
            animation: ProfileCache.I,
            builder: (_, __) {
              if (_mentionCtl == null) return const SizedBox.shrink();
              final matches = _mentionMatches();
              if (matches.isEmpty) return const SizedBox.shrink();
              return Container(
                constraints: const BoxConstraints(maxHeight: 196),
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                    color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final e in matches)
                      ListTile(
                        dense: true,
                        leading: AuthorAvatar(account: e.key, handle: e.value, radius: 15),
                        title: Text('@${e.value}',
                            style: const TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text('·${acctTag(e.key)}',
                            style: const TextStyle(color: kDim, fontSize: 11, fontFamily: 'monospace')),
                        onTap: () => _applyMention(e.value),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                _poll
                    ? '📊 a poll — each vote is a signed event, one per account'
                    : _article
                        ? '📄 a long-form article — title + body, signed & content-addressed'
                        : _isThread
                            ? '🧵 a thread — each post links to the one above, all signed'
                            : '⛓ posts are content-addressed & signed — no host can drop them',
                style: const TextStyle(color: kDim, fontSize: 11)),
          ),
        ]),
      ),
    );
  }
}

// a poll: fetches the signed, per-account tally; tap an option to cast one signed vote.
// Before you vote it shows tappable options; after, it shows result bars + your choice.
class PollView extends StatefulWidget {
  final String pollId;
  final List<String> options;
  const PollView({super.key, required this.pollId, required this.options});
  @override
  State<PollView> createState() => _PollViewState();
}

class _PollViewState extends State<PollView> {
  Map<int, int> _counts = {};
  int _total = 0;
  int? _myOption;
  bool _loading = true, _voting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Api.pollGet(widget.pollId);
    if (!mounted) return;
    setState(() {
      final c = (r?['counts'] as Map?) ?? {};
      _counts = {for (final e in c.entries) int.parse('${e.key}'): (e.value as num).toInt()};
      _total = (r?['total'] ?? 0) as int;
      _myOption = r?['my_option'] is int ? r!['my_option'] as int : null;
      _loading = false;
    });
  }

  Future<void> _vote(int i) async {
    if (_voting || _myOption != null) return;
    setState(() { _voting = true; _myOption = i; _counts[i] = (_counts[i] ?? 0) + 1; _total += 1; });
    await Api.pollVote(widget.pollId, i);
    await _load();
    if (mounted) setState(() => _voting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 14),
          child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)));
    }
    final voted = _myOption != null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (int i = 0; i < widget.options.length; i++)
          _option(i, voted),
        const SizedBox(height: 4),
        Text('$_total vote${_total == 1 ? '' : 's'}${voted ? ' · you voted' : ' · tap to vote'} · signed, one per account',
            style: const TextStyle(color: kDim, fontSize: 11.5)),
      ]),
    );
  }

  Widget _option(int i, bool voted) {
    final count = _counts[i] ?? 0;
    final pct = _total == 0 ? 0.0 : count / _total;
    final mine = _myOption == i;
    final leading = _total > 0 && count == _counts.values.fold<int>(0, (a, b) => b > a ? b : a);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GestureDetector(
        onTap: voted ? null : () => _vote(i),
        child: Container(
          height: 38,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: mine ? kAccent : kLine)),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            if (voted) FractionallySizedBox(
              widthFactor: pct.clamp(0.0, 1.0),
              child: Container(color: (leading ? kAccent : kDim).withValues(alpha: 0.22)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                if (mine) const Padding(padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.check_circle, size: 15, color: kAccent)),
                Expanded(child: Text(widget.options[i],
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: kText, fontSize: 14, fontWeight: leading && voted ? FontWeight.w700 : FontWeight.w500))),
                if (voted) Text('${(pct * 100).round()}%',
                    style: const TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// a compact embedded card for a quoted post (rendered inside a quote-post or the composer)
class QuotedCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  const QuotedCard({super.key, required this.post, this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
            border: Border.all(color: kLine), borderRadius: BorderRadius.circular(12), color: kBg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AuthorAvatar(account: post.account, handle: post.handle, radius: 11),
            const SizedBox(width: 7),
            Flexible(child: AnimatedBuilder(
              animation: ProfileCache.I,
              builder: (_, __) => Text(ProfileCache.I.displayName(post.account, post.handle),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 13.5)),
            )),
            const SizedBox(width: 5),
            Text('@${post.handle} · ${timeAgo(post.ts)}',
                style: const TextStyle(color: kDim, fontSize: 12), overflow: TextOverflow.ellipsis),
          ]),
          const SizedBox(height: 5),
          Text(post.text,
              maxLines: 4, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kText, fontSize: 14, height: 1.3)),
          if (post.media != null && post.kind == 'movie')
            const Padding(padding: EdgeInsets.only(top: 6),
                child: Row(children: [Icon(Icons.movie_outlined, size: 14, color: kDim),
                    SizedBox(width: 5), Text('movie', style: TextStyle(color: kDim, fontSize: 12))])),
        ]),
      ),
    );
  }
}

// ---- GROUPS: a view over the DMs that already arrived --------------------------------------------
//
// There is no group store and no group fetch. A group message IS a DM carrying an envelope, so the
// inbox the app already has contains everything: scanning it yields the groups you are in, who is in
// them and what was said. That is why groups needed no relay change, no node change and no new poll —
// and why a group appears on a reinstall as soon as your DMs do.

class GroupChatMsg {
  final String from, cid, key;
  final int ts;
  const GroupChatMsg(this.from, this.ts, this.cid, this.key);
}

class GroupChat {
  final String gid;
  String name;
  List<String> members;
  final List<GroupChatMsg> msgs;
  int newestTs;
  GroupChat(this.gid, this.name, this.members, this.msgs, this.newestTs);

  /// Groups, newest first, built from the conversation list.
  ///
  /// Membership and name are LAST-WRITER-WINS: the newest envelope seen for a group decides both.
  /// With no coordinator there is nothing better to do, and pretending otherwise would be worse than
  /// saying so — see the note on GroupMsg.
  static List<GroupChat> extract(List<Map<String, dynamic>> convos) {
    final by = <String, GroupChat>{};
    final seen = <String, Set<String>>{};       // gid -> cids already taken
    for (final c in convos) {
      for (final m in ((c['messages'] as List?) ?? const [])) {
        final env = GroupMsg.parse('${m['text']}');
        if (env == null) continue;
        final ts = (m['ts'] as int?) ?? 0;
        final g = by.putIfAbsent(env.gid,
            () => GroupChat(env.gid, env.name, env.members, [], 0));
        // The SAME message reaches us once per conversation it was addressed through — our own copy
        // and, for anything we sent, one per recipient. The cid names the content, so it is what
        // makes a message one message.
        final cids = seen.putIfAbsent(env.gid, () => <String>{});
        if (cids.add(env.cid)) {
          g.msgs.add(GroupChatMsg('${m['outgoing'] == true ? '' : c['peer']}', ts, env.cid, env.key));
        }
        if (ts >= g.newestTs) {
          g.newestTs = ts;
          if (env.name.isNotEmpty) g.name = env.name;
          if (env.members.isNotEmpty) g.members = env.members;
        }
      }
    }
    final out = by.values.toList();
    for (final g in out) {
      g.msgs.sort((a, b) => a.ts.compareTo(b.ts));
    }
    out.sort((a, b) => b.newestTs.compareTo(a.newestTs));
    return out;
  }
}

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({super.key, required this.group, required this.handleOf});
  final GroupChat group;
  final String Function(String account) handleOf;
  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  // cid -> plaintext, process-wide. The content lives in a blob, so without this every rebuild
  // re-fetches and re-decrypts the whole conversation.
  static final Map<String, String> _body = {};
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  String? _err;
  late GroupChat _g = widget.group;

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetchAll() async {
    for (final m in _g.msgs) {
      if (_body.containsKey(m.cid)) continue;
      final t = await Api.groupText(m.cid, m.key);
      if (!mounted) return;
      // A message whose blob is gone is marked as such rather than left blank — an empty bubble
      // reads as "they sent nothing", which is a different and wrong claim.
      setState(() => _body[m.cid] = t ?? '');
    }
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() { _sending = true; _err = null; });
    final r = await Api.groupSend(_g.gid, _g.name, _g.members, text);
    if (!mounted) return;
    if (r['ok'] == true) {
      _ctl.clear();
      // Report a PARTIAL send instead of showing a tick. "Sent to 4 of 5" is the truth, and the one
      // person who did not get it is exactly what the sender needs to know.
      final sent = r['sent'] as int, of = r['of'] as int;
      setState(() {
        _sending = false;
        _err = sent < of ? 'sent to $sent of $of — the rest have not enabled DMs' : null;
      });
    } else {
      setState(() { _sending = false; _err = '${r['error'] ?? 'send failed'}'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_g.name.isEmpty ? 'Group' : _g.name,
              style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
          Text('🔐 ${_g.members.length} members',
              style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 11.5)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _g.msgs.isEmpty
              ? const Center(child: Text('No messages yet.', style: TextStyle(color: kDim)))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: _g.msgs.length,
                  itemBuilder: (_, i) {
                    final m = _g.msgs[i];
                    final out = m.from.isEmpty;
                    final txt = _body[m.cid];
                    return Align(
                      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78),
                        decoration: BoxDecoration(
                            color: out ? kAccent : kCard,
                            borderRadius: BorderRadius.circular(16)),
                        child: Column(
                          crossAxisAlignment:
                              out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Who said it. In a group this is not decoration — without it a
                            // conversation between four people is unreadable.
                            if (!out)
                              Text(widget.handleOf(m.from),
                                  style: const TextStyle(
                                      fontSize: 11, fontWeight: FontWeight.w700, color: kAccent)),
                            Text(
                              txt == null
                                  ? '…'
                                  : (txt.isEmpty ? 'message unavailable' : txt),
                              style: TextStyle(
                                  color: out ? Colors.black : kText,
                                  fontSize: 15,
                                  height: 1.3,
                                  fontStyle: txt != null && txt.isEmpty
                                      ? FontStyle.italic
                                      : FontStyle.normal),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_err != null)
          Container(
            width: double.infinity, color: const Color(0xFF2A1A00),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(_err!, style: const TextStyle(color: Color(0xFFFFC46B), fontSize: 12)),
          ),
        SafeArea(
          top: false,
          child: Container(
            decoration: const BoxDecoration(
                color: kCard, border: Border(top: BorderSide(color: kLine))),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  style: const TextStyle(color: kText, fontSize: 15),
                  minLines: 1, maxLines: 5,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                      hintText: 'Encrypted message…',
                      hintStyle: TextStyle(color: kDim), border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 12)),
                ),
              ),
              _sending
                  ? const Padding(padding: EdgeInsets.all(10),
                      child: SizedBox(height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
                  : IconButton(
                      onPressed: _send,
                      tooltip: 'Send to the group',
                      icon: const Icon(Icons.send, color: kAccent)),
            ]),
          ),
        ),
      ]),
    );
  }
}
