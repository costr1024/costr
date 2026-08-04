/// App root: gates the router on [bootstrapProvider] so the identity load +
/// relay connect finish before any redirect resolves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'router.dart';
import 'theme.dart';

/// Material/Cupertino/Widgets localization delegates + supported locales.
/// Without these, Flutter's built-in text-selection toolbar (剪切/复制/粘贴/
/// 全选) and other Material widgets fall back to English. Costr is Chinese-
/// first, so non-zh/en devices default to Chinese.
const List<LocalizationsDelegate<dynamic>> _localizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

const List<Locale> _supportedLocales = <Locale>[
  Locale('zh', 'CN'),
  Locale('en', 'US'),
];

Locale _localeResolutionCallback(Locale? device, Iterable<Locale> supported) {
  for (final l in supported) {
    if (l.languageCode == device?.languageCode) return l;
  }
  return const Locale('zh', 'CN');
}

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
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        localizationsDelegates: _localizationsDelegates,
        supportedLocales: _supportedLocales,
        localeResolutionCallback: _localeResolutionCallback,
        home: const _Splash(),
      ),
      error: (Object error, StackTrace _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        localizationsDelegates: _localizationsDelegates,
        supportedLocales: _supportedLocales,
        localeResolutionCallback: _localeResolutionCallback,
        home: _ErrorView('$error'),
      ),
      data: (_) {
        final router = ref.watch(routerProvider);
        // Global font scale (设置 → 字号): apply via MediaQuery.textScaler so
        // all text (including the OS text-selection toolbar and Material
        // widgets) scales uniformly. Rebuilds when the user picks a level.
        final factor = ref.watch(textScaleFactorProvider);
        return MaterialApp.router(
          title: 'Costr',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          routerConfig: router,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: _localizationsDelegates,
          supportedLocales: _supportedLocales,
          localeResolutionCallback: _localeResolutionCallback,
          builder: (BuildContext context, Widget? child) {
            // Clamp to a sane range to avoid pathological overflow; the three
            // levels (1.0/1.2/1.44) are all within bounds.
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(factor.clamp(0.8, 2.0)),
              ),
              child: child!,
            );
          },
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

class _ErrorView extends ConsumerWidget {
  const _ErrorView(this.message);
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('启动失败：$message', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => ref.invalidate(bootstrapProvider),
                child: const Text('重试'),
              ),
              const SizedBox(height: 10),
              // Escape hatch for the overlay-upgrade wedge: delete the local
              // cache files (login key is in the OS keystore, NOT this DB, so
              // nothing is lost except cached posts) and bootstrap again.
              OutlinedButton(
                onPressed: () async {
                  await resetLocalCacheFiles();
                  ref.invalidate(localCacheProvider);
                  ref.invalidate(bootstrapProvider);
                },
                child: const Text('重置本地缓存并重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
