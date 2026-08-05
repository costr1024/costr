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
}
