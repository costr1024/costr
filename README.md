# costr

A cross-platform Nostr social client built with Flutter, targeting Android,
iOS, Windows, macOS, and Linux from a single Dart codebase.

## Status

**v1** — private-key login (NIP-19 `nsec1`) + a public text-note feed with
global and following timelines. No posting/compose yet.

Implemented:
- Identity: paste an `nsec1` private key → derive the x-only pubkey
  (BIP-340 `getPublicKey`) → persist in OS secure storage (auto-login).
- Feed: segmented toggle between **全球** (global kind-1 firehose, live, capped)
  and **关注** (kind-1 from your NIP-02 kind-3 contact list).
- Relay pool: multi-relay fan-out with per-event-id dedup, exponential-backoff
  reconnect, and re-issue of active subscriptions on reconnect.
- Event store: in-memory, dedup by id, newest-first, capped at 5000.
- UI: login page, feed page (relay status chip + empty/error states),
  profile page (npub/pubkey + logout), compose placeholder.

## Protocols

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) —
  events, REQ/EVENT/CLOSE/EOSE/NOTICE.
- [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) —
  `nsec1`/`npub1`/`note1` bech32 (pure-Dart codec; the `bech32` pub package
  is incompatible with Dart 3.x).
- [NIP-02](https://github.com/nostr-protocol/nips/blob/master/02.md) —
  contact list (kind 3) as the source of follows.
- [BIP-340](https://bips.xyz/340) — secp256k1 Schnorr (via the `bip340`
  package) for pubkey derivation. Signing arrives with the compose feature.

## Requirements

- Flutter 3.44.x (stable). SDK installed at `/home/user/flutter`; ensure
  `/home/user/flutter/bin` is on your PATH (`export PATH="/home/user/flutter/bin:$PATH"`).
- Linux desktop builds additionally need: clang, cmake, ninja-build,
  libgtk-3-dev, pkg-config, mesa-utils, and **libsecret-1-dev + libglib2.0-dev**
  (the latter are required by `flutter_secure_storage_linux`).
- Android: Android SDK (not configured in this environment).
- iOS: macOS + Xcode (cannot build on Linux).

## Getting started

```bash
flutter pub get
flutter run -d linux        # or: android, ios, macos, windows
flutter doctor
```

On first launch you'll be asked to paste an `nsec1` private key. The key is
stored in the OS keystore (Android Keystore / iOS Keychain / libsecret on
Linux desktop) and never leaves the device.

## Default relays

- `wss://relay.bostr.online/`
- `wss://relay.ditto.pub/`

## Project layout

```
lib/
  main.dart              entry point (ProviderScope)
  app/                   app shell, theme, routing, providers (riverpod)
    app.dart             bootstrap-gated MaterialApp.router
    router.dart         GoRouter + auth redirect (/login /feed /profile /compose)
    providers.dart      identity, relayPool, bootstrap, eventStore, feedMode,
                        followingState, feedSubscription, currentFeed, relayStatus
  models/                NIP-01 Event (parse, p-tags, verify hook)
  nostr/
    identity.dart        Identity value (nsec1 -> pubkey, bip340)
    relay_client.dart    WebSocket relay connection (long-lived broadcast, EOSE/NOTICE)
    relay_pool.dart      RelayPool (dedup, reconnect, re-issue, RelayState)
    event_store.dart    in-memory store (dedup/sort/cap)
  services/
    secure_storage_service.dart   nsec persistence (libsecret degrade-safe)
  features/
    auth/login_page.dart      nsec input + validate + persist
    feed/feed_page.dart       global/following toggle, list, status, empty states
    feed/event_card.dart      npub + relative time + content
    profile/profile_page.dart npub/pubkey + logout
    compose/compose_page.dart placeholder (posting comes later)
  utils/
    bech32_codec.dart    pure-Dart BIP-173 bech32
    nip19.dart           nsec/npub/note ↔ hex
test/             unit & widget tests (49 tests)
```

## Verification

```bash
flutter analyze          # 0 issues
flutter test             # 49 tests
flutter build linux --debug
```

## Known v1 limitations

- Arrival events are **not** Schnorr-verified (perf at firehose rates); the
  `Event.isSignatureValid` hook is wired but off by default.
- Global feed is live (bounded by the 5000-event store), not an EOSE-closed
  snapshot.
- The follows list may be stale if your kind-3 was last updated on relays
  outside the default set.
- Single-isolate JSON decode + dedup; very high event rates can jank the UI
  (v1 is bounded by the store cap; isolate-ization is a later optimization).
- Linux desktop secure storage needs a running keyring (GNOME Keyring / KDE
  Wallet). Without one it degrades to "logged out on restart" rather than crash.

## License

TBD.
