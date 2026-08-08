// Repro harness: immersive hide on the 关注 (following) feed tab is
// unreliable ("菜单偶尔隐藏偶尔不隐藏"). Pumps the REAL FeedPage in
// following mode with a live store and simulates finger scrolling + live
// event arrival, asserting the chrome (appBarsVisibleProvider) hides.

import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/feed_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/metadata.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/event_store.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _followee =
    'abababababababababababababababababababababababababababababababab';

const longStatus =
    'a very very very very very very very very very very long status line '
    'that definitely overflows the card width and scrolls horizontally';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Follows extends FollowingNotifier {
  @override
  Future<List<String>> build() async => const <String>[_followee];
}

class _ImmersiveOn extends ImmersiveBrowseNotifier {
  @override
  bool build() => true;
}

class _NoFilter extends FollowingFilterNotifier {
  @override
  String? build() => null;
}

class _NoLang extends LanguageFilterNotifier {
  @override
  LanguageFilter build() => LanguageFilter.all;
}

class _NoTag extends TagFilterNotifier {
  @override
  String? build() => null;
}

class _NoTags extends FollowedTagsNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
}

/// Feed mode notifier that skips SQLite persistence (no plugin in tests).
class _MutableMode extends FeedModeNotifier {
  _MutableMode(this.initial);
  final FeedMode initial;

  @override
  FeedMode build() => initial;

  @override
  void set(FeedMode mode) {
    if (mode == state) return;
    state = mode;
  }
}

/// Store with synchronous, externally-triggerable ingestion (mimics the
/// 200ms-batched live flush of the real EventStoreNotifier).
class _LiveStore extends EventStoreNotifier {
  @override
  final EventStore store = EventStore();

  @override
  List<Event> build() => store.events;

  void add(Event e) {
    if (store.add(e)) state = store.events;
  }
}

Event _post(String id, String pubkey, int createdAt) => Event(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: 1,
      tags: const [],
      content: 'post $id with some content to give the card height',
      sig: 's' * 128,
    );

ProviderContainer _buildContainer({
  required _LiveStore store,
  FeedMode mode = FeedMode.following,
  String? status,
}) {
  return ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      indexerPoolProvider.overrideWith((ref) => RelayPool(const [])),
      searchPoolProvider.overrideWith((ref) => RelayPool(const [])),
      identityProvider.overrideWith(() => _Id()),
      followingStateProvider.overrideWith(() => _Follows()),
      feedModeProvider.overrideWith(() => _MutableMode(mode)),
      immersiveBrowseProvider.overrideWith(() => _ImmersiveOn()),
      followingFilterProvider.overrideWith(() => _NoFilter()),
      languageFilterProvider.overrideWith(() => _NoLang()),
      tagFilterProvider.overrideWith(() => _NoTag()),
      eventStoreProvider.overrideWith(() => store),
      myMuteSetProvider.overrideWith((ref) => const MuteSet()),
      feedSubscriptionProvider.overrideWith((ref) {}),
      followingOutboxProvider.overrideWith((ref) {}),
      metadataProvider.overrideWith((ref, pubkey) async* {
        yield null as Metadata?;
      }),
      userStatusProvider.overrideWith((ref, pubkey) async* {
        yield status;
      }),
      userGroupedFollowsProvider.overrideWith((ref, pubkey) async* {
        yield const <FollowGroup>[];
      }),
      followedTagsProvider.overrideWith(() => _NoTags()),
    ],
  );
}

Future<void> pumpFeed(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FeedPage()),
    ),
  );
  // Let the async providers (identity/follows) resolve and the feed render
  // its events (the list becomes scrollable once items are in).
  final sw = Stopwatch()..start();
  while (maxFeedExtent(tester) < 100) {
    if (sw.elapsed > const Duration(seconds: 3)) {
      fail('feed list never filled — events not visible in following mode');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The feed list's scroll metrics (the scrollable with the largest extent).
ScrollMetrics feedMetrics(WidgetTester tester) {
  final states = tester.stateList<ScrollableState>(find.byType(Scrollable));
  return states
      .map((s) => s.position)
      .fold<ScrollMetrics>(states.first.position,
          (a, b) => b.maxScrollExtent > a.maxScrollExtent ? b : a);
}

double maxFeedExtent(WidgetTester tester) {
  final states = tester.stateList<ScrollableState>(find.byType(Scrollable));
  if (states.isEmpty) return 0;
  return states
      .map((s) => s.position.maxScrollExtent)
      .fold<double>(0, (a, b) => b > a ? b : a);
}

/// A finger-like drag: small moves with frame pumps in between, then release
/// and let the ballistic settle.
Future<void> fingerScroll(
  WidgetTester tester,
  Offset start,
  List<Offset> moves, {
  Duration step = const Duration(milliseconds: 40),
}) async {
  final g = await tester.startGesture(start);
  for (final m in moves) {
    await g.moveBy(m);
    await tester.pump(step);
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  statusLineTests();
  doubleTapTests();

  testWidgets('following: single firm down-scroll hides chrome',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    expect(container.read(appBarsVisibleProvider), isTrue);
    await fingerScroll(tester, const Offset(300, 400), [
      for (var i = 0; i < 10; i++) const Offset(0, -30),
    ]);
    expect(feedMetrics(tester).pixels, greaterThan(100),
        reason: 'the drag must actually scroll the feed list');
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'firm down-scroll must hide the chrome');
  });

  testWidgets('following: repeated short down-scrolls hide chrome',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Five short ~60px strokes, pausing between them like a real reader.
    for (var s = 0; s < 5; s++) {
      await fingerScroll(tester, const Offset(300, 400), [
        const Offset(0, -20),
        const Offset(0, -20),
        const Offset(0, -20),
      ]);
    }
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'accumulated short down-scrolls must hide the chrome');
  });

  testWidgets('following: down-scroll hides while live events arrive',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Scroll a bit (sets the read freeze), then live events land while the
    // user keeps scrolling down.
    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, -60),
      const Offset(0, -60),
    ]);
    for (var i = 0; i < 5; i++) {
      store.add(_post('live$i', _followee, 200000 + i));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, -60),
      const Offset(0, -60),
      const Offset(0, -60),
    ]);
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'chrome must hide even while live events rebuild the list');
  });

  testWidgets('following: hide → up show → down hide again', (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, -150),
      const Offset(0, -150),
    ]);
    expect(container.read(appBarsVisibleProvider), isFalse);
    // Scroll back UP past the top → chrome returns.
    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, 150),
      const Offset(0, 150),
      const Offset(0, 150),
      const Offset(0, 150),
    ]);
    expect(container.read(appBarsVisibleProvider), isTrue);
    // And hiding again must work.
    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, -100),
      const Offset(0, -100),
      const Offset(0, -100),
    ]);
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'second down-scroll must hide the chrome again');
  });

  testWidgets('following: hide survives scroll while list grows at top',
      (tester) async {
    // The cold-following pattern: user is at the top while events stream in
    // (list rebuilds every arrival), THEN starts scrolling down.
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    for (var i = 0; i < 8; i++) {
      store.add(_post('new$i', _followee, 300000 + i));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await fingerScroll(tester, const Offset(300, 400), [
      const Offset(0, -80),
      const Offset(0, -80),
      const Offset(0, -80),
      const Offset(0, -80),
    ]);
    expect(container.read(appBarsVisibleProvider), isFalse);
  });
}

// --- Nested horizontal scrollable (author status line) ---------------------
//
// EventCard renders an author status as a HORIZONTAL SingleChildScrollView
// (_StatusLine). The immersive detector listens to ScrollNotifications of ANY
// axis from ANY descendant, so a horizontal swipe of the status line drives
// the chrome show/hide logic with horizontal metrics.

Finder _hScrollFinder() => find.byWidgetPredicate(
      (Widget w) =>
          w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );

/// Center of the first status line that is currently inside the viewport.
/// Waits (pumps) until at least one status line is rendered.
Future<Offset> _visibleStatusCenter(WidgetTester tester) async {
  final sw = Stopwatch()..start();
  while (true) {
    for (final e in _hScrollFinder().evaluate()) {
      final c = tester.getCenter(find.byWidget(e.widget));
      if (c.dy > 0 && c.dy < 600) return c;
    }
    if (sw.elapsed > const Duration(seconds: 3)) {
      fail('no status line visible in the viewport');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void statusLineTests() {
  testWidgets('horizontal swipe of a status line does NOT flip the chrome',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store, status: longStatus);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Hide the chrome with a legit vertical down-scroll first.
    await fingerScroll(tester, const Offset(300, 450), [
      for (var i = 0; i < 6; i++) const Offset(0, -30),
    ]);
    expect(container.read(appBarsVisibleProvider), isFalse);

    // Now swipe the (visible) status line horizontally. The feed itself must
    // not move and the chrome state must not flip.
    final before = feedMetrics(tester).pixels;
    final target = await _visibleStatusCenter(tester);
    final g = await tester.startGesture(target);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(-25, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(feedMetrics(tester).pixels, before,
        reason: 'horizontal status swipe must not scroll the feed');
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'horizontal status swipe must not re-show the chrome');

    // And a swipe back must not hide-then-show-flip either.
    final g2 = await tester.startGesture(await _visibleStatusCenter(tester));
    for (var i = 0; i < 6; i++) {
      await g2.moveBy(const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g2.up();
    await tester.pumpAndSettle();
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'horizontal status swipe must not flip chrome visibility');
  });

  testWidgets('visible chrome is not hidden by a horizontal status swipe',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store, status: longStatus);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Scroll down a little (below the threshold) — chrome still visible.
    await fingerScroll(tester, const Offset(300, 450), [
      const Offset(0, -20),
      const Offset(0, -20),
    ]);
    expect(container.read(appBarsVisibleProvider), isTrue);

    // A long horizontal swipe of the status line must not hide the chrome.
    final target = await _visibleStatusCenter(tester);
    final g = await tester.startGesture(target);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(container.read(appBarsVisibleProvider), isTrue,
        reason: 'horizontal scroll must never hide the vertical chrome');
  });
}

// --- Double-tap tab row → scroll to top -------------------------------------

void doubleTapTests() {
  /// Two quick taps on the same point (within the 300ms double-tap window).
  Future<void> doubleTap(WidgetTester tester, Offset at) async {
    for (var i = 0; i < 2; i++) {
      final g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 30));
      await g.up();
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('feed: double-tap the tab row jumps back to the newest post',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 60; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Scroll deep into the feed.
    await fingerScroll(tester, const Offset(300, 450), [
      for (var i = 0; i < 8; i++) const Offset(0, -60),
    ]);
    final deep = feedMetrics(tester).pixels;
    expect(deep, greaterThan(200));
    expect(container.read(appBarsVisibleProvider), isFalse,
        reason: 'chrome hides once deep in the feed');

    // The tab row is part of the hidden chrome — a real user scrolls up a
    // touch to bring it back, THEN double-taps it.
    await fingerScroll(tester, const Offset(300, 450), [
      const Offset(0, 40),
      const Offset(0, 40),
    ]);
    expect(container.read(appBarsVisibleProvider), isTrue);
    expect(feedMetrics(tester).pixels, greaterThan(100),
        reason: 'still deep — only the chrome came back');

    // Double-tap the 全球/关注 tab row.
    await doubleTap(
        tester, tester.getCenter(find.byType(SegmentedButton<FeedMode>)));
    expect(feedMetrics(tester).pixels, 0,
        reason: 'double-tap must return to the top of the feed');
    expect(container.read(appBarsVisibleProvider), isTrue,
        reason: 'chrome must be visible again at the top');
  });

  testWidgets('feed: double-tap releases the read freeze (pending posts land)',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 60; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store);
    addTearDown(container.dispose);
    await pumpFeed(tester, container);

    // Scroll down (sets the freeze), then new posts arrive while frozen.
    await fingerScroll(tester, const Offset(300, 450), [
      for (var i = 0; i < 5; i++) const Offset(0, -60),
    ]);
    store.add(_post('fresh1', _followee, 900000));
    await tester.pump(const Duration(milliseconds: 100));
    // The newest visible post is still the freeze-time one.
    expect(find.text('post fresh1 with some content to give the card height'),
        findsNothing,
        reason: 'new post is held back while frozen');

    // Scroll up a touch so the (hidden) tab row is visible again, then
    // double-tap back to the top → freeze releases → newest post shows.
    await fingerScroll(tester, const Offset(300, 450), [
      const Offset(0, 40),
      const Offset(0, 40),
    ]);
    await doubleTap(
        tester, tester.getCenter(find.byType(SegmentedButton<FeedMode>)));
    expect(feedMetrics(tester).pixels, 0);
    expect(find.text('post fresh1 with some content to give the card height'),
        findsOneWidget,
        reason: 'releasing at the top must unhold the pending post');
  });

  testWidgets('feed: single tap still switches mode without double-tap delay',
      (tester) async {
    final store = _LiveStore();
    for (var i = 0; i < 40; i++) {
      store.store.add(_post('e$i', _followee, 100000 - i * 10));
    }
    final container = _buildContainer(store: store); // starts in following
    addTearDown(container.dispose);
    await pumpFeed(tester, container);
    expect(container.read(feedModeProvider), FeedMode.following);

    // Single tap on 全球.
    await tester.tap(find.text('全球'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(container.read(feedModeProvider), FeedMode.global,
        reason: 'a single tap must switch the mode promptly — the wrapping '
            'double-tap listener must not hold the tap hostage');
  });
}
