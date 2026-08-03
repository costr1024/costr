/// Routing + auth redirect.
///
/// Feed and Profile live inside a [StatefulShellRoute] so a bottom nav bar
/// persists across them (and each tab keeps its state). Compose is pushed
/// full-screen (auto back button). Login is a standalone top-level route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_page.dart';
import '../features/compose/compose_page.dart';
import '../features/feed/feed_page.dart';
import '../features/feed/post_detail_page.dart';
import '../features/notifications/notification_settings_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/profile/edit_profile_page.dart';
import '../features/profile/profile_page.dart';
import '../features/settings/account_settings_page.dart';
import '../features/settings/mute_list_page.dart';
import '../features/settings/relays_page.dart';
import '../features/settings/settings_page.dart';
import '../features/search/search_page.dart';
import '../models/event.dart';
import '../widgets/costr_logo.dart';
import '../widgets/onboarding_overlay.dart';
import 'providers.dart';
import 'theme.dart';

final GlobalKey<NavigatorState> rootNavigator = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = GoRouterRefreshNotifier();
  // Re-evaluate redirects whenever identity or bootstrap state changes.
  ref.listen<AsyncValue>(identityProvider, (_, _) => refresh.notify());
  ref.listen<AsyncValue>(bootstrapProvider, (_, _) => refresh.notify());

  return GoRouter(
    navigatorKey: rootNavigator,
    initialLocation: '/feed',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final identity = ref.read(identityProvider).value;
      final loc = state.matchedLocation;
      final goingToLogin = loc == '/login';
      if (identity == null && !goingToLogin) return '/login';
      if (identity != null && goingToLogin) return '/feed';
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/login',
        builder: (BuildContext context, GoRouterState state) =>
            const LoginPage(),
      ),
      GoRoute(
        path: '/compose',
        builder: (BuildContext context, GoRouterState state) {
          final extra = state.extra;
          Event? replyTo;
          Event? quoteOf;
          if (extra is Map) {
            final r = extra['replyTo'];
            final q = extra['quoteOf'];
            if (r is Event) replyTo = r;
            if (q is Event) quoteOf = q;
          }
          return ComposePage(replyTo: replyTo, quoteOf: quoteOf);
        },
      ),
      GoRoute(
        path: '/u/:pubkey',
        builder: (BuildContext context, GoRouterState state) =>
            ProfilePage(pubkey: state.pathParameters['pubkey']),
      ),
      GoRoute(
        path: '/n/:id',
        builder: (BuildContext context, GoRouterState state) =>
            PostDetailPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (BuildContext context, GoRouterState state) =>
            const EditProfilePage(),
      ),
      GoRoute(
        path: '/settings',
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsPage(),
      ),
      GoRoute(
        path: '/about',
        builder: (BuildContext context, GoRouterState state) =>
            const AboutPage(),
      ),
      GoRoute(
        path: '/settings/notifications',
        builder: (BuildContext context, GoRouterState state) =>
            const NotificationSettingsPage(),
      ),
      GoRoute(
        path: '/settings/account',
        builder: (BuildContext context, GoRouterState state) =>
            const AccountSettingsPage(),
      ),
      GoRoute(
        path: '/settings/relays',
        builder: (BuildContext context, GoRouterState state) =>
            const RelaysPage(),
      ),
      GoRoute(
        path: '/settings/mute',
        builder: (BuildContext context, GoRouterState state) =>
            const MuteListPage(),
      ),
      StatefulShellRoute.indexedStack(
        builder:
            (
              BuildContext context,
              GoRouterState state,
              StatefulNavigationShell navigationShell,
            ) => AppShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          // Tab 1: 首页 (Feed)
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/feed',
                builder: (BuildContext context, GoRouterState state) =>
                    const FeedPage(),
              ),
            ],
          ),
          // Tab 2: 搜索
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/search',
                builder: (BuildContext context, GoRouterState state) =>
                    const SearchPage(),
              ),
            ],
          ),
          // Tab 3: 通知 (placeholder — fills with notification center in P4)
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/notifications',
                builder: (BuildContext context, GoRouterState state) =>
                    const NotificationsPage(),
              ),
            ],
          ),
          // Tab 4: 我的 (Profile)
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/profile',
                builder: (BuildContext context, GoRouterState state) =>
                    const ProfilePage(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// 4-tab bottom-nav shell (首页/搜索/通知/我的) with FAB. Persists each
/// tab's state via StatefulShellRoute.indexedStack.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// Whether to show the first-run onboarding overlay. Loaded from the local
  /// config table on init; flipped off + persisted when the user finishes.
  bool _showOnboarding = false;

  /// Compose FAB position (top-left origin within the shell stack). Null =
  /// default bottom-right. Persisted to the local config table so the user's
  /// chosen spot survives across sessions.
  Offset? _fabOffset;

  static const double _fabSize = 56;
  static const double _fabMargin = 12;
  static const double _navBarHeight = 80; // NavigationBar default height.

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    _loadFabOffset();
  }

  Future<void> _loadFabOffset() async {
    final cache = await ref.read(localCacheProvider.future);
    final x = await cache.readConfig('fab_x');
    final y = await cache.readConfig('fab_y');
    if (!mounted) return;
    final dx = double.tryParse(x ?? '');
    final dy = double.tryParse(y ?? '');
    if (dx != null && dy != null) {
      setState(() => _fabOffset = Offset(dx, dy));
    }
  }

  Future<void> _persistFabOffset() async {
    final pos = _fabOffset;
    if (pos == null) return;
    final cache = await ref.read(localCacheProvider.future);
    await cache.writeConfig('fab_x', pos.dx.toStringAsFixed(1));
    await cache.writeConfig('fab_y', pos.dy.toStringAsFixed(1));
  }

  Offset _defaultFabOffset(Size size, EdgeInsets pad) {
    return Offset(
      size.width - _fabSize - _fabMargin,
      size.height - _navBarHeight - pad.bottom - _fabSize - _fabMargin,
    );
  }

  Future<void> _checkOnboarding() async {
    final cache = await ref.read(localCacheProvider.future);
    final done = await cache.readConfig('onboarding_done');
    if (mounted && done != '1') {
      setState(() => _showOnboarding = true);
    }
  }

  Future<void> _finishOnboarding() async {
    setState(() => _showOnboarding = false);
    final cache = await ref.read(localCacheProvider.future);
    await cache.writeConfig('onboarding_done', '1');
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final pad = mq.padding;
    // Unread notification count — watching it keeps the notification
    // subscription alive across tabs (foreground-live per DESIGN §5.1).
    final myPubkey = ref.watch(identityProvider).value?.pubkeyHex;
    final unread = myPubkey == null
        ? 0
        : ref.watch(unreadNotificationCountProvider(myPubkey));
    // Resolve + clamp the FAB position so it stays fully on-screen across
    // rotations / keyboard insets.
    final base = _fabOffset ?? _defaultFabOffset(size, pad);
    final pos = Offset(
      base.dx.clamp(_fabMargin, size.width - _fabSize - _fabMargin),
      base.dy.clamp(
        pad.top + _fabMargin,
        size.height - _navBarHeight - pad.bottom - _fabSize - _fabMargin,
      ),
    );
    // Immersive browse: hide the bottom nav + FAB when the user scrolls down
    // (gated by the local immersive toggle). Only the bottom nav + FAB live
    // here; each page's top app bar is handled by ImmersiveScaffold.
    final hideBars =
        ref.watch(immersiveBrowseProvider) &&
        !ref.watch(appBarsVisibleProvider);
    const animDuration = Duration(milliseconds: 220);
    return Stack(
      children: <Widget>[
        Scaffold(
          body: shell,
          bottomNavigationBar: AnimatedContainer(
            // Collapse the nav bar to 0 height when hidden — the body extends
            // to the bottom edge. ClipRect hides the (still-laid-out) bar
            // content during the shrink.
            duration: animDuration,
            curve: Curves.easeOut,
            height: hideBars ? 0 : _navBarHeight,
            child: ClipRect(
              child: NavigationBar(
                selectedIndex: shell.currentIndex,
                onDestinationSelected: (int index) {
                  // Switching tabs restores the chrome so the new page isn't
                  // stuck with the previous page's hidden state.
                  ref.read(appBarsVisibleProvider.notifier).setVisible(true);
                  shell.goBranch(
                    index,
                    initialLocation: index == shell.currentIndex,
                  );
                },
                destinations: <NavigationDestination>[
                  const NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: '首页',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.search),
                    selectedIcon: Icon(Icons.search),
                    label: '搜索',
                  ),
                  NavigationDestination(
                    // Red count badge when there are unread notifications; a plain
                    // icon when 0 (no clutter — DESIGN §2 "简约 / 不打扰").
                    icon: unread > 0
                        ? Badge(
                            label: Text(unread > 99 ? '99+' : '$unread'),
                            child: const Icon(Icons.notifications_outlined),
                          )
                        : const Icon(Icons.notifications_outlined),
                    selectedIcon: unread > 0
                        ? Badge(
                            label: Text(unread > 99 ? '99+' : '$unread'),
                            child: const Icon(Icons.notifications),
                          )
                        : const Icon(Icons.notifications),
                    label: '通知',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: '我的',
                  ),
                ],
              ), // NavigationBar
            ), // ClipRect
          ), // AnimatedContainer
        ), // Scaffold
        // Draggable compose FAB. Tap = open compose; drag = reposition
        // (persisted). Lets the user move it off any sheet/menu/popup that
        // would otherwise be occluded by a fixed bottom-right button.
        // In immersive mode it shrinks out with the chrome on scroll-down.
        Positioned(
          left: pos.dx,
          top: pos.dy,
          child: AnimatedScale(
            scale: hideBars ? 0 : 1,
            duration: animDuration,
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: hideBars ? 0 : 1,
              duration: animDuration,
              child: _buildFab(context),
            ),
          ),
        ),
        if (_showOnboarding) OnboardingOverlay(onDone: _finishOnboarding),
      ],
    );
  }

  Widget _buildFab(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Tap and pan compete in the gesture arena: a touch that moves beyond
      // the slop becomes a drag (onTap won't fire); a quick tap fires onTap.
      onTap: () => context.push('/compose'),
      onPanUpdate: (details) {
        setState(() {
          _fabOffset = (_fabOffset ?? Offset.zero) + details.delta;
        });
      },
      onPanEnd: (_) => _persistFabOffset(),
      child: Container(
        width: _fabSize,
        height: _fabSize,
        decoration: BoxDecoration(
          color: CostrColors.of(context).brand,
          shape: BoxShape.circle,
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: CostrLogo(size: 26, color: CostrColors.of(context).onBrand),
      ),
    );
  }
}

/// Notification center placeholder (P4 will fill this in).
