import 'package:costr/models/event.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tokenizeContent (image grouping)', () {
    test('single image → one image group of 1', () {
      final segs = tokenizeContent('see this ![](https://x/a.jpg)');
      // [TextSeg, ImageGroupSeg(1)]
      expect(segs.length, 2);
      expect(segs[0], isA<TextSeg>());
      expect((segs[1] as ImageGroupSeg).urls, ['https://x/a.jpg']);
    });

    test('contiguous images (whitespace between) → one group', () {
      final segs = tokenizeContent(
        '![](https://x/a.jpg) ![](https://x/b.jpg)\n![](https://x/c.png)',
      );
      // one ImageGroupSeg with 3 urls (leading text empty → no TextSeg)
      expect(segs.length, 1);
      expect((segs[0] as ImageGroupSeg).urls.length, 3);
    });

    test('text between images → two separate groups + text between', () {
      final segs = tokenizeContent(
        '![](https://x/a.jpg)\nlook here\n![](https://x/b.jpg)',
      );
      // [ImageGroup(1), TextSeg, ImageGroup(1)]
      expect(segs.length, 3);
      expect(segs[0], isA<ImageGroupSeg>());
      expect((segs[0] as ImageGroupSeg).urls, ['https://x/a.jpg']);
      expect(segs[1], isA<TextSeg>());
      expect((segs[2] as ImageGroupSeg).urls, ['https://x/b.jpg']);
    });

    test('a video URL breaks the image group (full-width video)', () {
      final segs = tokenizeContent(
        '![](https://x/a.jpg)![](https://x/v.mp4)![](https://x/b.jpg)',
      );
      // [ImageGroup(1: a), SingleVideo(v), ImageGroup(1: b)] — all contiguous
      // (no text between), but the video is a separate SingleVideoSeg.
      expect(segs.length, 3);
      expect(segs[0], isA<ImageGroupSeg>());
      expect(segs[1], isA<SingleVideoSeg>());
      expect((segs[1] as SingleVideoSeg).url, 'https://x/v.mp4');
      expect(segs[2], isA<ImageGroupSeg>());
    });

    test('9+ images group together (no cap, actual count)', () {
      final segs = tokenizeContent(
        List.generate(12, (i) => '![](https://x/\$i.jpg)').join(' '),
      );
      expect(segs.length, 1);
      expect((segs[0] as ImageGroupSeg).urls.length, 12);
    });

    test('no images → single text segment', () {
      final segs = tokenizeContent('just text, nothing else');
      expect(segs.length, 1);
      expect(segs[0], isA<TextSeg>());
    });

    test('leading text + contiguous group + trailing text', () {
      final segs = tokenizeContent(
        'intro\n![](https://x/a.jpg)![](https://x/b.jpg)\noutro',
      );
      // [TextSeg(intro), ImageGroup(2), TextSeg(outro)]
      expect(segs.length, 3);
      expect(segs[0], isA<TextSeg>());
      expect((segs[1] as ImageGroupSeg).urls.length, 2);
      expect(segs[2], isA<TextSeg>());
    });
  });

  group('tokenizeContent (bare media URLs)', () {
    test('single bare image URL → one image group of 1', () {
      final segs = tokenizeContent('see this https://x/a.jpg');
      expect(segs.length, 2);
      expect(segs[0], isA<TextSeg>());
      expect((segs[1] as ImageGroupSeg).urls, ['https://x/a.jpg']);
    });

    test('two contiguous bare image URLs → one group of 2', () {
      final segs = tokenizeContent(
        'http://img.toto.im/mw600/a.jpg\nhttps://img.wangmoyu.com/mw600/b.jpeg',
      );
      expect(segs.length, 1);
      expect((segs[0] as ImageGroupSeg).urls.length, 2);
    });

    test('bare URL between text → text + image + text', () {
      final segs = tokenizeContent('look\nhttps://x/a.jpg\nmore');
      expect(segs.length, 3);
      expect(segs[0], isA<TextSeg>());
      expect((segs[1] as ImageGroupSeg).urls, ['https://x/a.jpg']);
      expect(segs[2], isA<TextSeg>());
    });

    test('markdown link to an image is NOT extracted as a bare image', () {
      // [text](https://x/a.jpg) — the URL is inside markdown link syntax; the
      // negative lookbehind on ]( keeps it from being tokenized as an image,
      // so it stays in the text segment for the markdown renderer to linkify.
      final segs = tokenizeContent('click [photo](https://x/a.jpg) here');
      expect(segs.length, 1);
      expect(segs[0], isA<TextSeg>());
    });

    test('bare video URL → SingleVideoSeg', () {
      final segs = tokenizeContent('clip https://x/v.mp4 end');
      expect(segs.length, 3);
      expect(segs[0], isA<TextSeg>());
      expect(segs[1], isA<SingleVideoSeg>());
      expect((segs[1] as SingleVideoSeg).url, 'https://x/v.mp4');
      expect(segs[2], isA<TextSeg>());
    });

    test('npub-subdomain blossom URL → SingleVideoSeg with the full URL', () {
      // blossom.band serves media under the uploader's npub as a subdomain;
      // the tokenizer must hand the URL through intact (the npub inside it
      // is part of the host name, not a mention).
      const url =
          'https://npub1ak68qfcjj7k95c0jwleu69x72nr8adwv6g80pkwl9xlps6zmkqzqrxy8fx'
          '.blossom.band/200f65747d4b50e01a6e912a628e2c1da49fc4a45c5bfdccc2cb4fef'
          '783e8776.mp4';
      final segs = tokenizeContent('NVK knew in 2021.\n\n$url');
      expect(segs.length, 2);
      expect(segs[0], isA<TextSeg>());
      expect(segs[1], isA<SingleVideoSeg>());
      expect((segs[1] as SingleVideoSeg).url, url);
    });
  });

  group('tag-declared media whose URL lacks a file extension', () {
    // Real-world shape (抖音 share): the bare URL carries no .mp4 extension,
    // but the event declares it via ["video", url, "video/mp4"]. The tag's
    // MIME must win so the player renders instead of a plain link
    // ("视频链接不渲染播放控件" bug).
    const douyin =
        'https://www.iesdouyin.com/aweme/v1/playwm/?line=0&logo_name=aweme'
        '_diversion_search&ratio=720p&video_id=v0300fg10000d9kbvqfog65vt6g0i58g';

    test('["video", url, video/mp4] → SingleVideoSeg', () {
      final segs = tokenizeContent(
        '分享一个视频\n$douyin\n#媒体',
        tagged: const [MediaAttachment(url: douyin, mimeType: 'video/mp4')],
      );
      expect(segs.whereType<SingleVideoSeg>().map((s) => s.url), [douyin]);
      // The URL must NOT also linger in a text segment.
      for (final s in segs.whereType<TextSeg>()) {
        expect(s.text.contains('iesdouyin'), isFalse);
      }
    });

    test('same URL without the tag stays plain text (a link)', () {
      final segs = tokenizeContent('分享一个视频\n$douyin\n#媒体');
      expect(segs.whereType<SingleVideoSeg>(), isEmpty);
      expect(segs.whereType<ImageGroupSeg>(), isEmpty);
    });

    test('tag-declared image URL without extension joins an image group', () {
      const url = 'https://x/cdn?id=abc';
      final segs = tokenizeContent(
        url,
        tagged: const [MediaAttachment(url: url, mimeType: 'image/jpeg')],
      );
      expect(segs.single, isA<ImageGroupSeg>());
      expect((segs.single as ImageGroupSeg).urls, [url]);
    });

    test('tagged URL inside a markdown link is NOT extracted as media', () {
      // The (?<!\]\() guard applies to tag-declared urls too: [text](url)
      // stays a clickable link.
      const url = 'https://x/play?video_id=1';
      final segs = tokenizeContent(
        '[click]($url)',
        tagged: const [MediaAttachment(url: url, mimeType: 'video/mp4')],
      );
      expect(segs.whereType<SingleVideoSeg>(), isEmpty);
      expect(segs.single, isA<TextSeg>());
    });

    test('tag with non-media mimetype does not hijack the URL', () {
      const url = 'https://x/thing?id=1';
      final segs = tokenizeContent(
        url,
        tagged: const [MediaAttachment(url: url, mimeType: 'text/html')],
      );
      expect(segs.whereType<SingleVideoSeg>(), isEmpty);
      expect(segs.whereType<ImageGroupSeg>(), isEmpty);
    });
  });

  group('media URLs with query/fragment (signed CDN links)', () {
    // Regression: the bare-media regexes used to require the URL to END at
    // the extension, so `…/xxx_309.mp4?sign=…&t=…` matched only up to
    // `.mp4` — the player got a dead truncated URL and the text strip left
    // an orphan `?sign=…` behind.
    test('bare video URL keeps its full ?query (real xhscdn shape)', () {
      const url =
          'https://sns-video-v3.xhscdn.com/stream/1/110/309/'
          '01ea169b8f13cfd2010370019e68505ad5_309.mp4'
          '?sign=abe6972bb781f1988a30ed2662d111f1&t=6a8a6e3a';
      final segs = tokenizeContent('看视频 $url 完了');
      expect(segs.length, 3);
      expect(segs[0], isA<TextSeg>());
      expect(segs[1], isA<SingleVideoSeg>());
      expect((segs[1] as SingleVideoSeg).url, url); // FULL url incl. query
      expect((segs[0] as TextSeg).text, isNot(contains('sign=')));
      expect((segs[2] as TextSeg).text, isNot(contains('t=')));
    });

    test('bare image URL keeps its ?query', () {
      const url = 'https://x/a.jpg?x-oss-process=resize,w_100';
      final segs = tokenizeContent(url);
      expect(segs.single, isA<ImageGroupSeg>());
      expect((segs.single as ImageGroupSeg).urls, [url]);
    });

    test('fragment also stays with the URL', () {
      const url = 'https://x/v.mp4#t=10';
      final segs = tokenizeContent(url);
      expect((segs.single as SingleVideoSeg).url, url);
    });

    test('contiguous query-suffixed images still group together', () {
      final segs = tokenizeContent('https://x/a.jpg?v=1 https://x/b.png?v=2');
      expect(segs.single, isA<ImageGroupSeg>());
      expect((segs.single as ImageGroupSeg).urls.length, 2);
    });

    test('markdown link to a query media URL stays a text link', () {
      // The (?<!\]\() lookbehind still wins over the query suffix.
      final segs = tokenizeContent('[p](https://x/a.jpg?v=1)');
      expect(segs.single, isA<TextSeg>());
    });

    test('stripBareMediaUrls removes the query too (no orphan ?sign=)', () {
      const text = 'a https://x/v.mp4?s=1&t=2 b https://x/f.pdf?dl=1';
      final stripped = stripBareMediaUrls(text);
      expect(stripped, isNot(contains('s=1')));
      expect(stripped, isNot(contains('dl=1')));
      expect(stripped.replaceAll(RegExp(r'\s+'), ' ').trim(), 'a b');
    });
  });
}
