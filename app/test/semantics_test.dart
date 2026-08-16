// What a screen reader is actually told about a post.
//
// Before this, the answer was "almost nothing": the app contained zero Semantics widgets, so the six
// controls under every post — reply, repost, like, views, tips, tip — were an unlabelled icon each,
// and the counts beside them were loose digits with no noun. "3" is not "3 replies", and the Ӿ tip
// button is a custom painter with no text in it at all, which made the one control that moves money
// the most silent thing on the card.
//
// These assertions read the REAL semantics tree that Flutter hands to Android's accessibility layer,
// not the presence of a Semantics widget in the source. The difference matters: wrapping a widget in
// Semantics while leaving its children visible to the tree produces a label followed by the same
// information again as fragments, which is worse than the label alone.
//
// (uiautomator would have tested the same tree on a device, but this app never reaches the idle
// state its dump requires — the update banner marquees and the live avatars animate continuously.)
//
//   cd app && flutter test test/semantics_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart';

Post _post({String text = 'hello', String handle = 'alice', int likes = 0, int reposts = 0}) =>
    Post('p1', handle, 'nano_1abc', 'post', text, null, null, null, null, 1786899000, likes, reposts);

Future<void> _pump(WidgetTester t, Widget child) async {
  await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await t.pump();
}

/// Every label in the rendered semantics tree.
List<String> _labels(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    final l = n.label.trim();
    if (l.isNotEmpty) out.add(l);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return out;
}

bool _has(List<String> ls, String needle) => ls.any((l) => l.contains(needle));

void main() {
  testWidgets('the actions under a post are named, not just tappable', (t) async {
    final handle = t.ensureSemantics();
    // Counts come from the engagement map, not the Post — the card renders what the feed aggregated.
    await _pump(t, PostCard(post: _post(), replyCount: 1, onTip: () {},
        engage: const {'likes': 3, 'reposts': 2, 'views': 12, 'tips_xno': 0.25}));
    final ls = _labels(t);

    // Singular and plural, because "1 replies" is the tell that a count was pasted onto a label.
    expect(_has(ls, '1 reply'), isTrue, reason: 'reply count unlabelled: $ls');
    expect(_has(ls, '2 reposts'), isTrue, reason: 'repost count unlabelled: $ls');
    expect(_has(ls, '3 likes'), isTrue, reason: 'like count unlabelled: $ls');
    expect(_has(ls, '12 views'), isTrue, reason: 'view count unlabelled: $ls');
    expect(_has(ls, '0.25 XNO tipped'), isTrue, reason: 'the tip total is unlabelled: $ls');
    // The one that moves money, and the one that had no text in it whatsoever.
    expect(_has(ls, 'Tip this post'), isTrue, reason: 'the tip button is silent: $ls');
    handle.dispose();
  });

  testWidgets('a count of zero reads as the ACTION, not as "0"', (t) async {
    final handle = t.ensureSemantics();
    await _pump(t, PostCard(post: _post(), onTip: () {}));
    final ls = _labels(t);
    expect(_has(ls, 'Reply'), isTrue);
    expect(_has(ls, 'Like'), isTrue);
    expect(_has(ls, 'Repost'), isTrue);
    // "0 likes" is noise on every post in a quiet feed; the control's name is the useful thing.
    expect(_has(ls, '0 likes'), isFalse, reason: 'announcing zero on every post: $ls');
    handle.dispose();
  });

  testWidgets('state that is carried only by COLOUR is said out loud', (t) async {
    // liked and reposted are signalled by tinting the icon. That is unreachable without sight, so it
    // has to be in the label or it does not exist for a screen-reader user.
    final handle = t.ensureSemantics();
    await _pump(t, PostCard(post: _post(), liked: true, reposted: true, onTip: () {},
        engage: const {'likes': 1, 'reposts': 1}));
    final ls = _labels(t);
    expect(_has(ls, 'liked by you'), isTrue, reason: 'like state invisible: $ls');
    expect(_has(ls, 'reposted by you'), isTrue, reason: 'repost state invisible: $ls');
    handle.dispose();
  });

  testWidgets('the overflow menu says what it opens', (t) async {
    final handle = t.ensureSemantics();
    await _pump(t, PostCard(post: _post(), onTip: () {}));
    // '...' is the least guessable control on the card and was completely unnamed.
    expect(_has(_labels(t), 'More actions for this post'), isTrue);
    handle.dispose();
  });

  testWidgets('an avatar names whose it is, in every one of its three forms', (t) async {
    final handle = t.ensureSemantics();
    // No profile is cached here, so this renders the initial-letter fallback — which without a label
    // announces as a lone capital 'A'.
    await _pump(t, const AuthorAvatar(account: 'nano_1abc', handle: 'alice'));
    expect(_has(_labels(t), 'Avatar of alice'), isTrue, reason: _labels(t).toString());
    handle.dispose();
  });

  testWidgets('a label replaces its children rather than being read alongside them', (t) async {
    // The failure this guards: Semantics() wrapping a subtree whose children stay visible, so the
    // reader hears "3 likes" and then, separately, "3". ExcludeSemantics is what prevents it, and
    // it is easy to drop in a later edit.
    final handle = t.ensureSemantics();
    await _pump(t, PostCard(post: _post(), onTip: () {}, engage: const {'likes': 3}));
    final bare = _labels(t).where((l) => l == '3').length;
    expect(bare, 0, reason: 'the raw count leaked into the tree beside its label: ${_labels(t)}');
    handle.dispose();
  });
}
