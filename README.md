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
- **头像与资料**：按作者 pubkey 拉取 NIP-01 kind 0 元数据（name / display_name / picture / about / website / banner），内存缓存 + 去重 in-flight 请求（`closeOnEose` 一次性快照）。feed 帖子卡显示头像 + 名字（无名字回退 npub 缩写），个人 profile 页展示 banner / 头像 / 名字 / about / website / npub / 登出。头像图片用 `cached_network_image` 缓存 + 占位/错误回退。
- **帖子正文渲染**：GitHub 风格 markdown（`flutter_markdown`）。**多图九宫格**：正文里连续的 markdown 图片（无文字间隔）合成 3 列方格缩略图（按实际数量，不封顶 9）；图片间有文字则各自成组；单张仍全宽显示。内联视频用 `video_player`（点按播放/暂停）。NIP-92 `imeta` tag 附带的图/视频未在正文里的追加在下方（图片合成方格、视频全宽）。NIP-19 `npub1`/`nprofile1` 提及自动 linkify 成可点链接（`nprofile1` 解 TLV 取 pubkey），标签显示已解析的 kind-0 用户名（无则缩写），点选跳 `/u/:pubkey`。**长帖折叠**：正文 >400 字符默认折叠到限高 + 渐变"展开"，展开后底部"收起"。
- **标签与语言过滤**：解析 NIP-12 `["t","value"]` tag **及**正文内联 `#hashtag`（支持中文 tag，忽略 markdown 标题与 URL 片段），合并去重小写；正文下方渲染成可点 chip（点选设为 tag 过滤器，AppBar 出现可清除的 tag chip）。AppBar 语言下拉：全部 / 中文 / 英文 / **日文**——启发式检测：**含假名（平假名/片片假名）判日文**（先于 Han 判定，避免日文帖被 CJK 当中文漏进来）；否则含 Han 判中文，否则含拉丁字母判英文。与 mode / tag 过滤叠加。
- **用户主页**：点 feed 帖子的头像或作者名 → 打开该用户 profile（`/u/:pubkey`，push 进栈、自带返回）。**头部用 NestedScrollView（banner/头像/资料可滚走 + TabBar 吸顶）**，避免长资料在窄屏 overflow。3 个 tab：**帖子**（顶层帖）、**回帖**（带回复的父帖引用 + 左侧竖线缩进层级，NIP-10 `e` tag：`reply` > legacy positional > `root`，忽略 `mention`）、**关注**（该用户 NIP-02 kind-3 联系人列表，每行头像+名可点进对方主页）。他人主页只展示资料，自己的主页才有 hex pubkey + 登出。
- **帖子菜单**：每条帖子右上角 `⋮` → 弹出菜单「复制 event id」「复制全文」，便于定位/反馈问题。
- **发帖（Compose）**：FAB → 撰写页，字数计数（280 软上限提示），签名（`Identity.signEvent`：computeId + bip340 sign + secure-random aux）+ 发布到中继。**EVENT 消息用对象形式**（2026 现行 NIP-01，中继拒绝旧数组形式）；`publishAndWait` 等中继 OK 应答，成功/失败带原因反馈到 UI，并本地 echo 让作者立即看到自己的帖子。**NIP-42 认证**：中继发 `["AUTH", challenge]` 时，pool 用当前身份签 kind-22242（含 `relay`/`challenge` tag）回送；`publishAndWait` 遇 auth-required 自动重试该中继。
- **媒体/文件上传（Blossom，BUD-02 + BUD-11）**：Compose 内 📷图片 / 🎬视频 / 📎文件 按钮选文件 → 上传到 Blossom 图床。**图片**≤10MB、最多 9 张；**视频**≤100MB、单条；图片视频不可混传；**文件附件**（pdf/zip 等，按 Blossom 服务器支持的类型）≤100MB、最多 4 个、可与图片或视频并存。上传 = 签 kind-24242 auth event（tags `t/x/expiration/size/m`）→ `PUT /upload`（binary + `Authorization: Nostr <base64url of event>`）→ 取回 url。默认服务器 `blossom.ditto.pub` / `media.libernet.app`，失败自动换服务器重试。每个上传媒体生成 NIP-92 `imeta` tag（url/m/x）随帖发布，MarkdownContent 渲染为九宫格图 / 视频 / 文件 chip。
- **默认中继**：`damus.io` / `nos.lol` / `ditto.pub` / `bostr.online`。前三个接受写入且被广泛订阅（帖子能被其他客户端看到）；`bostr.online` 写入需 NIP-42 认证（已支持）+ **白名单**（你的 key 须在白名单内，否则拒 `restricted: whitelisted`，这是中继策略）。
- **帖子交互（X 风格）**：每条帖子下方一排 💬回复 / 🔁转发 / ❤️reaction / 📌引用 / ↗分享。
  - **回复**（NIP-10）：push Compose 带 `replyTo`，签 kind-1 带 root+reply `e` tag + `p` tag。
  - **转发**（NIP-18）：确认后签 kind-6（content = 被转帖事件 JSON）+ `e`/`p` tag。
  - **reaction**（NIP-25 + NIP-30）：表情选择器，签 kind-7（`e`/`p`/`k` tag；unicode emoji 或 `:shortcode:` 自定义表情 + `emoji` tag）。自定义表情的 URL 由 `NostrActions.reaction(customShortcode/customUrl)` 支持。
  - **引用**（quote）：push Compose 带 `quoteOf`，签 kind-1，正文带 `nostr:note1` 引用 + `e` mention tag。
  - **分享**：复制 `https://njump.me/<note1>`（参考 Amethyst）。
- **关注**（NIP-02 kind 3 = 主关注列表，最新标准未废弃）：他人主页头像旁"关注"按钮 → 弹分组选择（无分组 / 亲友 / 新闻资讯 / 网友）。拉取当前用户完整 kind-3（保留 relay/petname）→ `NostrActions.follow` 加新 pubkey → 签 kind-3 全量发布 → 刷新关注列表。若选了分组，额外拉取该分组的 NIP-51 kind-30000 列表（`d`=分组名，parameterized replaceable）→ `NostrActions.followCategory` 加 pubkey → 发布。已关注则显示"已关注"。**安全护栏**：拉 kind-3 / kind-30000 不 closeOnEose、等事件或所有中继 EOSE；超时未确认则**中止不发布**（绝不发只含新 pubkey 的列表清空已有）。RelayPool 的 closeOnEose 改成等**所有**已连中继 EOSE 才关。**支持关注自己**（own profile 也显示关注按钮——关注自己后自己的帖会出现在"关注"feed，因关注流用 kind-3 p-tags 作 authors）。
- **关注者列表 + 列表内关注 + 回关**：个人主页新增"关注者"tab（NIP-12 参数化查询 `{kinds:[3], "#p":[pubkey]}` → 返回引用该 pubkey 的 kind-3，作者即 follower）。关注/关注者列表每行带关注按钮；在**自己的"关注者"tab**里，对方关注了我 → 按钮显示"回关"（未互关）/"已关注"（已互关）；其他列表显示"关注"/"已关注"。
- **收藏**（NIP-51 kind-10003 + NIP-44）：每条帖子收藏动作，弹"公开书签 / 私人书签"选择。**公开**：`e` tag 加进事件 `tags`（明文，他人可见）；**私人**：`e` tag 加进 `.content`——用 **NIP-44 v2 加密给自己**（secp256k1 ECDH + HKDF + ChaCha20 RFC7539 + HMAC-SHA256，纯 Dart 自实现，通过官方向量验证）。保留现有公开 tag + 私人条目。同样的中止护栏（拉取不确定时不发布，绝不清空书签）。
- **搜索**：Feed AppBar 搜索图标 → 全局搜索页。**全局搜索**支持搜索帖子（NIP-50 `search` 过滤器 + kind 1）和用户（kind 0 metadata），结果分用户区 + 帖子区，点用户进主页、点帖为 EventCard。搜索中继用 `nostr.wine`（支持 NIP-50，已 live 验证）。**指定用户搜索**放在用户主页：profile 顶部搜索框，客户端过滤该用户的帖子/回帖（按正文子串）。
- **下拉刷新 + 加载更多**：下拉刷新重新拉取当前流；滚到底自动发 `until: 最旧时间戳` 的 REQ 追加更早的事件。
- **界面与导航**：**中文优先**（面向中国用户，所有 UI 文案中文化；品牌名 costr 保留）。登录页、信息流页（中继状态 chip + 语言下拉 + tag 过滤 chip + 空/错误态）、个人页（头像 + 资料 + npub/pubkey + 登出）、发帖页、帖子详情页、用户主页。Feed/Profile 共用一个底栏导航 shell（`StatefulShellRoute.indexedStack`，保留各 tab 状态）；发帖页 / 用户主页 / 详情页 push 进栈、AppBar 自带返回键。相对时间中文（刚刚/分/时/天）。

## 设计与交互

- [docs/DESIGN.md](docs/DESIGN.md) —— 设计原则与交互规范（设计"宪法"）：用户定位、设计优先级（复刻 X app UI > 简约年轻 > 开箱即用 > 性能）、视觉语言（X 浅色基线：纯白底 + 黑主色，弃用 Material3 紫色）、Costr Logo 规范、4-tab + FAB 导航、通知中心数据源与界面、表情选择器（NIP-25/NIP-30）与转发/引用菜单、应用介绍页 / 新手引导、登录/注册/退出、搜索与主页筛选/关注分组、文案规范、性能约束。
- [docs/ui_demo.html](docs/ui_demo.html) —— 可导航单文件交互稿（浏览器打开即用）：首页 / 搜索 / 通知 / 我的 + 发帖 + 登录/注册 + 退出登录 + 通知设置 / 关于 / 帖子详情 + 新手引导，内联 Costr Logo SVG。快捷键 `1/2/3/4` 切 tab、`C` 发帖、`L` 登录、`Esc` 返回。
- 品牌名统一写作 **Costr**（首字母大写）。**每开发新功能前必须先回看这两个文件**，demo 与实现保持同步。

## 协议

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) —— events、REQ/EVENT/CLOSE/EOSE/NOTICE。
- [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) —— `nsec1`/`npub1`/`note1` bech32 编码（纯 Dart 自实现，因为 pub 上的 `bech32` 包不兼容 Dart 3.x）。
- [NIP-02](https://github.com/nostr-protocol/nips/blob/master/02.md) —— 联系人列表（kind 3），作为关注列表来源。
- [BIP-340](https://bips.xyz/340) —— secp256k1 Schnorr（用 `bip340` 包）做公钥派生。签名功能随发帖特性一同加入。

**中继兼容性**：NIP-01 规定 EVENT 帧的 event 是数组形式
`[id, pubkey, created_at, kind, tags, content, sig]`，但部分中继（如
`relay.bostr.online`）发送对象形式 `{"id","pubkey",...}`。`Event.fromMessage`
两者都解析，`_onData` 据此分发，所以对标准与非标准中继都能取到事件。

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
```

> **小内存机器注意**：`flutter run` 的调试编译峰值内存 ~1.5–2GB，无 swap 的
> 小 ECS（如 2 vCPU / 7GB / 无 swap）会 OOM 卡死。这类机器直接跑已构建的
> 二进制跳过编译：
> ```bash
> ./build/linux/x64/debug/bundle/costr
> ```

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
test/             单元与 widget 测试（58 个）
```

## 验证

```bash
flutter analyze          # 0 issue
flutter test             # 58 个测试
flutter build linux --debug
```

## v1 已知限制

- 到达事件**不做** Schnorr 验签（firehose 性能）；`Event.isSignatureValid` hook 已接线但默认关闭。
- 全球流是**有界快照**：EOSE 后即 CLOSE（取近期事件，不再持续接收 live firehose），切回全球模式会重新拉一次。关注流事件量小，保持 live。
- 关注列表可能 stale（如果你的 kind 3 最后更新在默认中继集之外的中继上）。
- 单 isolate 做 JSON 解析 + 去重；极高事件速率下 UI 可能卡顿（v1 有界可接受，后续可 isolate 化）。
- 安全存储：优先用 OS keystore（Linux libsecret / Android Keystore / iOS Keychain 等）。Linux 上若 login keyring 锁着或会话未自动解锁（自动登录/SSH 转发桌面等），libsecret 会失败，此时**自动退回 0600 权限文件** `~/.config/costr/secret.json`（dir 0700）。文件兜底的安全级别≈空密码 keyring（都是磁盘可读），适合独占的单用户主机。libsecret 一旦失败即记忆，后续不再重试。

## 许可证

待定。
