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
import '../features/profile/edit_profile_page.dart';
import '../features/profile/profile_page.dart';
import '../features/search/search_page.dart';
import '../models/event.dart';
import 'providers.dart';

final GlobalKey<NavigatorState> rootNavigator =
    GlobalKey<NavigatorState>(debugLabel: 'root');

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
        builder: (BuildContext context, GoRouterState state) => ProfilePage(
          pubkey: state.pathParameters['pubkey'],
        ),
      ),
      GoRoute(
        path: '/n/:id',
        builder: (BuildContext context, GoRouterState state) => PostDetailPage(
          id: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/search',
        builder: (BuildContext context, GoRouterState state) => const SearchPage(),
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (BuildContext context, GoRouterState state) => const EditProfilePage(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            AppShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/feed',
                builder: (BuildContext context, GoRouterState state) =>
                    const FeedPage(),
              ),
            ],
          ),
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

/// Shared bottom-nav shell wrapping Feed + Profile. Persists across the two
/// tabs and preserves each tab's state (scroll position, etc.).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (int index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
