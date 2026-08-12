// ӾChat — a censorship-free X. The "Ӿ" is the XNO (Nano) symbol.
// Identity = a Nano keypair. Feed = read from the ledger. Tips = feeless Nano.
// Backend = the Keel engine (same censorship-free stack as KeelTube).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'wallet.dart';

// The engine/relay endpoint. Default: the Android emulator reaches the host loopback at
// 10.0.2.2. Runtime-configurable (Settings → Connection) so the app can point at a hosted
// relay (e.g. a Fly.io node) — that's how a physical phone + an emulator share one network.
const String kDefaultBase = 'https://xchat-alpha-node.fly.dev'; // hosted alpha node (run your own + repoint in Settings)
String kBase = kDefaultBase;

// On-device signer, built from the local seed. Every write the app publishes (follows, comments,
// polls, profile, …) is signed HERE and only the signed record is sent — the node never sees the
// seed. Set as soon as the seed is known (RootGate), used by the Api layer below.
NanoWallet? gWallet;
const String kGw = 'http://10.0.2.2:8080/ipfs/';
const String kAppVersion = '2.2.0'; // this build; the update checker compares against the signed release
// NB the version JUMPED 0.1.x → 2.2.0 on purpose: the older (keeltube-lineage) app reached ~v2.1.0, so a
// 0.1.x release looked like a DOWNGRADE to those installs and was never offered. 2.2.0 supersedes every
// prior lineage. (Cross-lineage installs that pin a different publisher key still need one manual sideload.)
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
  final saved = (await SharedPreferences.getInstance()).getString('xchat_endpoint');
  if (saved != null && saved.isNotEmpty) kBase = saved;
  runApp(const XChatApp());
}

class XChatApp extends StatelessWidget {
  const XChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ӾChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kBg),
        fontFamily: 'Roboto',
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

  static Future<String?> get() async {
    final s = await _secure.read(key: _k);
    if (s != null && s.isNotEmpty) return s;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_k);
    if (legacy == null || legacy.isEmpty) return null;
    await _secure.write(key: _k, value: legacy);
    await prefs.remove(_k);                       // only after the keystore copy is committed
    return legacy;
  }

  static Future<void> save(String s) async => _secure.write(key: _k, value: s);

  static Future<void> clear() async {
    await _secure.delete(key: _k);
    await (await SharedPreferences.getInstance()).remove(_k);
  }
}

String genSeed() {
  final r = math.Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
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
  bool notifyLike, notifyComment, notifyTip;
  int forYouFreshness;      // For You ranking: 0 = popular, 1 = balanced, 2 = latest
  bool forYouBoostFollows;  // boost posts from people you follow
  bool autoSweep;           // auto-forward balance above the safety cap to a savings address
  String sweepAddr;         // the external savings address (this app holds no key for it)
  Settings({
    this.defaultTip = 0.01,
    this.relaySplit = 10,
    this.reposterSplit = 5,
    this.notifyLike = true,
    this.notifyComment = true,
    this.notifyTip = true,
    this.forYouFreshness = 1,
    this.forYouBoostFollows = true,
    this.autoSweep = false,
    this.sweepAddr = '',
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
        forYouFreshness: (m['forYouFreshness'] as num?)?.toInt() ?? 1,
        forYouBoostFollows: m['forYouBoostFollows'] ?? true,
        autoSweep: m['autoSweep'] ?? false,
        sweepAddr: m['sweepAddr'] ?? '',
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
          'forYouFreshness': s.forYouFreshness,
          'forYouBoostFollows': s.forYouBoostFollows,
          'autoSweep': s.autoSweep,
          'sweepAddr': s.sweepAddr,
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

// private, on-device bookmarks — a list of saved post ids. Client-side only (like X bookmarks,
// which are private); nothing is published, so your reading list stays yours.
class BookmarkStore {
  static const _k = 'xchat_bookmarks';
  static Future<Set<String>> get() async =>
      ((await SharedPreferences.getInstance()).getStringList(_k) ?? <String>[]).toSet();
  static Future<void> save(Set<String> s) async =>
      (await SharedPreferences.getInstance()).setStringList(_k, s.toList());
}

// remembers the update version the user dismissed, so the auto-check banner nags once per version, not
// every launch. ("" = nothing dismissed.)
class UpdateDismiss {
  static const _k = 'xchat_update_dismissed';
  static Future<String> get() async =>
      (await SharedPreferences.getInstance()).getString(_k) ?? '';
  static Future<void> set(String version) async =>
      (await SharedPreferences.getInstance()).setString(_k, version);
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
    await WalletStore.save(seed);
    gWallet = NanoWallet(seed);       // seedless node: nothing to activate server-side
    setState(() => _seed = seed);
  }

  Future<void> _logout() async {
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
  String _step = 'choose'; // choose | backup | restore
  String _newSeed = '';
  bool _saved = false;
  final _restoreC = TextEditingController();
  String? _err;
  bool _busy = false;

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
                  : _restore(),
        ),
      ),
    );
  }

  Widget _brand() => Column(children: const [
        NanoMark(size: 64),
        SizedBox(height: 14),
        Text('ӾChat',
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
        const Spacer(),
        _bigBtn(_busy ? 'Setting up…' : 'Enter ӾChat', _saved ? kAccent : kLine,
            _saved ? Colors.black : kDim, _saved && !_busy ? () => _finish(_newSeed) : null),
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
                _finish(s);
              }),
      ]);

  Future<void> _finish(String seed) async {
    setState(() => _busy = true);
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
  int localLikes;
  bool liked;
  bool pending = false; // a locally-queued (offline) post not yet sent to any relay
  Post(this.id, this.handle, this.account, this.kind, this.text, this.title,
      this.media, this.thumb, this.dur, this.ts, this.likes, this.reposts,
      {this.quote, this.replyTo, this.poll})
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
      );
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
  static Future<FeedData> feed({int since = 0}) async {
    final url = since > 0 ? '$kBase/api/feed?since=$since' : '$kBase/api/feed';
    final r = await http.get(Uri.parse(url));
    final d = jsonDecode(r.body);
    final c = d['content'] ?? {};
    final posts = (c['posts'] as List?) ?? [];
    return FeedData(
        posts.map((p) => Post.fromJson(p)).toList(),
        (d['onchain_blocks'] ?? 0) as int,
        (c['relays_up'] ?? 0) as int,
        (c['relays_total'] ?? 0) as int);
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
      // sequential on-device sends (each consumes the frontier)
      final ch = await _sendRaw(w, to, creatorRaw);
      if (relay.isNotEmpty && relayRaw > BigInt.zero) await _sendRaw(w, relay, relayRaw);
      if (reposter.isNotEmpty && reposterRaw > BigInt.zero) await _sendRaw(w, reposter, reposterRaw);
      return {
        'ok': ch != null, 'to': to, 'amount': amount, 'hash': ch,
        'creator_xno': creatorRaw / BigInt.from(10).pow(30),
        'relay': relay.isEmpty ? null : relay, 'relay_xno': relayRaw / BigInt.from(10).pow(30),
        'reposter': reposter.isEmpty ? null : reposter, 'reposter_xno': reposterRaw / BigInt.from(10).pow(30),
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
    try {
      final r = await http.post(Uri.parse('$kBase/api/block_process'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'block': block, 'subtype': subtype}));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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

  static Future<void> like(String pid, int delta) => _engagePost('like', pid, delta);
  // repost carries the resharer's account so tips can reward whoever spread the post
  static Future<void> repost(String pid, int delta, String account) async {
    try {
      await http.post(Uri.parse('$kBase/api/repost'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'delta': '$delta', 'account': account}));
    } catch (_) {}
  }
  static Future<void> _engagePost(String kind, String pid, int delta) async {
    try {
      await http.post(Uri.parse('$kBase/api/$kind'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'delta': '$delta'}));
    } catch (_) {}
  }

  static Future<void> tipstat(String pid, String raw) async {
    try {
      await http.post(Uri.parse('$kBase/api/tipstat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': pid, 'raw': raw}));
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
    try {
      final r = await http.get(Uri.parse('$kBase/api/notify'));
      final d = jsonDecode(r.body);
      return ((d['notifs'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
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

  // returns the new post's id (empty string on failure) so a thread can chain reply_to.
  // ON-DEVICE SIGNED, two-step: (1) sign the post event locally + POST it to /api/post_prepare — the
  // node assembles the thread, pins it, and returns the content CID + head seq; (2) sign the head
  // "account|seq|cid|expires" locally + POST to /api/post_submit — the node verifies + gossips it.
  // The seed never leaves the device; the node only assembles content and relays signed records.
  static Future<String> post(String text, {String handle = 'you.xno', String media = '', String mediaKind = '', String quote = '', String replyTo = '', String title = '', String poll = '', int? ts}) async {
    final w = gWallet;
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

  // wallet: claim any pending receivable blocks into the account.
  // ON-DEVICE SIGNED: each receive/open block is built + signed locally, sequentially.
  static Future<Map<String, dynamic>?> receive() async {
    final w = gWallet;
    if (w == null) return null;
    int received = 0;
    try {
      final rc = await http.get(Uri.parse('$kBase/api/receivables?account=${w.account}'));
      final list = ((jsonDecode(rc.body)['receivables'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final item in list) {
        final srcHash = '${item['hash']}';                 // the send block we're receiving
        final amt = BigInt.parse('${item['amount']}');
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
    } catch (_) {}
    final st = await accountState(w.account);
    return {'ok': true, 'received': received, 'balance': st?['balance'] ?? '0'};
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
    try {
      await http.post(Uri.parse('$kBase/api/dm_key_set'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'account': w.account, 'dm_pk': w.dmPub, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']}));
    } catch (_) {}
  }

  // fetch + verify a peer's DM public key (signed by their Nano key)
  static Future<String?> dmKeyGet(String account) async {
    try {
      final r = await http.get(Uri.parse('$kBase/api/dm_key_get?account=$account'));
      return jsonDecode(r.body)['dm_pk'] as String?;
    } catch (_) {
      return null;
    }
  }

  // encrypted DMs: seal ON-DEVICE (NaCl crypto_box), relay only the ciphertext — the node never
  // sees plaintext or any secret.
  static Future<Map<String, dynamic>?> dmSend(String to, String text) async {
    final w = gWallet;
    if (w == null) return null;
    final peer = await dmKeyGet(to);
    if (peer == null) return {'ok': false, 'error': 'recipient has not enabled DMs yet'};
    final ct = w.dmSeal(peer, text);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final r = await http.post(Uri.parse('$kBase/api/dm_send'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'to': to, 'from': w.account, 'from_pk': w.dmPub, 'to_pk': peer, 'ct': ct, 'ts': ts}));
      return {'ok': jsonDecode(r.body)['ok'] == true, 'ts': ts};
    } catch (_) {
      return {'ok': false, 'error': 'send failed'};
    }
  }

  // encrypted DMs: fetch RAW ciphertext records, DECRYPT ON-DEVICE, group into conversations
  static Future<List<Map<String, dynamic>>> dmInbox() async {
    final w = gWallet;
    if (w == null) return [];
    try {
      final r = await http.get(Uri.parse('$kBase/api/dm_inbox?account=${w.account}'));
      final dms = ((jsonDecode(r.body)['dms'] as List?) ?? []).cast<Map<String, dynamic>>();
      final convos = <String, List<Map<String, dynamic>>>{};
      for (final m in dms) {
        final outgoing = m['from'] == w.account;
        final peerAcc = '${outgoing ? m['to'] : m['from']}';
        final peerPk = '${outgoing ? m['to_pk'] : m['from_pk']}';
        final plain = w.dmOpen(peerPk, '${m['ct']}');      // decrypts locally; null if not ours
        if (plain == null) continue;
        (convos[peerAcc] ??= []).add({'from': m['from'], 'outgoing': outgoing, 'text': plain, 'ts': m['ts']});
      }
      for (final lst in convos.values) {
        lst.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
      }
      final out = convos.entries
          .map((e) => {'peer': e.key, 'messages': e.value, 'last_ts': e.value.last['ts']})
          .toList();
      out.sort((a, b) => (b['last_ts'] as int).compareTo(a['last_ts'] as int));
      return out.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
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

  // on-device signed: the app signs the profile record locally; the node only verifies + relays.
  static Future<Map<String, dynamic>?> profileSet(String display, String bio, String avatar, String banner) async {
    final w = gWallet;
    if (w == null) return null;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = w.signMsg(w.profileMsg(ts, display, bio, avatar, banner));
    try {
      final r = await http.post(Uri.parse('$kBase/api/profile_set'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'account': w.account, 'display': display, 'bio': bio, 'avatar': avatar,
                            'banner': banner, 'ts': ts, 'sig': s['sig'], 'pub': s['pub']}));
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
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

}

// compact counts, X-style: 942 · 1.2K · 3.4M
String _compact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) { final k = n / 1000; return '${k < 10 ? k.toStringAsFixed(1) : k.round()}K'; }
  final m = n / 1000000; return '${m < 10 ? m.toStringAsFixed(1) : m.round()}M';
}

String timeAgo(int ts) {
  if (ts == 0) return '';
  final s = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
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
class AuthorAvatar extends StatelessWidget {
  final String account, handle;
  final double radius;
  const AuthorAvatar({super.key, required this.account, required this.handle, this.radius = 22});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ProfileCache.I,
      builder: (_, __) {
        ProfileCache.I.ensure(account);
        final cid = ProfileCache.I.avatarCid(account);
        if (cid != null) {
          return ClipOval(
            child: SizedBox(
              width: radius * 2, height: radius * 2,
              child: MediaImage(cid: cid, fit: BoxFit.cover),
            ),
          );
        }
        return CircleAvatar(
          radius: radius,
          backgroundColor: avatarColor(handle),
          child: Text(handle.isEmpty ? '?' : handle.substring(0, 1).toUpperCase(),
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: radius * 0.62)),
        );
      },
    );
  }
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

class _FeedScreenState extends State<FeedScreen> {
  NanoWallet? _wallet; // on-device signer, built from the local seed — never sent to the node
  List<Post> _posts = [];
  final List<Post> _newPosts = [];        // fetched but held BACK — surfaced via a "new posts" pill,
                                          // not injected live, so the reader's scroll never jumps
  int _pollTick = 0;                      // every 5th quiet poll does a full reconcile (drops expired)
  final ScrollController _scroll = ScrollController();
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
  final Map<String, String> _handleOf = {}; // account -> handle, for the settle bar
  // reshare/media attribution LOCKED at tip time (per creator) — a later reshare can't claim it
  final Map<String, String> _reposterOf = {}; // author account -> resharer account to reward
  final Map<String, String> _mediaOf = {};    // author account -> media cid (to reward its host relay)
  // auto-settle policy: consented once (threshold + cap), fires within bounds, non-custodial
  bool _autoSettle = false;
  double _autoThreshold = 0.05, _autoCap = 1.0, _autoSpent = 0.0;
  int _tab = 0; // 0 = Home, 1 = Discover (everyone + search)
  int _homeFeed = 0; // 0 = For You (ranked), 1 = Following (chronological)
  List<Map<String, dynamic>> _outbox = []; // posts composed OFFLINE, queued + auto-flushed on reconnect
  bool _flushing = false;                  // guards _flushOutbox against re-entrancy
  Map<String, dynamic>? _update;           // a newer signed release found by the launch auto-check
  Set<String> _follows = {};
  Settings _settings = Settings();
  Map<String, dynamic> _engage = {}; // post_id -> {likes, reposts, tips_raw}
  final Set<String> _liked = {}, _reposted = {}, _reported = {};
  Set<String> _muted = {}, _blocked = {}; // per-viewer moderation (accounts)
  Set<String> _bookmarks = {}; // saved post ids (private, on-device)
  final Set<String> _viewed = {}; // ids counted as viewed this session (dedup)
  final Map<String, int> _commentCount = {}; // post_id -> comment count (lazy)
  List<Map<String, dynamic>> _notifs = []; // push payloads (mentions/replies)
  String _account = '';
  // supporter mode: contribute (relay/pin) ONLY when charging + on Wi-Fi
  bool _supporterOn = false, _charging = false, _wifi = false;
  int _supporters = 0;
  final Battery _battery = Battery();
  StreamSubscription? _batSub, _connSub;
  Timer? _republishTimer, _gossipTimer, _feedTimer;
  int _relayed = 0; // signed heads this phone has propagated (backfilled) this session
  bool get _supporterActive => _supporterOn && _charging && _wifi;

  @override
  void initState() {
    super.initState();
    _bootWallet();
    _load();
    _initDevice();
    SettingsStore.get().then((s) {
      if (mounted) setState(() => _settings = s);
    });
    _initProfile();
    MuteStore.get().then((m) { if (mounted) setState(() => _muted = m); });
    BlockStore.get().then((b) { if (mounted) setState(() => _blocked = b); });
    BookmarkStore.get().then((b) { if (mounted) setState(() => _bookmarks = b); });
    // keep our own head alive on the relays (republish < TTL); also backfills new relays
    _republishTimer = Timer.periodic(const Duration(seconds: 45), (_) => Api.republish());
    // quietly poll the feed so posts from OTHER devices appear on their own (no manual refresh)
    _feedTimer = Timer.periodic(const Duration(seconds: 12), (_) => _refreshFeedQuiet());
  }

  @override
  void dispose() {
    _batSub?.cancel();
    _connSub?.cancel();
    _republishTimer?.cancel();
    _gossipTimer?.cancel();
    _feedTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _newestTs() {                               // newest ts we already hold (shown OR buffered)
    var t = 0;
    for (final p in _posts) { if (p.ts > t) t = p.ts; }
    for (final p in _newPosts) { if (p.ts > t) t = p.ts; }
    return t;
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
      if (reconcile) _refreshLabels();   // pick up others' community reports for the shield filter
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
  Future<bool> _onlineNow() async =>
      _onlineFrom(await Connectivity().checkConnectivity());

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
    if (p.account != _account && _settings.notifyTip) {
      Api.notifyPush(p.handle, _handle, 'tip', 'tipped your post ${amt.toStringAsFixed(2)} XNO');
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200),
        backgroundColor: kCard,
        content: Text('◈ +${amt.toStringAsFixed(2)} XNO tallied off-chain — no network, no block')));
    _maybeAutoSettle(p.account, p.handle);
  }

  // fire an on-chain settlement automatically ONLY within the user-consented policy
  Future<void> _maybeAutoSettle(String account, String handle) async {
    if (!_autoSettle) return;
    final amt = _pending[account] ?? 0;
    if (amt + 1e-9 < _autoThreshold) return; // below the per-creator threshold — keep tallying
    if (_autoSpent + amt > _autoCap + 1e-9) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text('auto-settle cap reached — settle the rest manually')));
      return;
    }
    final r = await Api.settle(account, amt.toStringAsFixed(2),
        split: _settings.relaySplit, rsplit: _settings.reposterSplit,
        reposter: _reposterOf[account] ?? '', media: _mediaOf[account] ?? '');
    if (r != null && r['ok'] == true) {
      setState(() {
        _autoSpent += amt;
        _pending.remove(account);
        _reposterOf.remove(account);
        _mediaOf.remove(account);
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text(
              '⚡ auto-settled ${amt.toStringAsFixed(2)} XNO → @$handle · 1 block (policy ≥${_autoThreshold.toStringAsFixed(2)})')));
    } else if (r != null && mounted) {
      // a failed auto-settle must not fail silently — the tally stays pending and the user is told why
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kCard,
          content: Text('auto-settle held: ${r['error'] ?? 'failed'} — still pending')));
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
    final entries = _pending.entries.toList();
    int blocks = 0, failedCount = 0;
    String? err;
    for (final e in entries) {
      final r = await Api.settle(e.key, e.value.toStringAsFixed(2),
          split: _settings.relaySplit, rsplit: _settings.reposterSplit,
          reposter: _reposterOf[e.key] ?? '', media: _mediaOf[e.key] ?? '');
      if (r != null && r['ok'] == true) {
        blocks++;
        // clear ONLY what actually settled — an unpaid tally must stay pending, not silently vanish
        setState(() { _pending.remove(e.key); _reposterOf.remove(e.key); _mediaOf.remove(e.key); });
      } else {
        failedCount++;
        err ??= r?['error']?.toString();
      }
    }
    await _load(); // refresh the footprint meter
    if (!mounted) return;
    final msg = failedCount == 0
        ? 'settled ${entries.length} creator${entries.length == 1 ? '' : 's'} in $blocks Nano block${blocks == 1 ? '' : 's'} · ⚙ PoW delegated (0 ms on device)'
        : blocks > 0
            ? 'settled $blocks of ${entries.length} · $failedCount unpaid (${err ?? 'failed'}) — still pending'
            : 'nothing settled — ${err ?? 'settle failed'}. Your tips are still pending.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: kCard, content: Text(msg)));
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
                  onPressed: () { Navigator.pop(ctx); _showAutoSettle(); },
                  icon: Icon(Icons.tune, size: 20, color: _autoSettle ? kAccent : kDim),
                  tooltip: 'Auto-settle policy',
                ),
              ]),
              Text(
                  _autoSettle
                      ? 'Tips tally off-chain. Auto-settle is on (≥${_autoThreshold.toStringAsFixed(2)} XNO each). Settle the rest now, or leave them to accrue.'
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
                        Text('${e.value.toStringAsFixed(2)} XNO',
                            style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700, fontSize: 14)),
                      ]),
                    )),
                const Divider(color: kLine, height: 22),
                Row(children: [
                  Text('${entries.length} creator${entries.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: kDim, fontSize: 12)),
                  const Spacer(),
                  Text('${total.toStringAsFixed(2)} XNO total',
                      style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: settling
                        ? null
                        : () async {
                            setSheet(() => settling = true);
                            await _settle();               // shows the result snackbar on the main scaffold
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                    style: FilledButton.styleFrom(
                        backgroundColor: kAccent, foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                    child: settling
                        ? const SizedBox(height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : Text('Settle ${total.toStringAsFixed(2)} XNO',
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
      if (p.account.isNotEmpty && p.handle != 'you.xno' && !_hidden(p.account) && seen.add(p.account)) {
        out.add({'account': p.account, 'handle': p.handle});
      }
    }
    out.sort((a, b) => a['handle']!.compareTo(b['handle']!));
    return out;
  }

  // Home shows the people you follow (+ your own posts); everyone if you follow no one yet
  List<Post> _homePosts() {
    final base = _follows.isEmpty
        ? _posts
        : _posts.where((p) => _follows.contains(p.account) || p.account == _account);
    return base.where((p) => !_reported.contains(p.id) && !_hidden(p.account)).toList();
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

  // ranked feed across everyone (minus muted/blocked/reported), highest score first
  List<Post> _forYouPosts() {
    final list = _posts
        .where((p) => !_reported.contains(p.id) && !_hidden(p.account) && p.replyTo == null)
        .toList();
    list.sort((a, b) => _score(b).compareTo(_score(a)));
    return list;
  }

  // ---- engagement (relay-backed likes/reposts + XNO gathered per post) ----
  Map<String, dynamic> _eng(String pid) {
    final e = _engage[pid];
    return e is Map ? Map<String, dynamic>.from(e) : {'likes': 0, 'reposts': 0, 'tips_xno': 0};
  }


  String _rawOf(double xno) => '${(xno * 100).round()}${'0' * 28}'; // XNO(2dp) -> raw string

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
    if (!liked && p.account != _account && _settings.notifyLike) {
      Api.notifyPush(p.handle, _handle, 'like',
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
    if (!rp && p.account != _account) {
      Api.notifyPush(p.handle, _handle, 'repost', 'reposted your post');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard,
          content: Text('🔁 reposted — spreads to your followers; you earn a cut of its future tips')));
    }
  }

  // count one impression per post/comment per session (fire-and-forget; shows on next refresh)
  void _countView(String id) {
    if (id.isNotEmpty && _viewed.add(id)) Api.view(id);
  }

  // build a fully-wired post card (reused by the profile screen's Posts/Media tabs)
  Widget _profileCard(Post post) {
    _countView(post.id); // this card is being rendered → an impression
    final mod = _mod(post.id);
    if (mod.hide) {
      return HiddenPostTile(post: post, mod: mod, onShow: () => setState(() => _shown.add(post.id)));
    }
    return PostCard(
        post: post,
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
        onQuote: () => _quotePost(post),
        onOpenThread: () => _openThread(post),
        onOpenProfile: () => _openProfile(post.account, post.handle),
        muted: _muted.contains(post.account),
        blocked: _blocked.contains(post.account),
        bookmarked: _bookmarks.contains(post.id),
        onBookmark: () => _toggleBookmark(post),
        onPin: (post.media != null && post.media!.isNotEmpty) ? () => _pinPost(post) : null,
        onMute: post.account == _account ? null : () => _toggleMute(post.account, post.handle),
        onBlock: post.account == _account ? null : () => _toggleBlock(post.account, post.handle),
        onDelete: post.account == _account ? () => _deletePost(post) : null);   // your own posts only
  }

  // ---- threads: posts chained by reply_to ----
  Post? _postById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final p in _posts) { if (p.id == id) return p; }
    return null;
  }

  bool _inThread(Post p) =>
      (p.replyTo != null && p.replyTo!.isNotEmpty) || _posts.any((x) => x.replyTo == p.id);

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

  // root + its descendants, oldest-first (the reading order of a thread)
  List<Post> _threadChain(Post root) {
    final chain = <Post>[root];
    bool added = true;
    while (added) {
      added = false;
      final lastId = chain.last.id;
      for (final p in _posts) {
        if (p.replyTo == lastId && !chain.contains(p)) { chain.add(p); added = true; }
      }
    }
    return chain;
  }

  void _openThread(Post p) {
    final root = _threadRoot(p);
    final chain = _threadChain(root);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
          title: const Text('Thread', style: TextStyle(color: kText, fontWeight: FontWeight.w800))),
      body: ListView.separated(
        itemCount: chain.length,
        separatorBuilder: (_, __) => Container(color: kLine, height: 1),
        itemBuilder: (_, i) => _profileCard(chain[i]),
      ),
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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmInboxScreen(
      handleOf: _handleFor,
      isBlocked: (acc) => _blocked.contains(acc), // blocked people's DMs don't reach you
      onOpen: (acc, h) => _openChat(acc, h),
    )));
  }

  Future<void> _openChat(String account, String handle) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DmChatScreen(peer: account, handle: handle, myAccount: _account)));
  }

  // load our own profile into the cache on start (so avatars/name show everywhere)
  Future<void> _initProfile() async {
    if (_account.isEmpty) return;
    final p = await Api.profileGet(_account);
    if (p != null) ProfileCache.I.put(_account, p);
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
                    child: avatar.isNotEmpty
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
            Api.notifyPush(p.handle, _handle, 'comment', 'commented on your post');
          }
        },
      ),
    );
    final cs = await Api.comments(p.id);
    if (mounted) setState(() => _commentCount[p.id] = cs.length);
  }

  // tip a COMMENT: tally to the comment's author, stat on the comment's own id, notify.
  void _tallyCommentTip(Map<String, dynamic> c) {
    final amt = _settings.defaultTip;
    if (!_guardTip(amt)) return;
    final acct = (c['account'] ?? '') as String;
    final handle = (c['handle'] ?? '') as String;
    final cid = (c['cid'] ?? '') as String;
    setState(() {
      _pending[acct] = (_pending[acct] ?? 0) + amt;
      _handleOf[acct] = handle;
    });
    if (cid.isNotEmpty) Api.tipstat(cid, _rawOf(amt));
    if (acct != _account && _settings.notifyTip) {
      Api.notifyPush(handle, _handle, 'tip', 'tipped your comment ${amt.toStringAsFixed(2)} XNO');
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200),
        backgroundColor: kCard,
        content: Text('◈ +${amt.toStringAsFixed(2)} XNO tallied to @$handle (comment) — off-chain')));
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
    }
    Api.dmKeyRegister();   // publish our signed DM public key so peers can encrypt to us
    _initFollows();
    _outbox = await Outbox.load();          // restore anything queued offline in a previous session
    if (mounted) setState(() {});
    _flushOutbox();                          // and try to send it now (best-effort; no-op if offline)
    _autoCheckUpdate();                      // background: is there a newer signed release? (non-blocking)
  }

  // AUTO-UPDATE CHECK: on launch, ask the relays for a newer signed release and, if there is one the user
  // hasn't already dismissed, surface a banner. The manual wallet→"App updates" flow still exists; this
  // just means an update reaches people without them going looking for it.
  Future<void> _autoCheckUpdate() async {
    try {
      final r = await Api.releaseCheck();
      if (r == null || r['update'] != true) return;
      final v = '${r['version']}';
      if (await UpdateDismiss.get() == v) return;   // already dismissed this exact version
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
    String prev = '';
    for (int i = 0; i < segs.length; i++) {
      // A post's id is 'u<ts>' (seconds), so every segment MUST get a distinct ts — else a queued thread
      // (all segments share the job's single ts) collapses to one id and the reply chain breaks. +i keeps
      // order and makes each unique. (Also fixes a fast online thread posting >1 segment in the same second.)
      final id = await Api.post(segs[i], handle: job['handle'] as String,
          media: i == 0 ? mediaCid : '', mediaKind: i == 0 ? (job['mediaKind'] as String? ?? '') : '',
          quote: i == 0 ? (job['quote'] as String? ?? '') : '', replyTo: i == 0 ? '' : prev,
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
    if (remote.isEmpty) return;
    final union = {...local, ...remote};
    if (union.length != local.length) {
      await FollowStore.save(union);
      if (mounted) setState(() => _follows = union);
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
            ...notifs.map((n) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CircleAvatar(radius: 16, backgroundColor: avatarColor('${n['from']}'),
                        child: Text('${n['from']}'.substring(0, 1).toUpperCase(),
                            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('@${n['from']} mentioned you · ${timeAgo(n['ts'] ?? 0)}',
                          style: const TextStyle(color: kDim, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text('${n['text']}', style: const TextStyle(color: kText, fontSize: 14, height: 1.3)),
                    ])),
                  ]),
                )),
        ]),
      ),
    );
  }

  void _showWallet() {
    bool reveal = false;
    String seed = '';
    String? rep; // current representative (fetched lazily)
    bool repFetching = false;
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
                    Text('@$_handle · ${xno.toStringAsFixed(3)} XNO', style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
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
            const Text('tap to copy · share it to receive XNO from another wallet',
                style: TextStyle(color: kDim, fontSize: 11)),
            const SizedBox(height: 14),
            // Receive QR: scan with any Nano wallet to send XNO to this account (mainnet).
            Center(
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(
                    data: _account,
                    version: QrVersions.auto,
                    size: 176,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Scan to send XNO to this account · mainnet',
                    style: TextStyle(color: kDim, fontSize: 11)),
              ]),
            ),
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
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final r = await Api.receive();
                    await _load();
                    if (mounted) setSheet(() {});
                    if (!mounted) return;
                    final n = (r?['received'] ?? 0) as int;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        backgroundColor: kCard,
                        content: Text(n > 0
                            ? '⬇ claimed $n incoming block${n == 1 ? '' : 's'}'
                            : 'nothing to receive right now')));
                  },
                  style: OutlinedButton.styleFrom(foregroundColor: kText, side: const BorderSide(color: kLine)),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  label: const Text('Receive', style: TextStyle(fontWeight: FontWeight.w800)),
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
              leading: const Icon(Icons.system_update, color: kText, size: 20),
              title: const Text('App updates', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
              subtitle: const Text('signed releases over the relays · no app store', style: TextStyle(color: kDim, fontSize: 12)),
              trailing: Text('v$kAppVersion', style: const TextStyle(color: kDim, fontSize: 12, fontFamily: 'monospace')),
              onTap: () { Navigator.pop(ctx); _showUpdates(); },
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
                Text('${xno.toStringAsFixed(3)} XNO', style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
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
              Wrap(spacing: 8, children: [0.01, 0.05, 0.10, 0.25, 1.0].map((o) =>
                chip('${o.toStringAsFixed(2)} XNO', (o - _settings.defaultTip).abs() < 1e-9,
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
              toggle('Likes', 'notify the creator on a like', _settings.notifyLike, (v) => _settings.notifyLike = v),
              toggle('Comments', 'notify the creator on a comment', _settings.notifyComment, (v) => _settings.notifyComment = v),
              toggle('Tips', 'notify the creator on a tip', _settings.notifyTip, (v) => _settings.notifyTip = v),

              section('Privacy'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block, color: kText, size: 20),
                title: const Text('Muted & blocked accounts', style: TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 15)),
                subtitle: Text('${_muted.length} muted · ${_blocked.length} blocked', style: const TextStyle(color: kDim, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: kDim),
                onTap: () { Navigator.pop(ctx); _showMutedBlocked(); },
              ),

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
        return FutureBuilder<Map<String, dynamic>?>(
          future: f,
          builder: (_, snap) {
            final health = (snap.data?['health'] as List?) ?? const [];
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
          ]),
        ),
      ),
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
            final bytes = await Api.media('${rel['cid']}');      // pull the APK bytes to THIS device (via the relays)
            final want = '${rel['sha256']}';
            if (bytes == null || sha256.convert(bytes).toString() != want) {   // re-verify on-device — don't trust the transport
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
          if (Platform.isIOS) {
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
                content: Text('Couldn’t open the installer (${res.message}). Allow “Install unknown apps” for ӾChat, then tap Install again.')));
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
                  icon: Icon(Platform.isIOS ? Icons.apple : Icons.android, size: 18),
                  label: Text(Platform.isIOS ? 'Install (iOS gated)' : 'Install', style: const TextStyle(fontWeight: FontWeight.w800)),
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait(
          [Api.feed(), Api.me(), Api.labels(), Api.notify(), Api.engagement()]);
      final fd = results[0] as FeedData;
      final me = results[1] as Map<String, dynamic>;
      final labelers = results[2] as List<Labeler>;
      final notifs = results[3] as List<Map<String, dynamic>>;
      final engage = results[4] as Map<String, dynamic>;
      setState(() {
        _posts = fd.posts;
        _newPosts.clear();                    // a full refresh already includes everything
        _onchainBlocks = fd.onchainBlocks;
        _relaysUp = fd.relaysUp;
        _relaysTotal = fd.relaysTotal;
        _handle = me['handle'] ?? 'you.xno';
        _account = me['account'] ?? '';
        _balance = me['balance']?.toString() ?? '0';
        _labelers = labelers;
        _notifs = notifs;
        _engage = engage;
        _loading = false;
      });
      _syncSupporter(); // reflect current supporter state now that the account is known
      _initProfile();   // pull our own profile (name/avatar) into the cache
      _maybeSweep();    // keep only the safety-cap float here; forward the rest to savings
    } catch (e) {
      setState(() {
        _error = 'could not reach the ledger engine\n($kBase)';
        _loading = false;
      });
    }
  }

  // Auto-forward anything above the safety cap to the user's external savings address (which this
  // app holds no key for), so the most a bad app build could ever touch is the small in-app float.
  bool _sweeping = false;
  Future<void> _maybeSweep() async {
    if (_sweeping || !_settings.autoSweep) return;
    final addr = _settings.sweepAddr.trim();
    if (!addr.startsWith('nano_') || addr.length < 60 || addr == _account) return;
    final xno = (double.tryParse(_balance) ?? 0) / 1e30;
    final excess = xno - kWalletCapXno;
    if (excess <= 0.0001) return;
    _sweeping = true;
    try {
      final r = await Api.send(addr, excess.toStringAsFixed(6));
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

  Future<void> _compose({Post? quotedPost}) async {
    final res = await showModalBottomSheet<ComposeResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      builder: (_) => ComposeSheet(handle: _handle, account: _account, quotedPost: quotedPost),
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
      'mediaKind': res.mediaBytes != null ? res.mediaKind : '',
      'mediaB64': res.mediaBytes != null ? base64Encode(res.mediaBytes!) : '',
      'poll': res.pollOptions,
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
          icon: CircleAvatar(
              radius: 15,
              backgroundColor: avatarColor(_handle),
              child: Text(_handle.substring(0, 1).toUpperCase(),
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13))),
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
            icon: const Icon(Icons.mail_outline, size: 21, color: kText),
          ),
          // push wakeups: bell with unread count
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _showNotifs,
            icon: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.notifications_none, size: 21, color: kText),
              if (_notifs.isNotEmpty)
                Positioned(
                  right: -3, top: -3,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: Color(0xFFEF6C9B), shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                    child: Text('${_notifs.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          ),
          // pending tips → the settle menu (only shown when something is waiting, or a policy is on)
          if (_pending.isNotEmpty || _autoSettle)
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
                          '⛓ ${_onchainBlocks} Nano block${_onchainBlocks == 1 ? '' : 's'}  ·  ${_posts.length} posts off-chain  ·  📡 ${_relaysUp}/${_relaysTotal} relays',
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
              : _tab == 1
                  ? DiscoverScreen(
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

  Widget _homeBody() {
    final posts = _homeFeed == 0 ? _forYouPosts() : _homePosts();
    return Column(children: [
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
                // without this the list recycles cards across posts and their media gets mismatched
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
            '👋 you follow no one yet — showing everyone.\ntap Discover to find people to follow.',
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
    _load();
  }

  Future<void> _load() async {
    final c = await Api.dmInbox();
    if (mounted) setState(() {
      _convos = c.where((x) => !widget.isBlocked('${x['peer']}')).toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        title: const Text('Messages', style: TextStyle(color: kText, fontWeight: FontWeight.w800)),
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
          : _convos.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(40),
                  child: Text('No messages yet.\nOpen someone’s profile and tap Message.',
                      textAlign: TextAlign.center, style: TextStyle(color: kDim, height: 1.5))))
              : RefreshIndicator(
                  color: kAccent, backgroundColor: kCard, onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _convos.length,
                    separatorBuilder: (_, __) => Container(color: kLine, height: 1),
                    itemBuilder: (_, i) {
                      final c = _convos[i];
                      final peer = '${c['peer']}';
                      final handle = widget.handleOf(peer);
                      final msgs = (c['messages'] as List?) ?? [];
                      final last = msgs.isEmpty ? null : msgs.last as Map<String, dynamic>;
                      return ListTile(
                        onTap: () async {
                          await widget.onOpen(peer, handle);
                          _load();
                        },
                        leading: AuthorAvatar(account: peer, handle: handle, radius: 22),
                        title: AnimatedBuilder(
                          animation: ProfileCache.I,
                          builder: (_, __) => Text(ProfileCache.I.displayName(peer, handle),
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
  bool _loading = true, _sending = false;
  String? _err;
  final _ctl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() { _ctl.dispose(); super.dispose(); }

  Future<void> _load() async {
    final convos = await Api.dmInbox();
    final mine = convos.firstWhere((c) => c['peer'] == widget.peer, orElse: () => {});
    if (mounted) setState(() {
      _msgs = ((mine['messages'] as List?) ?? []).cast<Map<String, dynamic>>();
      _loading = false;
    });
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    setState(() { _sending = true; _err = null; });
    final r = await Api.dmSend(widget.peer, text);
    if (!mounted) return;
    if (r != null && r['ok'] == true) {
      _ctl.clear();
      await _load();
      setState(() => _sending = false);
    } else {
      setState(() { _sending = false; _err = (r?['error'] ?? 'send failed').toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0, iconTheme: const IconThemeData(color: kText),
        titleSpacing: 0,
        title: Row(children: [
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
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: kAccent))
              : _msgs.isEmpty
                  ? const Center(child: Text('No messages yet — say hi 🔐', style: TextStyle(color: kDim)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: _msgs.length,
                      itemBuilder: (_, i) => _bubble(_msgs[i]),
                    ),
        ),
        if (_err != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(_err!, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12.5))),
        _composer(),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final out = m['outgoing'] == true;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: out ? kAccent : kCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16), topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(out ? 16 : 4), bottomRight: Radius.circular(out ? 4 : 16)),
        ),
        child: Text('${m['text']}',
            style: TextStyle(color: out ? Colors.black : kText, fontSize: 15, height: 1.3)),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: const BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kLine))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              style: const TextStyle(color: kText, fontSize: 15),
              minLines: 1, maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: 'Encrypted message…',
                hintStyle: TextStyle(color: kDim), border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
            ),
          ),
          _sending
              ? const Padding(padding: EdgeInsets.all(10),
                  child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
              : IconButton(onPressed: _send, icon: const Icon(Icons.send, color: kAccent)),
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
    final mine = widget.allPosts.where((p) => p.account == widget.account).toList();
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
                          child: avatar.isNotEmpty
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
                        Text('@${widget.handle}', style: const TextStyle(color: kDim, fontSize: 14)),
                        if (bio.isNotEmpty) Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(bio, style: const TextStyle(color: kText, fontSize: 14.5, height: 1.4)),
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          _count(following, 'Following'),
                          const SizedBox(width: 20),
                          _count(followers, 'Followers'),
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
                (_, i) => Column(children: [Container(color: kLine, height: 1), widget.cardBuilder(shown[i])]),
                childCount: shown.length,
              )),
            ]),
    );
  }

  Widget _count(int n, String label) => Row(children: [
        Text('$n', style: const TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: kDim, fontSize: 14)),
      ]);

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

class DiscoverScreen extends StatefulWidget {
  final List<Post> posts;
  final List<Map<String, String>> authors;
  final Set<String> follows, liked, reposted;
  final Map<String, dynamic> engage;
  final void Function(String account) onToggleFollow;
  final double Function(String account) pendingOf;
  final int Function(String postId) commentCountOf;
  final void Function(Post) onTipPost, onLikePost, onRepostPost, onReportPost, onCommentPost;
  final void Function(String account, String handle) onOpenProfile;
  const DiscoverScreen(
      {super.key,
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
          _section(q.isEmpty ? 'People · top earners' : 'People (${people.length})'),
          ...people.map((a) => _person(a['account']!, a['handle']!)),
          if (q.isNotEmpty) ...[
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
  final VoidCallback? onOpenProfile, onQuote, onOpenThread, onMute, onBlock, onBookmark, onPin, onDelete;
  final bool muted, blocked, bookmarked;
  final Post? quoted; // resolved quoted post (for a quote-post), rendered inline
  final bool inThread; // part of an author thread → show a thread affordance
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
      this.onMute,
      this.onBlock,
      this.onBookmark,
      this.onPin,
      this.onDelete,
      this.muted = false,
      this.blocked = false,
      this.bookmarked = false,
      this.quoted,
      this.inThread = false,
      this.repostedBy = ''});
  static void _noop() {}
  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _expanded = false;
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
              const SizedBox(width: 6),
              Text('· ${timeAgo(p.ts)}', style: const TextStyle(color: kDim, fontSize: 13)),
              const Spacer(),
              if (widget.softFlag != null && widget.softFlag!.flaggers.isNotEmpty) ...[
                _SoftFlag(mod: widget.softFlag!),
                const SizedBox(width: 6),
              ],
              if (p.kind != 'post') _KindBadge(kind: p.kind),
              InkWell(
                onTap: () => _menu(context),
                child: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.more_horiz, size: 18, color: kDim)),
              ),
            ]),
            const SizedBox(height: 3),
            if (p.kind == 'article' && p.title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(p.title!,
                    style: const TextStyle(color: kText, fontWeight: FontWeight.w700, fontSize: 16, height: 1.3)),
              ),
            Text(p.text,
                maxLines: (longText && !_expanded) ? 6 : null,
                overflow: (longText && !_expanded) ? TextOverflow.ellipsis : TextOverflow.clip,
                style: const TextStyle(color: kText, fontSize: 15, height: 1.35)),
            if (longText)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_expanded ? 'Show less' : 'Show more',
                      style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            // photo / GIF attachment (Image.memory animates GIFs)
            if (p.kind == 'photo' && p.media != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: SizedBox(width: double.infinity, child: MediaImage(cid: p.media!, fit: BoxFit.cover)),
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
            // thread affordance
            if (widget.inThread)
              GestureDetector(
                onTap: widget.onOpenThread,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    const Text('🧵 ', style: TextStyle(fontSize: 13)),
                    Text(p.replyTo != null ? 'Part of a thread' : 'Show this thread',
                        style: const TextStyle(color: kAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            const SizedBox(height: 8),
            _Actions(
              likes: (e['likes'] ?? 0) as int,
              reposts: (e['reposts'] ?? 0) as int,
              comments: widget.commentCount,
              tipsXno: ((e['tips_xno'] ?? 0) as num).toDouble(),
              liked: widget.liked,
              reposted: widget.reposted,
              pending: widget.pending,
              views: (e['views'] ?? 0) as int,
              onComment: widget.onComment,
              onLike: widget.onLike,
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
          if (widget.onBookmark != null)
            ListTile(
              leading: Icon(widget.bookmarked ? Icons.bookmark : Icons.bookmark_border, color: kAccent),
              title: Text(widget.bookmarked ? 'Remove bookmark' : 'Bookmark',
                  style: const TextStyle(color: kText, fontWeight: FontWeight.w600)),
              subtitle: const Text('save privately to read later — never published',
                  style: TextStyle(color: kDim, fontSize: 11)),
              onTap: () { Navigator.pop(context); widget.onBookmark!(); },
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
  const MediaImage({super.key, required this.cid, this.fit = BoxFit.cover});
  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  static final Map<String, Uint8List> _cache = {};   // CID -> bytes, shared app-wide (bounded)
  static const int _cacheMax = 48;
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
    final hit = _cache[cid];
    if (hit != null) { setState(() { _bytes = hit; _loading = false; }); return; }
    setState(() => _loading = true);
    final data = await Api.media(cid);
    if (!mounted || cid != widget.cid) return;   // widget moved to a different CID → drop this result
    if (data != null) {
      _cache[cid] = data;
      if (_cache.length > _cacheMax) _cache.remove(_cache.keys.first);  // evict oldest
    }
    setState(() { _bytes = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) return Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true);
    // loading → spinner (reads as loading, not broken); resolved-but-null → a plain dark tile
    return Container(
      color: kCard,
      child: _loading
          ? const Center(
              child: SizedBox(width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kDim)))
          : null,
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
            child: post.thumb != null ? MediaImage(cid: post.thumb!) : Container(color: kCard),
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

class _Actions extends StatelessWidget {
  final int likes, reposts, comments, views;
  final double tipsXno, pending;
  final bool liked, reposted;
  final VoidCallback onLike, onRepost, onTip;
  final VoidCallback? onComment, onQuote;
  const _Actions(
      {required this.likes,
      required this.reposts,
      required this.tipsXno,
      required this.liked,
      required this.reposted,
      required this.onLike,
      required this.onRepost,
      required this.onTip,
      this.comments = 0,
      this.views = 0,
      this.onComment,
      this.onQuote,
      this.pending = 0});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _act(Icons.chat_bubble_outline, comments > 0 ? '$comments' : '', kDim, onComment),
        Builder(builder: (ctx) => _act(Icons.repeat, reposts > 0 ? '$reposts' : '',
            reposted ? const Color(0xFF4DD0A7) : kDim,
            onQuote == null ? onRepost : () => _repostMenu(ctx))),
        _act(liked ? Icons.thumb_up : Icons.thumb_up_outlined, likes > 0 ? '$likes' : '',
            liked ? kAccent : kDim, onLike),
        // views (impressions) — non-interactive, like X's view counter
        _act(Icons.bar_chart, views > 0 ? _compact(views) : '', kDim, null),
        // XNO this post has gathered
        if (tipsXno > 0)
          Row(children: [
            const XnoGlyph(size: 13, color: Color(0xFF4DD0A7), weight: 0.18),
            const SizedBox(width: 4),
            Text(tipsXno.toStringAsFixed(2),
                style: const TextStyle(color: Color(0xFF4DD0A7), fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        // the tip action carries the Ӿ mark — payments are native XNO
        InkWell(
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

  Widget _act(IconData icon, String label, Color color, VoidCallback? onTap) {
    return InkWell(
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
    );
  }
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
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
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
  ComposeResult(this.segments, this.quote,
      {this.title = '', this.pollOptions = const [], this.mediaBytes, this.mediaKind = ''});
}

class ComposeSheet extends StatefulWidget {
  final String handle, account;
  final Post? quotedPost; // when set, this is a quote-post embedding that post
  const ComposeSheet({super.key, required this.handle, required this.account, this.quotedPost});
  @override
  State<ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<ComposeSheet> {
  final List<TextEditingController> _cs = [TextEditingController()];
  final _titleCtl = TextEditingController();
  final List<TextEditingController> _pollOpts = [TextEditingController(), TextEditingController()];
  bool _article = false, _poll = false;
  Uint8List? _mediaBytes;   // attached photo/GIF/video
  String _mediaKind = '';   // 'photo' | 'movie'
  final _picker = ImagePicker();

  bool get _isQuote => widget.quotedPost != null;
  bool get _isThread => _cs.length > 1;
  bool get _hasMedia => _mediaBytes != null;

  Future<void> _attach(bool video) async {
    final x = video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    // relay pin cap is ~6 MB — refuse larger so the blob actually survives
    if (bytes.length > 6 * 1024 * 1024) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: kCard, content: Text('too large — attachments cap at 6 MB (relay pin limit)')));
      return;
    }
    setState(() { _mediaBytes = bytes; _mediaKind = video ? 'movie' : 'photo'; });
  }

  @override
  void dispose() {
    for (final c in _cs) { c.dispose(); }
    for (final c in _pollOpts) { c.dispose(); }
    _titleCtl.dispose();
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
        mediaBytes: _mediaBytes, mediaKind: _mediaKind));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final btnLabel = _isQuote ? 'Quote' : (_article ? 'Publish' : (_isThread ? 'Post all' : 'Post'));
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
                onPressed: () => _attach(false),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.image_outlined, size: 21, color: kAccent),
                tooltip: 'Photo / GIF',
              ),
              IconButton(
                onPressed: () => _attach(true),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.videocam_outlined, size: 21, color: kAccent),
                tooltip: 'Video',
              ),
            ],
            const Spacer(),
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
                for (int i = 0; i < segCount; i++)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Column(children: [
                      AuthorAvatar(account: widget.account, handle: widget.handle, radius: 20),
                      if (i < _cs.length - 1) Expanded(child: Container(width: 2, color: kLine, margin: const EdgeInsets.symmetric(vertical: 4))),
                    ]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _cs[i],
                        autofocus: i == 0 && !_article,
                        maxLines: null,
                        minLines: _article ? 6 : (i == 0 ? 3 : 1),
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
                  ]),
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
