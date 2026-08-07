// Regression test: the fullscreen image viewer offers 「复制图片链接」 —
// copying the CURRENT image's origin URL (sharing the URL where saving the
// file isn't wanted). Before this the top bar only had close + save.

import 'package:costr/widgets/media_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('viewer copies the current image origin URL', (tester) async {
    // flutter_test has no default Clipboard mock — setData would hang
    // forever. Back it with an in-memory map.
    final store = <String, dynamic>{};
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          store['text'] = (call.arguments as Map<Object?, Object?>)['text'];
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': store['text']};
        }
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: ElevatedButton(
                onPressed: () => pushMediaViewer(
                  ctx,
                  images: const [
                    'https://example.com/a.png',
                    'https://example.com/b.png',
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Route fade (180ms) + first frame; the top bar is visible by default
    // regardless of image load state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.link_rounded));
    await tester.pump();

    expect(find.text('已复制图片链接'), findsOneWidget);
    final data = await Clipboard.getData('text/plain');
    expect(data?.text, 'https://example.com/a.png',
        reason: 'origin URL (first image), not a proxy mirror');
  });
}
