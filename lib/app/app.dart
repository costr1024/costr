/// App root: gates the router on [bootstrapProvider] so the identity load +
/// relay connect finish before any redirect resolves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'router.dart';
import 'theme.dart';

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On background: do NOTHING to the in-memory cache or feed — the EventStore
    // (non-autoDispose) and relay pool persist, so the user's already-loaded
    // feed stays. On foreground: just nudge any dropped relay sockets to
    // reconnect (the OS suspends websockets while backgrounded). The event
    // store is NOT cleared and the feed is NOT re-fetched — only incremental
    // new events merge in via dedup. This matches DESIGN §10's intent (no
    // visible reload on resume) while never clearing the in-memory cache.
    if (state == AppLifecycleState.resumed) {
      ref.read(relayPoolProvider).reconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(bootstrapProvider);
    return bootstrap.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const _Splash(),
      ),
      error: (Object error, StackTrace _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: _ErrorView('$error'),
      ),
      data: (_) {
        final router = ref.watch(routerProvider);
        return MaterialApp.router(
          title: 'Costr',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          routerConfig: router,
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('启动失败：$message'),
        ),
      ),
    );
  }
}
