# Costr

**Costr = Chinese Nostr** —— 一个更适合中文用户的去中心化社交客户端，单一代码库
（Flutter）覆盖 Android、iOS、Windows、macOS、Linux 五端。你自己就是一个广播站：
帖子分布在全球多台服务器上，没有任何人——包括 Costr 自己——能删除、封号或限流。

---

## 下载

| 平台 | 版本 | 文件 |
| --- | --- | --- |
| Android | **0.1.5-beta** | `app-release.apk`（≈71 MB，arm/x64 split per ABI） |

> 0.1 beta 为首个公开测试版。Android 包 `applicationId = com.costr.costr`，用正式
> release keystore 自签（SHA-256 `4851d3b7…95eeaa`）。安装需在系统设置中允许「未知来源」。
> 桌面端（Linux/Windows/macOS）与 iOS 暂未发版，可从源码自行编译。
>
> release 包曾缺 `INTERNET` 权限（仅 debug 变体声明），导致 release 连不上中继——
> 已把 `uses-permission INTERNET` 提到主 manifest，对所有构建变体生效。选图/视频/文件
> 走 SAF 系统选择器，无需额外存储或相机权限。

---

## 核心设计思路与产品理念

Costr 的设计原则写在其 [设计宪法](docs/DESIGN.md) 里，核心可归纳为：

1. **无审查是第一卖点**。帖子分布在全网多台中继上，没有任何人能删、能封、能限流。
   这是去中心化带来的硬保证，也是 Costr 存在的理由。
2. **匿名，一把钥匙就是身份**。不用手机号、不用邮箱、不实名。一串 `nsec1` 钥匙就是
   整个账号，不绑定任何现实身份。私钥只在本机、不上传任何服务器；想更进一步隐身，
   搭配 VPN 代理服务用，中继连你的真实网络地址都看不到。
3. **复刻 X（推特）的 UI 语言**。布局、信息架构、配色、动作栏都对标 X 浅色风格
   （纯白底 + 黑主色），让从 X 迁来的用户零学习成本。技术名词（中继、npub、NIP、kind）
   **一律不出现在主界面**，需要时用比喻说人话（见关于页的「发件箱 / 收件箱」比喻）。
4. **开箱即用、克制不打扰**。默认值即最佳值，不给用户一堆开关去调。信息是公开的，
   但体验是安静的——通知聚合、批量刷新、后台不订阅、回前台不整页 reload。
5. **性能从设计阶段就守**。订阅有界、去重、聚合优先、批量更新、后台不持有 WebSocket、
   firehose 默认不验签——见 [性能约束](docs/DESIGN.md#10-性能约束设计阶段就要守)。

设计优先级裁决规则：**复刻 X > 简约年轻 > 开箱即用 > 性能 > 个性化**。冲突时砍掉低优先级的。

---

## 与其他 Nostr 客户端的差异

| 维度 | Costr | Amethyst / Damus / Jumble |
| --- | --- | --- |
| 目标用户 | 中国年轻用户（用过 X、不懂去中心化） | 英文 / 通用社区 |
| UI 语言 | 复刻 X 浅色风格，全中文文案，技术词不上主界面 | 各自风格，常见技术词暴露 |
| 语言过滤 | 首页内建 🌐/🇨🇳/🇬🇧/🇯🇵 启发式过滤（假名优先判日文） | 多无内建语言过滤 |
| 大陆可达 | 默认中继含 `damus.bostr.online` 反代便于直连；NIP-42 AUTH 已支持 | 默认中继常被墙 |
| 关注流拉取 | 按每个 followee 的 NIP-65 outbox 定向拉取（分组、30 上限、回落广播） | 多为广播到默认中继 |
| 单用户主页 | outbox 定向拉取（`fetchFromUrls` + `since` 增量） | 类似 outbox 路由 |
| 发布可靠性 | per-relay 1s/2s/3s 重试 + 全失败存草稿跨会话补发 | 多为单次广播 |
| 自定义表情/打闪 | NIP-30 + NIP-57 Zap（中文文案：打闪 / 聪） | 视客户端而定 |
| 本地缓存 | drift/SQLite，社交图谱 gated 持久化 + 30 天清理 | 各有缓存策略 |
| 代码库 | Flutter 单码库五端 | Android 原生 / Flutter / Web 各异 |

Costr 不重新发明 Nostr 协议——纯 Dart 协议层实现遵循 NIP 规范，交互与渲染先参考
Amethyst/Jumble 的成熟做法（见记忆 `reference-nostr-clients`），再按 X 风格与中文用户
偏好裁剪。

---

## 核心界面

> 交互稿见 [docs/ui_demo.html](docs/ui_demo.html)（浏览器打开即用，`1/2/3/4` 切 tab、
> `C` 发帖、`L` 登录、`Esc` 返回）。下面是核心界面的 SVG 概览图，配色取自设计宪法
> §3（纯白底 + 黑 `#0F1419` 主色）。

### 4-tab + FAB 主架构

![Costr 首页：顶栏 logo + 全球/关注切换 + 帖子流 + FAB + 4-tab 底栏](docs/img/feed-overview.svg)

### 关注流的 NIP-65 outbox 路由

![关注 tab 按 followee outbox 定向拉取：分组连接、30 上限、回落广播](docs/img/outbox-routing.svg)

界面与流程清单：**首页**（全球/关注切换 + 语言过滤 + 帖子流）｜**搜索**（用户/帖子 NIP-50）
｜**通知**（全部/提及 + 聚合）｜**我的**（banner/头像/资料 + 帖子/回帖/关注/关注者/收藏）
｜**发帖**（FAB，带 Blossom 媒体上传）｜**帖子详情**（回复线程）｜**登录/注册**（多步向导）
｜**设置**（通知/账号/服务器节点/关于/退出）｜**关于**（产品理念 + Nostr 原理图）。

---

## 技术架构

### 分层

```
lib/
  app/        app 外壳：GoRouter 路由、Riverpod providers、X 风格主题
  models/     NIP-01 Event（解析、p-tag、hashtags、computeId、验签 hook）
  nostr/      纯 Dart 协议层（可独立于 UI 复用/测试）
    identity.dart        Identity（nsec1 → BIP-340 公钥，signEvent）
    actions.dart         NostrActions（reply/repost/quote/reaction/follow/relayList）
    nip44.dart           NIP-44 v2 加密（纯 Dart，私人书签用）
    relay_client.dart    WebSocket 中继连接（长生命周期广播，EOSE/AUTH，重连退避）
    relay_pool.dart      RelayPool（去重合并流、重发、NIP-42 AUTH、fetchFromUrls outbox）
    outbox_router.dart   ★ 关注流 NIP-65 outbox 路由（持久分组连接 + fetchOnce 分页）
    event_store.dart     内存存储（去重/排序/上限 5000）
  services/   drift/SQLite 本地缓存、NIP-57 打闪、Blossom 上传、媒体下载、安全存储
  features/   feed / profile / compose / notifications / search / settings / auth
  widgets/    markdown 正文、动作栏、头像、Costr logo、新手引导
  utils/      bech32 / nip19 / language
```

### 信息流拉取（关键设计）

- **全球 tab**：`feedSubscriptionProvider` → `pool.request({kinds:[0,1,6,7], limit:200})`
  广播到 8 台默认中继，**live 不 close-on-EOSE**（实时 reaction/metadata 持续到达）。
- **关注 tab**：`followingOutboxProvider` → `OutboxRouter` 按 followee 的 kind-10002 outbox
  分组定向拉取（详见上面的 SVG）。事件经 `EventStoreNotifier.ingest` 入内存库，`currentFeedEventsProvider`
  既有 `follows.contains(pubkey)` 过滤复用，UI 零改动。
- **个人主页**：`userPostsProvider` → `fetchFromUrls` 临时连接对方 outbox read 中继
  （`since` 增量，250ms 去抖流式 yield），无清单回落广播。
- **本地缓存**：drift/SQLite，社交图谱 gated 持久化（follows + self 的 kind-1/7 落库，
  全球 firehose 不落库），replaceable 事件恒缓存；冷启动 hydration 秒出。

### 状态管理

Riverpod 3。长生命周期（relay pool、event store、identity）用非 autoDispose，
导航间保持。`feedSubscriptionProvider` / `followingOutboxProvider` 是 void provider，
被 `currentFeedEventsProvider` watch 续命，mode/follows 变化时重建（onDispose 关旧开新）。

### 支持的 NIP

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) — events / REQ / EVENT / CLOSE / EOSE（EVENT 帧数组与对象两种形式都解析）
- [NIP-02](https://github.com/nostr-protocol/nips/blob/master/02.md) — 联系人列表（kind 3，关注列表来源）
- [NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md) — 域名验证
- [NIP-09](https://github.com/nostr-protocol/nips/blob/master/09.md) — 删除（kind 5）
- [NIP-10](https://github.com/nostr-protocol/nips/blob/master/10.md) — 回复 e-tag 语义
- [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) — 收件箱私信路由（仅留口子，DM 不做）
- [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) — bech32 编码（nsec / npub / note / nevent / nprofile，纯 Dart 自实现）
- [NIP-25](https://github.com/nostr-protocol/nips/blob/master/25.md) + [NIP-30](https://github.com/nostr-protocol/nips/blob/master/30.md) — reaction + 自定义表情
- [NIP-27](https://github.com/nostr-protocol/nips/blob/master/27.md) — 事件引用嵌入（nevent / note）
- [NIP-38](https://github.com/nostr-protocol/nips/blob/master/38.md) — 用户状态（kind 30315）
- [NIP-42](https://github.com/nostr-protocol/nips/blob/master/42.md) — AUTH 认证
- [NIP-44](https://github.com/nostr-protocol/nips/blob/master/44.md) — v2 加密（私人书签用）
- [NIP-50](https://github.com/nostr-protocol/nips/blob/master/50.md) — 全文搜索
- [NIP-51](https://github.com/nostr-protocol/nips/blob/master/51.md) — 关注集 / 兴趣集 / 屏蔽列表 / 书签（kind 30000 / 30015 / 10015 / 10000 / 10003 / 30003，含 NIP-44 私密列表）
- [NIP-57](https://github.com/nostr-protocol/nips/blob/master/57.md) — 打闪 Zap
- [NIP-65](https://github.com/nostr-protocol/nips/blob/master/65.md) — outbox 路由（kind 10002）
- [NIP-92](https://github.com/nostr-protocol/nips/blob/master/92.md) — imeta 媒体元数据
- [BIP-340](https://bips.xyz/340) — secp256k1 Schnorr（公钥派生 / 签名）
- [BUD-02 / BUD-11](https://github.com/hzrd149/blossom) — Blossom 媒体上传

---

## 默认中继

主池（8 台，广播用）：`damus.bostr.online/`（damus 反代，便于大陆直连）·`relay.gulugulu.moe/`·
`relay.ditto.pub/`（接受写入、被广泛订阅）·`relay.bostr.online/`（写入需 NIP-42 认证 + 白名单）·
`wheat.happytavern.co/`·`relay.nostr.net/`·`relay.0xchat.com/`·`top.testrelay.top/`。

搜索专用（NIP-50，独立 `searchPoolProvider`）：`relay.ditto.pub/`·`search.nos.today/`。
索引中继（陌生用户资料补漏）：`indexer.coracle.social/`·`user.kindpag.es/`。

中继列表同时是 NIP-65（kind 10002）用户元数据——每次冷启动后台签发一次 kind 10002
（replaceable，重复发布只替换不堆积），让其他客户端按 outbox/inbox 模型找到你的中继。

---

## 开发者指导手册

### 环境要求

- Flutter 3.44.x（stable）。SDK 装在 `/home/user/flutter`，确保
  `/home/user/flutter/bin` 在 PATH 中（`export PATH="/home/user/flutter/bin:$PATH"`）。
- Linux 桌面构建还需：clang、cmake、ninja-build、libgtk-3-dev、pkg-config、mesa-utils，
  以及 **libsecret-1-dev + libglib2.0-dev**（`flutter_secure_storage_linux` 构建必需）。
- Android：Android SDK。iOS：macOS + Xcode（Linux 上无法构建）。

### 常用命令

```bash
flutter pub get          # 安装/刷新依赖
flutter run -d linux     # 桌面运行（或 android / macos / windows）
flutter test             # 全套测试（209 个）
flutter analyze          # 静态分析（须 0 警告）
dart format lib/ test/   # 格式化
flutter build linux      # 桌面构建验证
```

> 小内存机器（如 2 vCPU / 7GB / 无 swap）跑 `flutter run` 调试编译会 OOM——这类机器
> 直接跑已构建的二进制：`./build/linux/x64/debug/bundle/costr`。

### 约定

- 平台特定代码只在 `android/` `ios/` `windows/` `macos/` `linux/`（生成产物，极少手改）。
- 全部应用逻辑在 `lib/`，五端共享。Nostr 协议代码隔离在 `lib/nostr/`，可独立于 UI 复用/测试。
- 提交前必须：`flutter analyze` 0 警告 + `flutter test` 全绿 + 目标平台构建通过。
- `dart format` 后再提交。提交信息末尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。
- **每开发一个新功能前先回看 [docs/DESIGN.md](docs/DESIGN.md) 与 [docs/ui_demo.html](docs/ui_demo.html)**，
  确认布局/配色/文案/信息密度没跑偏；功能上线时 demo 对应屏幕同步改成真实效果。
- **每个代码 commit 必须同步更新 README** 对应说明（`readme-per-commit` 规则）。
- 不提交 secrets / `.env` / keystore / `local.properties`。

### 新增一个 Nostr 事件类型 / 界面的典型路径

1. `lib/models/event.dart` 加 kind 常量 + 便捷 getter（如 `isTextNote`）。
2. `lib/nostr/actions.dart` 加签名构造（`NostrActions`，仿 `reaction`/`repost`）。
3. `lib/app/providers.dart` 加 provider（缓存优先：SQLite → 内存 → relay 刷新），
   事件经 `EventStoreNotifier` 入库（replaceable 用 `_isReplaceableKind` 分支；不可变事件
   走社交图谱 gated `_persist`）。
4. `lib/features/<area>/` 加页面/组件，`lib/widgets/markdown_content.dart` 处理正文渲染。
5. `docs/DESIGN.md` + `docs/ui_demo.html` 同步该屏幕，README 同步该功能。
6. `test/` 加单测（纯函数抽出来测，仿 `outbox_router_test.dart` / `event_store_test.dart`）。

### 测试

`test/` 下 209 个测试覆盖：纯协议层（bech32/nip19/nip44/identity/event）、relay 池与
outbox router（`_FakeRelay` 注入，无网络）、event store 去重/排序/上限、feed 过滤与冻结、
markdown 渲染（九宫格/自定义表情/mention）、语言检测、打闪、widget 渲染。新增功能请抽纯函数
单测覆盖，避免依赖网络/UI。

---

## 当前状态

**v0.1.5-beta** —— 完整的 Nostr 社交客户端：私钥登录 / 创建账号（NIP-19 `nsec1`）、
发帖/回复/转发/引用/reaction、全球/关注信息流、用户主页（帖子/回帖/关注/关注者/收藏）、
搜索、通知中心、本地 SQLite 缓存（冷启动秒出）。单代码库覆盖 Android、iOS、Windows、macOS、Linux。

<details>
<summary><b>已实现功能详情（点击展开）</b></summary>

- **身份**：粘贴 `nsec1` → BIP-340 `getPublicKey` 派生公钥 → OS 安全存储，下次自动登录。创建账号多步向导（备份钥匙→设资料→完成），强制备份提示。
- **信息流**：**全球**（广播到默认中继，live）与**关注**（按 followee NIP-65 outbox 定向拉取，详见上方 SVG）切换。只显帖子（Amethyst 式事件类型门控：kind-7/3 不当帖显示）。repost 进信息流（kinds `[0,1,6,7]`，EventCard 渲染「↻ 转发」header + 嵌入被转帖）。
- **中继池**：多中继 fan-out，按 id 去重（`events` 流给全球流）；另开 `rawEvents`（不去重）给一次性定向拉取（kind-3、关注者 `#p`、NIP-50 搜索）。断线指数退避重连，重连后自动重发活跃订阅。`RelayClient.connect` 等 `channel.ready` 才标 connected（+10s 超时让被墙中继快速判离线）。
- **事件存储**：内存单源，按 id 去重，时间倒序，上限 5000 淘汰最旧。`ingest` 经 `_scheduleFlush` 200ms 去抖批量刷新（避免突发百条 jank）。
- **头像资料**：`metadataProvider` 是 StreamProvider——先 yield SQLite/内存缓存（即时），再异步拉 kind-0 刷新（按 `created_at` 不回退）。社交图谱资料预取（冷启动延迟 5s 对 follows+followers+self bulk REQ kind-0 落库）。
- **正文渲染**：GitHub 风格 markdown。多图九宫格、裸图片/视频 URL 当图渲染、NIP-92 imeta + `["image",url]`/`["video",url]` tag 跨协议去重、NIP-30 自定义表情 `:shortcode:` 内联、长帖折叠、空行保留（Amethyst 式）。NIP-19 npub/nprofile 提及 linkify。
- **标签与语言过滤**：NIP-12 `t` tag + 正文内联 `#hashtag`（支持中文），chip 点选过滤/长按关注。**关注 hashtag 存 NIP-51 kind-10015 + NIP-44 加密 content**（`[["t",…]]` JSON，对齐 Amethyst 的私密兴趣列表，迁移互通），同时只读聚合 kind-30015 命名兴趣集的明文 `t`。语言下拉 🌐/🇨🇳/🇬🇧/🇯🇵，假名优先判日文。
- **用户状态（NIP-38）**：kind-30315 短文本，信息流卡昵称下一行显示，自己主页内联编辑。
- **用户主页**：NestedScrollView（banner/头像可滚走 + TabBar 吸顶）+ sliver 根治 overflow。4+1 tab：帖子/回帖/关注/关注者/收藏。`userPostsProvider` StreamProvider：先 yield 内存+SQLite 快照，后台 NIP-65 outbox 定向拉取（`since` 增量，250ms 去抖流式 yield）。下拉刷新、发帖后立即可见。
- **帖子交互（X 风格）**：💬回复 / 🔁转发（菜单二选一：NIP-18 kind-6 / 引用）/ ❤️reaction（NIP-25+NIP-30，二次点击撤回签 kind-5）/ 🔖收藏（NIP-51 kind-10003，公开 + NIP-44 私密）/ ↗分享（njump.me）。帖子菜单 `⋮`：复制帖子 id（`nostr:nevent1`）/ 复制全文 / ⚡打闪 / 删除（自己的帖，NIP-09 kind-5）。
- **NIP-09 删除应用层隐藏**：收到 kind-5 删除事件时按作者校验（只能删自己的）应用：`a` 标签坐标（`K:pubkey:d`）删本地 replaceable 行 + 自己的 kind-30000 触发版本刷新、kind-10002 清 relay-list 缓存；`e` 标签按 id 从内存库 + SQLite 移除（信息流即时消失）。best-effort——并非所有中继支持删除，已传播的帖可能仍被其他客户端保留。
- **打闪 Zap（NIP-57）**：自定义聪 + 预设 chip + 留言 → 解析 lud16/lud06 → LNURL-pay → 签 kind-9734 → BOLT11 发票二维码 + 复制 + `lightning:` deeplink。`lib/services/zap.dart` 纯函数可单测。
- **NIP-27 事件引用**：发帖框粘 `nostr:nevent1`/`note1` 自动补 `e` mention tag；渲染端嵌引用卡。
- **发帖（Compose）**：FAB，字数计数，`Identity.signEvent` 签名 + 发布。EVENT 用对象形式（2026 NIP-01）。NIP-42 AUTH 自动签 kind-22242。发布可靠性：`publishAndWait` per-relay 1s/2s/3s 重试，任一 OK 即成功、其余后台重试；全失败存草稿跨会话补发（`retryDrafts` + `onPublishExhausted`）。
- **媒体上传（Blossom BUD-02/BUD-11）**：图片≤10MB 最多 9 张 / 视频≤100MB 单条 / 文件≤100MB 最多 4 个。签 kind-24242 auth → `PUT /upload` → url + NIP-92 imeta。默认服务器逐台尝试失败自动换。
- **媒体/文件下载**：`lib/services/media_download.dart` 统一入口。移动端图片/视频走 `gal` 存相册；桌面/普通文件走 `file_picker` save-as。接入点：图片全屏查看器、全屏视频页、文件 chip。
- **关注信息流 outbox 路由（★）**：`OutboxRouter` 按 followee kind-10002 分组开持久连接（30 上限、authors 200 分片、live、重连重发、NIP-42 AUTH），`since` 增量刷新 limit 提到 500（根治漏帖），加载更多走 `fetchOnce(until:)` + 默认桶广播。全球路径不动。
- **自定义关注列表（NIP-51 kind-30000）**：兼容 Amethyst 的 `d`=UUID + `name`=人类名约定；`kind30000DisplayName` 优先 `name` 回退 `d`；编辑保留 UUID `d`+元数据。**重命名**（⋯ 菜单 → 底部弹窗，`d` 不变只改 `name`，列表不分叉）+ **删除**（发 NIP-09 kind-5 `a`-坐标 `30000:pubkey:d`，删全版本——Amethyst 自带删除只发 `e` 对 replaceable 无效，这是修正）。新列表创建用 UUID `d`（Amethyst 约定，避免重命名后 `d` 冲突）。列表人数显示真实 `p` 标签数（非「已关注 ∩ 组内」交集，对齐 Amethyst）。
- **服务器节点页**：中继（连接状态 + 真实 WS RTT，NIP-50 CLOSED 回退 search 重试）+ Blossom（HTTP HEAD RTT）。时延缓存 SQLite，颜色绿快黄慢红离线。NIP-50 搜索中继单列。
- **通知未读角标**：底栏通知图标红点角标 + 持久化已读（`notificationReadProvider` 存 SQLite，跨会话保持）；**逐条点开标记已读**（不再整页标记），未读项浅色背景底 + 小圆点稳定区分，点开后转已读；通知页 AppBar「全部标记已读」（首次登录历史未读过多时一键清空当前 tab）。
- **屏蔽列表（NIP-51 kind-10000）**：对齐 Amethyst——公开 `p`/`word`/`t`/`e` 标签 + NIP-44 加密私密条目同事件并存（默认私密，仅 owner 可解）。信息流过滤：屏蔽用户的帖子、含屏蔽词/标签的帖子不显示。入口：用户主页 ⋮ → 屏蔽、信息流 hashtag chip 长按 → 屏蔽此标签、设置 → 屏蔽列表（管理 + 添加词/标签）。
- **新手引导**：首次登录 7 步气泡（发帖、搜索、通知、关注、语言过滤、关注过滤、设置），可跳过，后续不再弹。覆盖首页语言/关注过滤、搜索、设置入口（含服务器节点列表与时延页，只读）等核心操作。
- **安全存储**：OS keystore 优先；Linux libsecret 失败（keyring 锁）自动回退 0600 文件 `~/.config/costr/secret.json`，独占单用户主机可用。

</details>

---

## 验证

```bash
flutter analyze          # 0 issue
flutter test             # 209 个测试
flutter build linux      # 桌面构建
```

## 已知限制

- 到达事件**不做** Schnorr 验签（firehose 性能）；`Event.isSignatureValid` hook 已接线但默认关闭。
- **全球流是 live 快照**：广播到默认中继、不 close-on-EOSE，但默认中继各自只保留近期事件；切回全球模式会重拉一次。关注流走 outbox，可达 followee 全部历史（`until`/`since` 分页）。
- 关注列表可能 stale（如果你的 kind 3 最后更新在默认中继集之外的中继上——outbox 路由已大幅缓解）。
- 单 isolate 做 JSON 解析 + 去重；极高事件速率下 UI 可能卡顿（v1 有界可接受，后续可 isolate 化）。
- 安全存储：Linux libsecret 失败时回退 0600 文件（安全级别≈空密码 keyring，适合独占单用户主机）。

## 设计资源

- [docs/DESIGN.md](docs/DESIGN.md) —— 设计原则与交互规范（设计「宪法」）：用户定位、设计优先级、视觉语言（X 浅色基线）、Costr Logo 规范、4-tab + FAB 导航、通知中心、表情选择器与转发/引用菜单、应用介绍页/新手引导、登录/注册/退出、搜索与关注分组、文案规范、性能约束。
- [docs/ui_demo.html](docs/ui_demo.html) —— 可导航单文件交互稿（浏览器打开即用）：首页/搜索/通知/我的 + 发帖 + 登录/注册 + 通知设置/关于/帖子详情 + 新手引导，内联 Costr Logo SVG。快捷键 `1/2/3/4` 切 tab、`C` 发帖、`L` 登录、`Esc` 返回。**demo 与实现保持同步**——功能上线时 demo 对应屏幕改成真实效果，下线的功能要从 demo 移除。
- 品牌名统一写作 **Costr**（首字母大写）；不出现在 UI 上的技术词一律小写且只在 DESIGN.md 给开发者看。

## 许可证

待定。
