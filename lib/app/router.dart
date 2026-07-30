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
import '../features/settings/settings_page.dart';
import '../features/search/search_page.dart';
import '../models/event.dart';
import '../widgets/costr_logo.dart';
import 'providers.dart';
import 'theme.dart';

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
        path: '/profile/edit',
        builder: (BuildContext context, GoRouterState state) => const EditProfilePage(),
      ),
      GoRoute(
        path: '/settings',
        builder: (BuildContext context, GoRouterState state) => const SettingsPage(),
      ),
      GoRoute(
        path: '/about',
        builder: (BuildContext context, GoRouterState state) => const AboutPage(),
      ),
      GoRoute(
        path: '/settings/notifications',
        builder: (BuildContext context, GoRouterState state) => const NotificationSettingsPage(),
      ),
      GoRoute(
        path: '/settings/account',
        builder: (BuildContext context, GoRouterState state) => const _PlaceholderPage(title: '账号与身份'),
      ),
      GoRoute(
        path: '/settings/relays',
        builder: (BuildContext context, GoRouterState state) => const _PlaceholderPage(title: '服务器节点'),
      ),
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            AppShell(navigationShell: navigationShell),
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
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      floatingActionButton: FloatingActionButton(
        backgroundColor: CostrColors.brand,
        child: const CostrLogo.light(size: 26),
        onPressed: () => context.push('/compose'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (int index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.search),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: '通知',
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

/// Notification center placeholder (P4 will fill this in).
class _NotificationsPlaceholder extends StatelessWidget {
  const _NotificationsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '还没有通知。\n有人 @你、回复、喜欢你的帖子时会出现在这里。',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

/// Simple placeholder for not-yet-implemented settings sub-pages.
class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(child: Text('$title（即将支持）', style: Theme.of(context).textTheme.bodyMedium)),
  );
}

/// Notification center placeholder (P4 will fill this in).
