/// Routing + auth redirect.
///
/// The router is built from a provider so the redirect can read the identity
/// provider. [GoRouterRefreshNotifier] bridges identity state changes (login /
/// logout) into GoRouter's refreshListenable so redirects re-evaluate.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_page.dart';
import '../features/compose/compose_page.dart';
import '../features/feed/feed_page.dart';
import '../features/profile/profile_page.dart';
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
        path: '/feed',
        builder: (BuildContext context, GoRouterState state) =>
            const FeedPage(),
      ),
      GoRoute(
        path: '/profile',
        builder: (BuildContext context, GoRouterState state) =>
            const ProfilePage(),
      ),
      GoRoute(
        path: '/compose',
        builder: (BuildContext context, GoRouterState state) =>
            const ComposePage(),
      ),
    ],
  );
});
