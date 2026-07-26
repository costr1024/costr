# costr

**costr** = Chinese Nostr。一个用 Flutter 构建的跨平台 Nostr 社交客户端，单一代码库覆盖
Android、iOS、Windows、macOS、Linux 五端。

## 当前状态

**v1** —— 私钥登录（NIP-19 `nsec1`）+ 公开帖子信息流（全球流 / 关注流）。暂不支持发帖。

已实现：
- **身份**：粘贴 `nsec1` 私钥 → 用 BIP-340 `getPublicKey` 派生 x-only 公钥 → 存入 OS 安全存储，下次启动自动登录。
- **信息流**：在 **全球**（kind 1 实时广播流，有界）和 **关注**（来自你的 NIP-02 kind 3 联系人列表中作者的 kind 1）之间切换。
- **中继池**：多中继 fan-out，按 event id 去重，断线指数退避重连，重连后自动重发活跃订阅。
- **事件存储**：内存单源，按 id 去重，按时间倒序，上限 5000 条淘汰最旧。
- **界面**：登录页、信息流页（中继状态 chip + 空/错误态）、个人页（npub/pubkey + 登出）、发帖占位页。

## 协议

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) —— events、REQ/EVENT/CLOSE/EOSE/NOTICE。
- [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) —— `nsec1`/`npub1`/`note1` bech32 编码（纯 Dart 自实现，因为 pub 上的 `bech32` 包不兼容 Dart 3.x）。
- [NIP-02](https://github.com/nostr-protocol/nips/blob/master/02.md) —— 联系人列表（kind 3），作为关注列表来源。
- [BIP-340](https://bips.xyz/340) —— secp256k1 Schnorr（用 `bip340` 包）做公钥派生。签名功能随发帖特性一同加入。

## 环境要求

- Flutter 3.44.x（stable）。SDK 装在 `/home/user/flutter`；确保 `/home/user/flutter/bin` 在 PATH 中
  （`export PATH="/home/user/flutter/bin:$PATH"`）。
- Linux 桌面构建还需：clang、cmake、ninja-build、libgtk-3-dev、pkg-config、mesa-utils，以及
  **libsecret-1-dev + libglib2.0-dev**（后者是 `flutter_secure_storage_linux` 构建必需）。
- Android：Android SDK（当前环境未配置）。
- iOS：macOS + Xcode（Linux 上无法构建）。

## 快速开始

```bash
flutter pub get
flutter run -d linux        # 或：android / ios / macos / windows
flutter doctor
```

首次启动会要求粘贴 `nsec1` 私钥。私钥存入 OS 密钥库（Android Keystore / iOS Keychain / Linux 桌面用 libsecret），从不离开本机。

## 默认中继

- `wss://relay.bostr.online/`
- `wss://relay.ditto.pub/`

## 目录结构

```
lib/
  main.dart              入口（ProviderScope）
  app/                   app 外壳、主题、路由、providers（riverpod）
    app.dart             以 bootstrap 门控的 MaterialApp.router
    router.dart          GoRouter + 登录重定向（/login /feed /profile /compose）
    providers.dart       identity、relayPool、bootstrap、eventStore、feedMode、
                         followingState、feedSubscription、currentFeed、relayStatus
  models/                NIP-01 Event（解析、p-tag、验签 hook）
  nostr/
    identity.dart        Identity（nsec1 → 公钥，bip340）
    relay_client.dart    WebSocket 中继连接（长生命周期广播，EOSE/NOTICE）
    relay_pool.dart      RelayPool（去重、重连、重发、RelayState）
    event_store.dart     内存存储（去重/排序/上限）
  services/
    secure_storage_service.dart   nsec 持久化（libsecret 不可用时降级）
  features/
    auth/login_page.dart      nsec 输入 + 校验 + 持久化
    feed/feed_page.dart       全球/关注切换、列表、状态、空态
    feed/event_card.dart      npub + 相对时间 + 正文
    profile/profile_page.dart npub/pubkey + 登出
    compose/compose_page.dart 占位（发帖后续版本）
  utils/
    bech32_codec.dart    纯 Dart BIP-173 bech32
    nip19.dart           nsec/npub/note ↔ hex
test/             单元与 widget 测试（49 个）
```

## 验证

```bash
flutter analyze          # 0 issue
flutter test             # 49 个测试
flutter build linux --debug
```

## v1 已知限制

- 到达事件**不做** Schnorr 验签（firehose 性能）；`Event.isSignatureValid` hook 已接线但默认关闭。
- 全球流是实时的（靠 5000 条存储上限兜底），不是 EOSE 后关闭的有界快照。
- 关注列表可能 stale（如果你的 kind 3 最后更新在默认中继集之外的中继上）。
- 单 isolate 做 JSON 解析 + 去重；极高事件速率下 UI 可能卡顿（v1 有界可接受，后续可 isolate 化）。
- Linux 桌面安全存储需要运行中的 keyring（GNOME Keyring / KDE Wallet）。无 keyring 时降级为"重启即登出"，不会崩溃。

## 许可证

待定。
