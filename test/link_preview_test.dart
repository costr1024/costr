// Pure-function tests for the link-preview / URL-classification service
// (lib/services/link_preview.dart): content-type classification, Open Graph
// parsing (incl. anti-bot-wall degradation), candidate extraction, SSRF host
// guards, and inspectUrl's redirect/guard flow against a fake http client.
import 'dart:convert';

import 'package:costr/services/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('classifyContentType', () {
    test('image / video / html / other', () {
      expect(classifyContentType('image/jpeg'), UrlContentKind.image);
      expect(classifyContentType('IMAGE/PNG'), UrlContentKind.image);
      expect(classifyContentType('video/mp4'), UrlContentKind.video);
      expect(
        classifyContentType('video/mp4; charset=binary'),
        UrlContentKind.video,
      );
      expect(
        classifyContentType('text/html; charset=utf-8'),
        UrlContentKind.html,
      );
      expect(classifyContentType('application/xhtml+xml'), UrlContentKind.html);
      expect(classifyContentType('application/pdf'), UrlContentKind.other);
      expect(classifyContentType('application/json'), UrlContentKind.other);
      expect(classifyContentType(null), UrlContentKind.other);
    });
  });

  group('parseLinkPreview', () {
    final page = Uri.parse('https://www.example.com/article?id=1');

    test('full Open Graph set (Bing-search shape)', () {
      const html = '''
<html><head>
<meta property="og:title" content="普通蓝灰蝶 - 必应" />
<meta property="og:description" content="通过必应的智能搜索，可以更轻松地查找内容。" />
<meta property="og:image" content="http://www.bing.com/sa/simg/share.png" />
<meta property="og:site_name" content="必应" />
<title>普通蓝灰蝶 - 搜索</title>
</head><body></body></html>''';
      final p = parseLinkPreview(html, page);
      expect(p.title, '普通蓝灰蝶 - 必应');
      expect(p.description, '通过必应的智能搜索，可以更轻松地查找内容。');
      expect(p.imageUrl, 'http://www.bing.com/sa/simg/share.png');
      expect(p.siteName, '必应');
      expect(p.domain, 'example.com'); // www. stripped
    });

    test('attribute order reversed (content before property)', () {
      const html = '<head><meta content="倒序标题" name="og:title"></head>';
      // NOTE: og:title via `name=` is nonstandard but seen in the wild;
      // the parser accepts both property= and name=.
      final p = parseLinkPreview(html, page);
      expect(p.title, '倒序标题');
    });

    test('twitter fallbacks when og: missing', () {
      const html = '''
<head>
<meta name="twitter:title" content="推特标题" />
<meta name="twitter:description" content="推特描述" />
<meta name="twitter:image" content="/tw.png" />
</head>''';
      final p = parseLinkPreview(html, page);
      expect(p.title, '推特标题');
      expect(p.description, '推特描述');
      // Relative image resolved against the page URL.
      expect(p.imageUrl, 'https://www.example.com/tw.png');
    });

    test('<title> + meta description fallback when no og/twitter', () {
      const html = '''
<head>
<meta name="description" content="普通描述" />
<title>页面标题 &amp; 更多</title>
</head>''';
      final p = parseLinkPreview(html, page);
      expect(p.title, '页面标题 & 更多');
      expect(p.description, '普通描述');
      expect(p.imageUrl, isNull);
    });

    test('og:image:secure_url fallback', () {
      const html =
          '<head><meta property="og:image:secure_url" content="https://cdn.example/i.png"></head>';
      expect(
        parseLinkPreview(html, page).imageUrl,
        'https://cdn.example/i.png',
      );
    });

    test('numeric entities unescaped', () {
      const html = '<head><title>A&#66;&#x43;</title></head>';
      expect(parseLinkPreview(html, page).title, 'ABC');
    });

    test('first occurrence wins on duplicate og:title', () {
      const html =
          '<head><meta property="og:title" content="第一个"><meta property="og:title" content="第二个"></head>';
      expect(parseLinkPreview(html, page).title, '第一个');
    });

    test('anti-bot wall title drops title AND description (weibo case)', () {
      const html = '''
<head>
<title>Sina Visitor System</title>
<meta name="description" content="正在使用微博访问方式" />
</head>''';
      final p = parseLinkPreview(html, page);
      expect(p.title, isNull);
      expect(p.description, isNull);
      expect(p.domain, 'example.com'); // domain-only card still renders
    });

    test('no metadata at all still yields domain', () {
      final p = parseLinkPreview('<html></html>', page);
      expect(p.title, isNull);
      expect(p.description, isNull);
      expect(p.imageUrl, isNull);
      expect(p.domain, 'example.com');
    });
  });

  group('unescapeHtml', () {
    test('named, decimal, hex, unknown passthrough', () {
      expect(unescapeHtml('a &amp; b &lt;c&gt;'), 'a & b <c>');
      expect(unescapeHtml('&quot;q&quot; &apos;s&apos;'), '"q" \'s\'');
      expect(unescapeHtml('&#20013;&#25991;'), '中文');
      expect(unescapeHtml('&#x4e2d;&#x6587;'), '中文');
      expect(unescapeHtml('&unknown; stays'), '&unknown; stays');
      expect(unescapeHtml('no entities'), 'no entities');
    });
  });

  group('isJunkTitle', () {
    test('walls match, real titles do not', () {
      expect(isJunkTitle('Sina Visitor System'), isTrue);
      expect(isJunkTitle('Just a moment...'), isTrue);
      expect(isJunkTitle('验证码拦截'), isTrue);
      expect(isJunkTitle('普通蓝灰蝶 - 搜索'), isFalse);
      expect(isJunkTitle(''), isFalse);
    });
  });

  group('isBlockedProbeHost', () {
    test('private/loopback/link-local literals blocked', () {
      for (final h in const [
        '127.0.0.1',
        '10.1.2.3',
        '192.168.0.1',
        '172.16.0.1',
        '172.31.255.255',
        '169.254.169.254', // cloud metadata
        '100.64.0.1',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '[::1]',
        'fd12::1',
        'fc00::1',
        'fe80::1',
        '::ffff:192.168.0.1',
        'localhost',
        '',
      ]) {
        expect(isBlockedProbeHost(h), isTrue, reason: h);
      }
    });

    test('public hosts allowed', () {
      for (final h in const [
        'example.com',
        '8.8.8.8',
        '172.32.0.1', // just outside 172.16/12
        '100.128.0.1', // just outside CGNAT
        'm.weibo.cn',
        '2001:4860:4860::8888',
      ]) {
        expect(isBlockedProbeHost(h), isFalse, reason: h);
      }
    });
  });

  group('trimUrlPunctuation / displayDomain', () {
    test('trailing punctuation trimmed, inner kept', () {
      expect(trimUrlPunctuation('https://x/a?id=1。'), 'https://x/a?id=1');
      expect(trimUrlPunctuation('https://x/a.'), 'https://x/a');
      expect(trimUrlPunctuation('https://x/a?b=1'), 'https://x/a?b=1');
      expect(trimUrlPunctuation('https://x/a，对吧'), 'https://x/a，对吧');
    });

    test('displayDomain strips www.', () {
      expect(displayDomain('https://www.weibo.cn/x'), 'weibo.cn');
      expect(displayDomain('https://m.weibo.cn/detail/1'), 'm.weibo.cn');
    });
  });

  group('extractPreviewCandidates', () {
    test('basic extraction, dedupe, order', () {
      const text =
          '先看 https://b.example/2 再看 https://a.example/1 重复 '
          'https://a.example/1';
      expect(extractPreviewCandidates(text), [
        'https://b.example/2',
        'https://a.example/1',
      ]);
    });

    test('cap at 4', () {
      final text = List.generate(6, (i) => 'https://e.example/$i').join(' ');
      expect(extractPreviewCandidates(text).length, 4);
    });

    test('media/file-extension URLs excluded (tokenizer owns them)', () {
      const text =
          'a https://x/i.jpg b https://x/v.mp4?sign=1 c https://x/f.pdf '
          'd https://x/page?q=1';
      expect(extractPreviewCandidates(text), ['https://x/page?q=1']);
    });

    test('markdown link targets excluded', () {
      const text = '[点这里](https://x/linked) 和裸链 https://x/bare';
      expect(extractPreviewCandidates(text), ['https://x/bare']);
    });

    test('exclude set (tag-declared attachments) honored', () {
      const text = 'https://x/a 和 https://x/b';
      expect(extractPreviewCandidates(text, exclude: const {'https://x/a'}), [
        'https://x/b',
      ]);
    });

    test(
      'extensionless query-format image URL IS a candidate (probe decides)',
      () {
        const text =
            'https://ci.xiaohongshu.com/notes/abc?imageView2/2/w/0/format/jpg';
        expect(extractPreviewCandidates(text), [text]);
      },
    );

    test('trailing Chinese punctuation trimmed', () {
      expect(extractPreviewCandidates('看这个：https://x/a。'), ['https://x/a']);
    });
  });

  group('inspectUrl (fake client)', () {
    test('image content-type → UrlImage, body not needed', () async {
      final client = MockClient(
        (req) async => http.Response.bytes(
          const [0xFF, 0xD8, 0xFF],
          200,
          headers: const {'content-type': 'image/jpeg'},
        ),
      );
      final r = await inspectUrl(
        'https://ci.xiaohongshu.com/n/abc?imageView2/2/w/0/format/jpg',
        client: client,
      );
      expect(r, isA<UrlImage>());
      expect(
        (r as UrlImage).url,
        'https://ci.xiaohongshu.com/n/abc?imageView2/2/w/0/format/jpg',
      );
    });

    test('video content-type → UrlVideo', () async {
      final client = MockClient(
        (req) async => http.Response.bytes(
          const [],
          200,
          headers: const {'content-type': 'video/mp4'},
        ),
      );
      final r = await inspectUrl('https://x/v', client: client);
      expect(r, isA<UrlVideo>());
    });

    test('html → UrlWebpage with parsed og', () async {
      final client = MockClient(
        (req) async => http.Response(
          '<head><meta property="og:title" content="标题"></head><body>x</body>',
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        ),
      );
      final r = await inspectUrl('https://x/page', client: client);
      final w = r as UrlWebpage;
      expect(w.preview.title, '标题');
      expect(w.preview.domain, 'x');
    });

    test(
      'one redirect hop followed; final URL used for relative image',
      () async {
        final client = MockClient((req) async {
          if (req.url.toString() == 'https://x/start') {
            return http.Response(
              '',
              302,
              headers: const {'location': 'https://final.example/page'},
            );
          }
          return http.Response(
            '<head><meta property="og:image" content="/img.png"></head>',
            200,
            headers: const {'content-type': 'text/html'},
          );
        });
        final r = await inspectUrl('https://x/start', client: client);
        final w = r as UrlWebpage;
        expect(w.preview.pageUrl, 'https://final.example/page');
        expect(w.preview.imageUrl, 'https://final.example/img.png');
        // The card's domain line shows the LINKED host, not the redirect
        // target (weibo bounces probes to visitor.passport.weibo.cn).
        expect(w.preview.domain, 'x');
      },
    );

    test('404 → UrlNone', () async {
      final client = MockClient((req) async => http.Response('nope', 404));
      expect(
        await inspectUrl('https://x/gone', client: client),
        isA<UrlNone>(),
      );
    });

    test('private-IP host refused without any request', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      expect(
        await inspectUrl('http://192.168.0.1/admin', client: client),
        isA<UrlNone>(),
      );
      expect(called, isFalse);
    });

    test('redirect to a private host is refused', () async {
      final client = MockClient(
        (req) async => http.Response(
          '',
          302,
          headers: const {'location': 'http://169.254.169.254/latest'},
        ),
      );
      expect(
        await inspectUrl('https://x/bounce', client: client),
        isA<UrlNone>(),
      );
    });

    test('non-http(s) scheme refused', () async {
      expect(await inspectUrl('ftp://x/f'), isA<UrlNone>());
    });

    test(
      'body capped mid multi-byte char does not throw (charset=utf-8)',
      () async {
        // The body cap can cut a UTF-8 sequence in half; the strict decoder
        // used to throw and kill the probe. Full og: head, then a truncated
        // 中 (E4 B8 AD → only E4 B8 sent), then a tiny cap.
        final head = '<head><meta property="og:title" content="ok"></head>';
        final bytes = <int>[...utf8.encode(head), 0xE4, 0xB8];
        final client = MockClient(
          (req) async => http.Response.bytes(
            bytes,
            200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
          ),
        );
        final r = await inspectUrl(
          'https://x/page',
          client: client,
          maxBodyBytes: 20,
        );
        final w = r as UrlWebpage;
        expect(w.preview.title, 'ok');
      },
    );
  });
}
