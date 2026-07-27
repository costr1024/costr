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
      final segs = tokenizeContent('![](https://x/a.jpg) ![](https://x/b.jpg)\n![](https://x/c.png)');
      // one ImageGroupSeg with 3 urls (leading text empty → no TextSeg)
      expect(segs.length, 1);
      expect((segs[0] as ImageGroupSeg).urls.length, 3);
    });

    test('text between images → two separate groups + text between', () {
      final segs = tokenizeContent('![](https://x/a.jpg)\nlook here\n![](https://x/b.jpg)');
      // [ImageGroup(1), TextSeg, ImageGroup(1)]
      expect(segs.length, 3);
      expect(segs[0], isA<ImageGroupSeg>());
      expect((segs[0] as ImageGroupSeg).urls, ['https://x/a.jpg']);
      expect(segs[1], isA<TextSeg>());
      expect((segs[2] as ImageGroupSeg).urls, ['https://x/b.jpg']);
    });

    test('a video URL breaks the image group (full-width video)', () {
      final segs = tokenizeContent('![](https://x/a.jpg)![](https://x/v.mp4)![](https://x/b.jpg)');
      // [ImageGroup(1: a), SingleVideo(v), ImageGroup(1: b)] — all contiguous
      // (no text between), but the video is a separate SingleVideoSeg.
      expect(segs.length, 3);
      expect(segs[0], isA<ImageGroupSeg>());
      expect(segs[1], isA<SingleVideoSeg>());
      expect((segs[1] as SingleVideoSeg).url, 'https://x/v.mp4');
      expect(segs[2], isA<ImageGroupSeg>());
    });

    test('9+ images group together (no cap, actual count)', () {
      final segs = tokenizeContent(List.generate(12, (i) => '![](https://x/\$i.jpg)').join(' '));
      expect(segs.length, 1);
      expect((segs[0] as ImageGroupSeg).urls.length, 12);
    });

    test('no images → single text segment', () {
      final segs = tokenizeContent('just text, nothing else');
      expect(segs.length, 1);
      expect(segs[0], isA<TextSeg>());
    });

    test('leading text + contiguous group + trailing text', () {
      final segs = tokenizeContent('intro\n![](https://x/a.jpg)![](https://x/b.jpg)\noutro');
      // [TextSeg(intro), ImageGroup(2), TextSeg(outro)]
      expect(segs.length, 3);
      expect(segs[0], isA<TextSeg>());
      expect((segs[1] as ImageGroupSeg).urls.length, 2);
      expect(segs[2], isA<TextSeg>());
    });
  });
}
