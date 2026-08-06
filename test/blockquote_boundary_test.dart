// Regression: a 财新-style post opens with a one-line blockquote (`> 导语`),
// then a blank line, then the article body. preserveBlankLines used to turn
// EVERY blank line into a zero-width space; a ZWSP right after a blockquote is
// a markdown "lazy continuation" line, so the parser absorbed the ENTIRE
// article into the quote (the whole post rendered inside the quote box).
// Blank lines that terminate a blockquote must stay real blank lines.
import 'package:costr/widgets/markdown_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' hide Text;

/// Shape of the reported post: hashtag, `> quote`, blank lines, article, link.
const _caixin =
    '#财新\n'
    '> “楼宇经济”是以商务楼宇为载体，形成税源并带动区域经济发展的一种新型经济形态\n'
    '\n'
    '  \n'
    '\n'
    '　　新时期房地产高质量发展的内涵，不仅体现在居民住房领域，也体现在商业楼宇的价值重塑。\n'
    '\n'
    '推荐进入[财新数据库](https://cxdata.caixin.com/index)。\n'
    'https://opinion.caixin.com/2026-08-06/102471690.html';

List<Element> _blockquotes(String src) {
  final nodes = Document(
    extensionSet: ExtensionSet.gitHubFlavored,
  ).parseLines(src.split('\n'));
  final out = <Element>[];
  void walk(List<Node> ns) {
    for (final n in ns) {
      if (n is Element) {
        if (n.tag == 'blockquote') out.add(n);
        if (n.children != null) walk(n.children!);
      }
    }
  }

  walk(nodes);
  return out;
}

void main() {
  group('preserveBlankLines blockquote termination', () {
    test('article after a `> quote` is NOT absorbed into the quote', () {
      final bqs = _blockquotes(preserveBlankLines(_caixin));
      expect(bqs, hasLength(1));
      final quoted = bqs.single.textContent;
      // The quote keeps its own line…
      expect(quoted, contains('楼宇经济'));
      // …but does not swallow the article body or the trailing link.
      expect(quoted, isNot(contains('新时期房地产')));
      expect(quoted, isNot(contains('财新数据库')));
      expect(quoted, isNot(contains('opinion.caixin.com')));
    });

    test('blank line right after a quote stays a real blank line', () {
      // '' terminator, not a ZWSP.
      expect(preserveBlankLines('> q\n\nnext'), '> q\n\nnext');
    });

    test('blank lines between ordinary paragraphs are still preserved', () {
      // Non-blockquote blanks become a ZWSP so the gap renders.
      expect(preserveBlankLines('a\n\nb'), 'a\n\u200B\nb');
      expect(preserveBlankLines('a\n\n\nb'), 'a\n\u200B\n\u200B\nb');
    });

    test('multi-line quote: blank after the last `>` line ends it', () {
      final bqs = _blockquotes(preserveBlankLines('> l1\n> l2\n\nnext'));
      expect(bqs, hasLength(1));
      expect(bqs.single.textContent, contains('l1'));
      expect(bqs.single.textContent, contains('l2'));
      expect(bqs.single.textContent, isNot(contains('next')));
    });
  });
}
