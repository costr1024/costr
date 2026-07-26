/// App routing.
library;

import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';

import '../features/feed/feed_page.dart';
import '../features/profile/profile_page.dart';
import '../features/compose/compose_page.dart';

final GlobalKey<NavigatorState> rootNavigator =
    GlobalKey<NavigatorState>(debugLabel: 'root');

final GoRouter router = GoRouter(
  navigatorKey: rootNavigator,
  initialLocation: '/feed',
  routes: <RouteBase>[
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
