# costr

A cross-platform Nostr social client (kind 1) built with Flutter.

Targets: Android, iOS, Windows, macOS, Linux.

## Status

Bootstrapping. Project scaffold, dependency manifest, and directory layout are
in place; core features are being defined.

## Requirements

- Flutter 3.44.x (stable channel)
- For Android builds: Android SDK
- For iOS builds: Xcode (macOS only)
- For desktop builds: platform toolchains (see `flutter doctor`)

## Getting started

```bash
flutter pub get
flutter run -d <device>
flutter doctor
```

## Project layout

```
lib/              Dart application code
  main.dart       entry point
  app/            app shell, theming, routing
  models/         NIP-01 event / data models
  nostr/          relay connection, subscriptions, signing
  features/       feature modules (feed, profile, compose, ...)
  widgets/        reusable UI components
  services/       state management, storage, caching
  utils/          helpers
test/             unit & widget tests
```

## License

TBD.
