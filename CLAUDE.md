# CLAUDE.md

Project guide for Claude Code working in `costr`.

## What this is

A cross-platform Nostr social client (text notes, NIP-01 kind 1) built with
Flutter, targeting Android, iOS, Windows, macOS, and Linux from a single
Dart codebase.

## Tech stack

- **Framework:** Flutter 3.44.x (stable)
- **Language:** Dart
- **Platforms:** android, ios, windows, macos, linux (web not a target)
- **Nostr:** pure-Dart relay/subscription/signing layer under `lib/nostr/`

## Environment

- Flutter SDK installed at `/home/user/flutter` (added to PATH in shell profile)
- Git repo root: `/home/user/costr`
- GitHub remote: `origin` -> `https://github.com/costr1024/costr.git` (branch `main`)
- Permissions: Bash, WebSearch, and WebFetch are default-allowed (see `.claude/settings.json`)

## Commands

```bash
flutter pub get          # install/refresh deps
flutter run              # run on attached device
flutter run -d linux     # run desktop build
flutter test             # run tests
flutter analyze          # static analysis
flutter doctor           # check toolchain
```

## Conventions

- Keep platform-specific code in `android/`, `ios/`, `windows/`, `macos/`, `linux/` (generated, rarely hand-edited).
- All app logic stays under `lib/` so it is shared across all 5 targets.
- Nostr protocol code is isolated under `lib/nostr/` so it can be reused/tested independently of UI.
- Follow `dart format` and resolve all `flutter analyze` warnings before committing.
- Commit messages end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Notes

- iOS builds require macOS + Xcode; do not attempt on Linux.
- Do not commit secrets, `.env`, keystore files, or platform `local.properties`.
