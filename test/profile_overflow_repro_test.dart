import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal repro of the profile-page scroll structure: NestedScrollView with a
/// tall SliverToBoxAdapter header (long profile), a pinned SliverPersistentHeader
/// TabBar, and a TabBarView body whose tabs are Column[searchbar, Expanded(list)].
/// Used to diagnose the recurring "bottom overflowed by N pixels" when the
/// profile header is taller than the viewport.
Widget _boilerplate({required double headerHeight}) {
  return MaterialApp(
    home: DefaultTabController(
      length: 2,
      child: Scaffold(
        body: NestedScrollView(
          headerSliverBuilder: (_, _) => [
            SliverToBoxAdapter(
              // Mirror the real _Header: a Column (MainAxisSize.max) with a
              // banner box + many rows, simulating a long profile.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(height: 150, color: Colors.red),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < (headerHeight / 40).round(); i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              height: 40,
                              color: Colors.red.shade200,
                              alignment: Alignment.center,
                              child: Text('row $i'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SliverPersistentHeader(pinned: true, delegate: _BarDelegate('TAB')),
          ],
          body: TabBarView(children: [_Tab('posts'), _Tab('replies')]),
        ),
      ),
    ),
  );
}

class _BarDelegate extends SliverPersistentHeaderDelegate {
  _BarDelegate(this.label);
  final String label;
  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;
  @override
  Widget build(_, _, _) => Container(
    height: 48,
    color: Colors.blue,
    alignment: Alignment.center,
    child: Text(label),
  );
  @override
  bool shouldRebuild(_BarDelegate old) => label != old.label;
}

class _Tab extends StatelessWidget {
  const _Tab(this.hint);
  final String hint;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 44,
          color: Colors.green,
          alignment: Alignment.center,
          child: Text('search $hint'),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: 50,
            itemBuilder: (_, i) => ListTile(title: Text('item $i')),
          ),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('short header: no overflow', (tester) async {
    await tester.pumpWidget(_boilerplate(headerHeight: 200));
    await tester.pumpAndSettle();
    final exc = tester.takeException();
    expect(exc, isNull, reason: 'short header must not overflow');
  });

  testWidgets('tall header (longer than viewport): no overflow after scroll', (
    tester,
  ) async {
    await tester.pumpWidget(_boilerplate(headerHeight: 1400));
    await tester.pumpAndSettle();
    // Scroll the header fully away so the pinned TabBar + search bar are visible.
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    final exc = tester.takeException();
    expect(exc, isNull, reason: 'tall header must not overflow on scroll');
  });
}
