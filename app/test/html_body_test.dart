// The sanitised HTML article renderer (HtmlBody) — what a channel article's rich body is allowed to
// become on screen. Channel articles are UNTRUSTED (anyone can publish one), so the renderer is an
// allowlist: it must render the safe formatting tags and must NOT surface active/embedded content or
// fetch a remote image on-device (that would hand the reader's IP to a stranger's server).
//
// These pump the real HtmlBody widget and read the rendered widget/text tree, so they test what the
// reader actually sees — not the source of the sanitiser.
//
//   cd app && flutter test test/html_body_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/main.dart';

Future<void> _pump(WidgetTester t, String html) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: HtmlBody(html))),
  ));
  await t.pump();
}

/// Collect the text of every Text/RichText in the tree, so an assertion can look for content that the
/// renderer flattened into spans (findsOneWidget by string won't match text inside a RichText).
String _allText(WidgetTester t) {
  final buf = StringBuffer();
  for (final e in find.byType(RichText).evaluate()) {
    final rt = e.widget as RichText;
    buf.write(rt.text.toPlainText());
    buf.write('\n');
  }
  for (final e in find.byType(Text).evaluate()) {
    final tw = e.widget as Text;
    buf.write(tw.data ?? '');
    buf.write('\n');
  }
  return buf.toString();
}

/// The first RichText whose flattened text contains [needle].
RichText tester_firstRichTextContaining(WidgetTester t, String needle) {
  for (final e in find.byType(RichText).evaluate()) {
    final rt = e.widget as RichText;
    if (rt.text.toPlainText().contains(needle)) return rt;
  }
  throw StateError('no RichText containing "$needle"');
}

/// The colour of the first text span whose text contains [needle], searching every RichText.
Color? _spanColor(WidgetTester t, String needle) {
  Color? found;
  void walk(InlineSpan span) {
    if (found != null) return;
    if (span is TextSpan) {
      if ((span.text ?? '').contains(needle)) {
        found = span.style?.color;
        return;
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  for (final e in find.byType(RichText).evaluate()) {
    walk((e.widget as RichText).text);
    if (found != null) break;
  }
  return found;
}

void main() {
  group('HtmlBody.looksLikeHtml', () {
    test('detects HTML, leaves plain markdown alone', () {
      expect(HtmlBody.looksLikeHtml('<p>hello <b>world</b></p>'), isTrue);
      expect(HtmlBody.looksLikeHtml('<h2>Title</h2>'), isTrue);
      expect(HtmlBody.looksLikeHtml('# A markdown heading\n\n- a\n- b'), isFalse);
      expect(HtmlBody.looksLikeHtml('just some plain text, 3 < 4 and 5 > 1'), isFalse);
    });
  });

  testWidgets('renders headings, paragraphs and inline emphasis', (t) async {
    await _pump(t, '<h1>Fuels report</h1><p>Now with <b>bold</b> and <i>italic</i> text.</p>');
    final text = _allText(t);
    expect(text, contains('Fuels report'));
    expect(text, contains('bold'));
    expect(text, contains('italic'));
  });

  testWidgets('renders list items with bullets', (t) async {
    await _pump(t, '<ul><li>First</li><li>Second</li></ul>');
    final text = _allText(t);
    expect(text, contains('First'));
    expect(text, contains('Second'));
    expect(text, contains('•')); // bullet glyph rendered by the list builder
  });

  testWidgets('renders ordered list numbering', (t) async {
    await _pump(t, '<ol><li>alpha</li><li>beta</li></ol>');
    final text = _allText(t);
    expect(text, contains('1.'));
    expect(text, contains('2.'));
    expect(text, contains('beta'));
  });

  testWidgets('DROPS a <script> tag entirely — no code leaks as text', (t) async {
    await _pump(t, '<p>Safe intro.</p><script>alert("xss")</script><p>Safe outro.</p>');
    final text = _allText(t);
    expect(text, contains('Safe intro.'));
    expect(text, contains('Safe outro.'));
    expect(text, isNot(contains('alert')));   // script contents must not render
    expect(text, isNot(contains('xss')));
  });

  testWidgets('DROPS an <iframe> and a <form>', (t) async {
    await _pump(t, '<iframe src="https://evil.example/track"></iframe>'
        '<form action="https://evil.example"><input value="secret"></form><p>Body.</p>');
    final text = _allText(t);
    expect(text, contains('Body.'));
    expect(text, isNot(contains('evil.example')));
    expect(text, isNot(contains('secret')));
  });

  testWidgets('a remote <img> becomes a tap-to-open card, not an on-device fetch', (t) async {
    await _pump(t, '<p>Look:</p><img src="https://tracker.example/pixel.png" alt="a pixel">');
    // The remote path must NOT build an Image (no on-device network fetch) and must NOT go through
    // MediaImage (that's the content-addressed path). It shows a card instead.
    expect(find.byType(Image), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    final text = _allText(t);
    expect(text, contains('Remote image · tap to open in browser'));
    expect(text, contains('a pixel')); // alt text is shown on the card
  });

  testWidgets('a content-addressed <img> renders through MediaImage', (t) async {
    await _pump(t, '<img src="cid:abc123" alt="chart">');
    expect(find.byType(MediaImage), findsOneWidget);
  });

  testWidgets('a javascript: link is stripped to plain text (no tap target)', (t) async {
    await _pump(t, '<p>Click <a href="javascript:steal()">here</a> now.</p>');
    final text = _allText(t);
    expect(text, contains('here'));       // the label survives
    expect(text, isNot(contains('steal'))); // the scheme/payload never appears
  });

  testWidgets('empty / non-HTML input still shows its text', (t) async {
    await _pump(t, 'plain text body');
    expect(_allText(t), contains('plain text body'));
  });

  testWidgets('renders a <table> as a real grid', (t) async {
    await _pump(t,
        '<table><thead><tr><th>Fuel</th><th>Yield</th></tr></thead>'
        '<tbody><tr><td>HVO</td><td>92%</td></tr><tr><td>SAF</td><td>70%</td></tr></tbody></table>');
    expect(find.byType(Table), findsOneWidget);
    final text = _allText(t);
    expect(text, contains('Fuel'));
    expect(text, contains('HVO'));
    expect(text, contains('92%'));
    expect(text, contains('SAF'));
  });

  testWidgets('a padded (uneven) table row does not throw', (t) async {
    // second row has one cell, header has two — must be padded, not crash.
    await _pump(t, '<table><tr><th>A</th><th>B</th></tr><tr><td>only</td></tr></table>');
    expect(find.byType(Table), findsOneWidget);
    expect(_allText(t), contains('only'));
  });

  testWidgets('honours text-align:center on a paragraph', (t) async {
    await _pump(t, '<p style="text-align:center">Centered line</p>');
    final rt = tester_firstRichTextContaining(t, 'Centered line');
    expect(rt.textAlign, TextAlign.center);
  });

  testWidgets('inline color via style is applied', (t) async {
    await _pump(t, '<p>plain <span style="color:#e0245e">tinted</span> word</p>');
    // find the span carrying the tinted text and check its colour
    final found = _spanColor(t, 'tinted');
    expect(found, const Color(0xFFE0245E));
  });

  testWidgets('a callout aside renders its text in a box', (t) async {
    await _pump(t, '<aside class="warning"><p>Heads up.</p></aside>');
    expect(_allText(t), contains('Heads up.'));
    // the callout wraps its content in a decorated Container
    expect(find.byType(Container), findsWidgets);
  });

  testWidgets('figcaption text renders (caption styling)', (t) async {
    await _pump(t, '<figure><img src="cid:abc"><figcaption>Figure 1. A chart.</figcaption></figure>');
    expect(_allText(t), contains('Figure 1. A chart.'));
    expect(find.byType(MediaImage), findsOneWidget);
  });

  group('articleExcerpt (feed-card preview)', () {
    test('strips HTML tags to clean text', () {
      final ex = articleExcerpt('<h1>Biofuels Briefing</h1><p>This is <b>bold</b> and more.</p>');
      expect(ex, 'Biofuels Briefing This is bold and more.');
      expect(ex, isNot(contains('<')));
      expect(ex, isNot(contains('>')));
    });

    test('drops a <script> from the excerpt too', () {
      final ex = articleExcerpt('<p>Intro.</p><script>alert(1)</script>');
      expect(ex, contains('Intro.'));
      expect(ex, isNot(contains('alert')));
    });

    test('strips common markdown marks', () {
      final ex = articleExcerpt('# Heading\n\nSome **bold** and _italic_ text.\n> a quote');
      expect(ex, isNot(contains('#')));
      expect(ex, isNot(contains('*')));
      expect(ex, contains('bold'));
      expect(ex, contains('a quote'));
    });
  });
}
