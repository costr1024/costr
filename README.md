# costr

**costr** = Chinese Nostr。一个用 Flutter 构建的跨平台 Nostr 社交客户端，单一代码库覆盖
Android、iOS、Windows、macOS、Linux 五端。

## 当前状态

**v1** —— 完整的 Nostr 社交客户端：私钥登录 / 创建账号（NIP-19 `nsec1`）、发帖 / 回复 / 转发 / 引用 / reaction、全球 / 关注信息流、用户主页（帖子 / 回帖 / 关注 / 关注者）、搜索、通知中心、本地 SQLite 缓存（冷启动秒出）。单代码库覆盖 Android、iOS、Windows、macOS、Linux 五端。

已实现：
- **身份**：粘贴 `nsec1` 私钥 → 用 BIP-340 `getPublicKey` 派生 x-only 公钥 → 存入 OS 安全存储，下次启动自动登录。
- **信息流**：在 **全球**（kind 1 实时广播流，有界）和 **关注**（来自你的 NIP-02 kind 3 联系人列表中作者的 kind 1）之间切换。
- **中继池**：多中继 fan-out，按 event id 去重（`events` 流，给全球信息流用），另开 **`rawEvents` 流（不去重）**给一次性定向拉取（个人 kind-3、关注者 `#p` 查询、NIP-50 搜索）——修复"再次拉取已被全球流见过的 kind-3 时被去重吞掉→关注/关注者 tab 空"的 bug；断线指数退避重连，重连后自动重发活跃订阅。
- **事件存储**：内存单源，按 id 去重，按时间倒序，上限 5000 条淘汰最旧。
- **头像与资料**：按作者 pubkey 拉取 NIP-01 kind 0 元数据（name / display_name / picture / about / website / banner），内存缓存 + 去重 in-flight 请求（`closeOnEose` 一次性快照）。feed 帖子卡显示头像 + 名字（无名字回退 npub 缩写），个人 profile 页展示 banner / 头像 / 名字 / about / website / npub（登出在设置→账号备份）。头像图片用 `cached_network_image` 缓存 + 占位/错误回退。
- **帖子正文渲染**：GitHub 风格 markdown（`flutter_markdown`）。**多图九宫格**：正文里连续的 markdown 图片（无文字间隔）合成 3 列方格缩略图（按实际数量，不封顶 9）；图片间有文字则各自成组；单张仍全宽显示。内联视频用 `video_player`（点按播放/暂停）。NIP-92 `imeta` tag 附带的图/视频未在正文里的追加在下方（图片合成方格、视频全宽）。NIP-19 `npub1`/`nprofile1` 提及自动 linkify 成可点链接（`nprofile1` 解 TLV 取 pubkey），标签显示已解析的 kind-0 用户名（无则缩写），点选跳 `/u/:pubkey`。**长帖折叠**：正文 >400 字符默认折叠到限高 + 渐变"展开"，展开后底部"收起"。
- **标签与语言过滤**：解析 NIP-12 `["t","value"]` tag **及**正文内联 `#hashtag`（支持中文 tag，忽略 markdown 标题与 URL 片段），合并去重小写；正文下方渲染成可点 chip——**点选 = 在首页按此 tag 过滤，长按 = 关注 / 取消关注此标签**（NIP-51 kind-30015），首页 tag 过滤激活时过滤条上还有星标一键关注。AppBar 语言下拉：🌐全部 / 🇨🇳中文 / 🇬🇧英文 / 🇯🇵日文，**当前选项显著标出**（按钮显示当前语言国旗 + 菜单内对勾）。启发式检测：**含假名（平假名/片假名）判日文**（先于 Han 判定，避免日文帖被 CJK 当中文漏进来）；否则含 Han 判中文，否则含拉丁字母判英文。与 mode / tag 过滤叠加。
- **用户主页**：点 feed 帖子的头像或作者名 → 打开该用户 profile（`/u/:pubkey`，push 进栈、自带返回）。**头部用 NestedScrollView（banner/头像/资料可滚走 + TabBar 吸顶）**，避免长资料在窄屏 overflow；4 个 tab 的主体改用 **`CustomScrollView` + sliver**（搜索框为 `SliverToBoxAdapter`、列表为 `SliverList`、空/载入态为 `SliverFillRemaining`），根治"简介过长下滑到搜索框附近 bottom overflowed by N px"——此前 `Column[固定高搜索框, Expanded(ListView)]` 在 header 滚动期 body 被给到小于搜索框的有界高度时，固定高子组件溢出；sliver 容忍任意有界高度。header 外层 Column 也加 `MainAxisSize.min` 不强占高度。关于长资料折叠用 `SingleChildScrollView(NeverScrollable)` + ClipRect。头部昵称 + @用户名按 **X 风格**布局：昵称粗体可换行（maxLines 2）+ 下方 npub 缩写；右侧动作按钮——他人显"关注"/"已关注"（点已关注可确认取消，见下），自己显"编辑资料"。NIP-05 旁的徽章 **区分已验证 / 未验证**（见搜索/验证）。4 个 tab：**帖子**（顶层帖）、**回帖**（带回复的父帖引用 + 左侧竖线缩进层级，NIP-10 `e` tag：`reply` > legacy positional > `root`，忽略 `mention`）、**关注**（该用户 NIP-02 kind-3 联系人列表，每行头像+名可点进对方主页）、**关注者**。
- **帖子菜单**：每条帖子右上角 `⋮` → 弹出菜单「复制帖子 id」「复制全文」「打闪」，便于定位/反馈问题/给作者打闪。**复制帖子 id 复制的是 `nostr:nevent1…`（NIP-19 nevent，带 relay + author hint，Amethyst 兼容）**，不是裸 hex——粘到别处或本应用发帖框都能解析回原帖。
- **打闪 Zap（NIP-57）**：帖子菜单「打闪」（在「复制全文」下方，同等级菜单项）→ 弹底部输入页：自定义聪（satoshi）数量 + 预设 chip（100/500/1k/5k/10k）+ 可选留言 → 解析对方 lud16/lud06（kind-0 元数据）→ LNURL-pay → 用当前身份签 kind-9734 zap 请求（tags `p`/`amount`/`lnurl`/`e`(被闪帖子)/`relays`）→ 取回 BOLT11 发票 → 展示二维码（`qr_flutter`）+ 可复制发票串 + 「在钱包中打开」（`lightning:` deeplink）。对方未配置闪电地址（无 lud16/lud06）时提示「对方未配置闪电地址，无法打闪」。服务层 `lib/services/zap.dart` 为纯函数（`httpGet` 回调注入，可单测）。
- **NIP-27 事件引用（nevent/note 嵌入）**：发帖框里粘贴 `nostr:nevent1…` / `nostr:note1…` → 发布时自动补 `e` mention tag（+ nevent 的 `p` author tag），正文保留 `nostr:…` 文本引用（其他客户端按此渲染）。渲染端 `MarkdownContent` 检测正文 `nostr:nevent1/note1` 及 `e` mention tag，抓取引用帖（`eventByIdProvider`：SQLite→内存→中继 REQ）渲染成内嵌引用卡（作者头像+名+正文片段，点进 `/n/:id`），原文里的裸 bech32 文本被剥离不重复显示。
- **发帖（Compose）**：FAB → 撰写页，字数计数（280 软上限提示），签名（`Identity.signEvent`：computeId + bip340 sign + secure-random aux）+ 发布到中继。**EVENT 消息用对象形式**（2026 现行 NIP-01，中继拒绝旧数组形式）；`publishAndWait` 等中继 OK 应答，成功/失败带原因反馈到 UI，并本地 echo 让作者立即看到自己的帖子。**NIP-42 认证**：中继发 `["AUTH", challenge]` 时，pool 用当前身份签 kind-22242（含 `relay`/`challenge` tag）回送；`publishAndWait` 遇 auth-required 自动重试该中继。
- **媒体/文件上传（Blossom，BUD-02 + BUD-11）**：Compose 内 📷图片 / 🎬视频 / 📎文件 按钮选文件 → 上传到 Blossom 图床。**图片**≤10MB、最多 9 张；**视频**≤100MB、单条；图片视频不可混传；**文件附件**（pdf/zip 等，按 Blossom 服务器支持的类型）≤100MB、最多 4 个、可与图片或视频并存。上传 = 签 kind-24242 auth event（tags `t/x/expiration/size/m`）→ `PUT /upload`（binary + `Authorization: Nostr <base64url of event>`）→ 取回 url。默认服务器 `blossom.ditto.pub` / `media.libernet.app`，失败自动换服务器重试。每个上传媒体生成 NIP-92 `imeta` tag（url/m/x）随帖发布，MarkdownContent 渲染为九宫格图 / 视频 / 文件 chip。
- **默认中继**（8 台）：`damus.bostr.online`（damus 反代，便于大陆直连）/ `nos.lol` / `ditto.pub` / `bostr.online` / `nostr.wine` / `nostr.net` / `0xchat.com` / `top.testrelay.top`。`damus/nos.lol/ditto` 接受写入且被广泛订阅（帖子能被其他客户端看到）；`bostr.online` 写入需 NIP-42 认证（已支持）+ **白名单**（你的 key 须在白名单内，否则拒 `restricted: whitelisted`，这是中继策略）。
- **NIP-65 中继清单发布**（kind 10002）：每次冷启动后台 fire-and-forget 签发一次当前中继列表（`["r", url]` tags，无 marker = 读写皆可），首次登录后也补发一次。kind 10002 是 replaceable 事件，重发只替换不堆积。让其他客户端按 outbox/inbox 模型找到你的中继、拉你的帖子——修复"其他客户端看不到我配置的中继、outbox/inbox 里只有 ditto/testrelay"的缺漏。
- **帖子交互（X 风格）**：每条帖子下方一排 💬回复 / 🔁转发 / ❤️reaction / 🔖收藏 / ↗分享。
  - **回复**（NIP-10）：push Compose 带 `replyTo`，签 kind-1 带 root+reply `e` tag + `p` tag。
  - **转发**（弹二选一菜单，DESIGN §3.5）：① **转发**（NIP-18）：确认后签 kind-6（content = 被转帖事件 JSON）+ `e`/`p` tag，直接转发不带评论；② **引用**（quote）：push Compose 带 `quoteOf`，签 kind-1，正文带 `nostr:note1` 引用 + `e` mention tag。不做下拉即转发的隐藏入口，弹菜单让用户明确选择。
  - **reaction**（NIP-25 + NIP-30）：表情选择器，签 kind-7（`e`/`p`/`k` tag；unicode emoji 或 `:shortcode:` 自定义表情 + `emoji` tag）。自定义表情的 URL 由 `NostrActions.reaction(customShortcode/customUrl)` 支持。
  - **分享**：复制 `https://njump.me/<note1>`（参考 Amethyst）。
- **关注**（NIP-02 kind 3 = 主关注列表，最新标准未废弃）：他人主页头像旁"关注"按钮 → 弹分组选择（无分组 / 亲友 / 新闻资讯 / 网友）。拉取当前用户完整 kind-3（保留 relay/petname）→ `NostrActions.follow` 加新 pubkey → 签 kind-3 全量发布 → 刷新关注列表。若选了分组，额外拉取该分组的 NIP-51 kind-30000 列表（`d`=分组名，parameterized replaceable）→ `NostrActions.followCategory` 加 pubkey → 发布。已关注则显示"已关注"（**点已关注 = 确认取消关注**，`NostrActions.unfollow` 读本地缓存 kind-3 移除该 pubkey 后签发，同样的中止护栏）。**安全护栏**：拉 kind-3 / kind-30000 不 closeOnEose、等事件或所有中继 EOSE；超时未确认则**中止不发布**（绝不发只含新 pubkey 的列表清空已有）。RelayPool 的 closeOnEose 改成等**所有**已连中继 EOSE 才关。**关注自己**：设置页有「在关注信息流显示自己的帖子」开关——状态反映自己是否在自己的 kind-3 里（若已在其他客户端关注过自己则显示开，否则关，可互切）；打开 = 关注自己（进默认分组），关闭 = 取消关注自己；关注自己后自己的帖会出现在"关注"信息流（关注流用 kind-3 p-tags 作 authors）。
- **关注者列表 + 列表内关注 + 回关**：个人主页新增"关注者"tab（NIP-12 参数化查询 `{kinds:[3], "#p":[pubkey]}` → 返回引用该 pubkey 的 kind-3，作者即 follower）。关注/关注者列表每行带关注按钮；在**自己的"关注者"tab**里，对方关注了我 → 按钮显示"回关"（未互关）/"已关注"（已互关）；其他列表显示"关注"/"已关注"。
- **收藏**（NIP-51 kind-10003 + NIP-44）：每条帖子收藏动作，弹"公开书签 / 私人书签"选择。**公开**：`e` tag 加进事件 `tags`（明文，他人可见）；**私人**：`e` tag 加进 `.content`——用 **NIP-44 v2 加密给自己**（secp256k1 ECDH + HKDF + ChaCha20 RFC7539 + HMAC-SHA256，纯 Dart 自实现，通过官方向量验证）。保留现有公开 tag + 私人条目。同样的中止护栏（拉取不确定时不发布，绝不清空书签）。
- **搜索**：Feed AppBar 搜索图标 → 全局搜索页。**全局搜索**支持搜索帖子（NIP-50 `search` 过滤器 + kind 1）和用户（kind 0 metadata），结果分用户区 + 帖子区，点用户进主页、点帖为 EventCard。**搜索走独立中继池 `searchPoolProvider`**（只连支持 NIP-50 的 `relay.ditto.pub` + `search.nos.today`），与主信息流隔离——此前把 search REQ 发给全部默认中继，多数中继不认 `search` 过滤器会无视它、直接回最近的 kind-1/kind-0 喂量，导致搜出一堆无关帖子。搜索 provider 用 `rawEvents` + 本地 `seen` 去重，重复搜同一关键词也能返回结果。**指定用户搜索**放在用户主页：profile 顶部搜索框，客户端过滤该用户的帖子/回帖（按正文子串）。
- **下拉刷新 + 加载更多**：下拉刷新重新拉取当前流；滚到底自动发 `until: 最旧时间戳` 的 REQ 追加更早的事件。
- **用户主页（P5 增强）**：header 加 **关注 / 关注者统计行**（数字粗体 + 次色 label，>1k/1M 紧凑格式；关注数取 `userGroupedFollowsProvider` 求和，关注者数取 `userFollowersProvider`，加载中显 `—`）。关注 tab 加 **子 tab：关注的人 / 关注的标签**（仅自己的 profile）：关注的人顶部 **分组 chip 横滑**（全部 / 各分组，选全部按分组分段带计数小标题，选某分组平铺）；关注的标签为 `#tag 帖子数` chip 网格，点一个跳首页按 tag 过滤、long-press 取消关注、行首"+ 标签"可手动添加。**关注的标签存中继**（NIP-51 kind-30015 Interests，`t` 标签列表，d=""，跨设备同步）+ 本地缓存（`replaceable_events` 表）冷启动秒开；入口三处：首页 tag 过滤条星标、帖子 `#标签` 长按菜单、个人页关注的标签网格。
- **帖子详情 thread line（P5）**：原帖 + 各回复共用左侧头像列（center x=28），每行 Stack 叠 2px 竖线，头像不透明遮中段 → 视觉呈「线—头像—线」连续；末条回复无下段线。复用 EventCard 不动。
- **新手引导（P5）**：首次登录后一次性 3 步气泡（发帖 FAB / 通知 tab / 关注一个人，可跳过、可点遮罩跳过）。"已看过"标志存本地 config 表（`onboarding_done`），后续不再弹。
- **首页偏好持久化（P5）**：上次选的首页 tab（全球 / 关注）和语言过滤重启后恢复——存本地 config 表（`feed_mode` / `language_filter`），不上传中继。开箱默认全球 + 全部语言。
- **账号备份**（设置→账号备份）：**账号级 NSFW 设置**（自动显示敏感内容 / 发帖默认标记敏感，只存本地不同步）+ **备份私钥**。复制私钥前用 `local_auth` 做生物识别 / 设备锁验证（移动端指纹/FaceID/锁屏密码；桌面 Linux 不支持则禁用），并展示强风险警示（私钥泄漏=账号无法销毁、被盗用、永远无法夺回控制权）。Android 用 `FlutterFragmentActivity`，iOS 配 `NSFaceIDUsageDescription`。
- **发帖 @ 提及候选自动补全**：Compose 输入 `@` 后实时列出候选用户（来自 EventStore kind-0 metadata + 关注列表 + 自己），按昵称/npub 过滤；选中插入 `nostr:npub1…`（NIP-27 文本引用）并在发送时补 `p` tag。渲染时 `MarkdownContent` linkify 成 `@昵称` 可点跳个人页（`entityToPubkeyHex` 剥 `nostr:` 前缀，正则 group(1) 捕获完整实体——修好此前"显示 @nprofile1 且点不动"的 bug）。
- **发帖图片上限**：图片最多 9 张，选超时显式提示"已只添加前 N 张"（不再静默丢弃）；满 9 张后禁止再选。
- **关于页 Nostr 协议原理**：补 app↔中继多对多 SVG 原理图 + 两段通俗讲解，按**最新 outbox/inbox 模型**写：发帖＝写进你的「发件箱」中继（outbox），看帖＝去别人的发件箱取（按 NIP-65 中继清单找），私信等只给特定人的内容写到对方「收件箱」（inbox，NIP-17）。末句修正——"开源可审计"指 **Costr 应用代码**（Nostr 是协议不是代码）。
- **NIP-05 验证徽章**：个人主页 NIP-05 旁的图标**区分已验证 / 未验证**——`nip05VerifiedProvider` 实际请求 `https://<domain>/.well-known/nostr.json?name=<local>`，比对 `names` map（或 `_` local-part 取根 `pubkey` 字段）映射的 pubkey 与本 pubkey。已验证＝勾选图标（主色，保持原样）；未通过 / 拉取超时＝灰色的 `error_outline` 图标，视觉上与已验证区分；校验中显小转圈。结果按 pubkey 缓存。
- **通知中心空通知修复**：通知 provider 此前监听去重后的 `pool.events` 流——其 `#p:[me]` / `#e:[我的帖]` 定向 REQ 重新拉取的提及/回复/点赞，大多已被全球 firehose 先收到、进了去重集合，于是被吞掉、监听器永不触发，导致「完全收不到通知」。改为 `pool.rawEvents`（不去重）+ 本地 `seen` 集合按 id 去重，过去的提及/回复/点赞得以回填；聚合逻辑不变（同 type+target 合并、按作者去重、`extraCount` 计多出来的）。
- **设置页脚**：底部品牌行改成「Costr = Chinese Nostr」单独一行 + 「更适合中文用户的 Nostr 开源社交客户端」单独一行。
- **NSFW 警告显示修复**：短内容 NSFW 帖的模糊层只占 ~28×20，把警告层挤成每行一个字、溢出串入相邻卡。改用 `SizedBox(width:∞)` + `ConstrainedBox(minHeight:200)`，警告层不再依赖模糊内容尺寸，长帖照常撑高。
- **后台不清缓存**：`AppRoot` 加 `WidgetsBindingObserver`——进后台绝不清空 EventStore / 不重发 feed；回前台只 `RelayPool.reconnect()` nudge 断线重连 + 增量补拉，不做整页 reload。
- **通知点击跳转修复**：mention 类通知 `targetEventId` 为 null（只 follow 走 profile 分支，mention 落空 → 点击无反应）。`NotificationItem` 新增 `sourceEventId`（触发通知的那条事件 id），tile `onTap` 用 `targetEventId ?? sourceEventId` 跳 `/n/:id`——回复/reaction/repost 跳到被互动的原帖，mention 跳到 @你的那条帖。
- **可拖动发帖 FAB**：发帖按钮原固定在右下，会遮挡打闪页/表情/转发等底部 sheet 与 `⋮` 弹出菜单。改为 shell 外层 `Stack` 里的 `Positioned` 可拖动 FAB——`onPanUpdate` 拖动、`onTap` 打开发帖（gesture arena 自动区分点按与拖动），位置 clamp 在屏内、持久化到本地 config 表（`fab_x`/`fab_y`），跨会话保留用户选定的位置。
- **退出登录崩溃修复**：`showLogoutSheet` 此前在确认按钮里 `Navigator.pop(ctx)` 后**不等 sheet 卸载**就 `logout()` 置空 identity → Riverpod 同步触发 `GoRouterRefreshNotifier.notify()` → GoRouter 在 bottom sheet 的 element 仍处于 `inactive→unmounted` 之间就 rebuild 整棵路由树，命中 `framework.dart` 的 `element._lifecycleState == inactive` 断言；外加一次与 redirect 并发的 `context.go('/login')`。改为确认按钮只 `pop(ctx, true)` 返回结果，真正的 `logout()` 放到 `await showModalBottomSheet` 返回之后执行——sheet 已完全卸载，状态变更触发 redirect 时不再撞上正在拆卸的 element。
- **通知页崩溃修复**：`_NotificationTile` 头像重叠此前用 `EdgeInsets.only(right: -8)`——`Padding` 不允许负值，每条带头像的通知渲染即命中 `shifted_box.dart` 的 `padding.isNonNegative` 断言。改用 `Transform.translate(offset: Offset(i==0?0:-8, 0))` 实现重叠，视觉一致且不违反 padding 约束。
- **界面与导航**：**中文优先**（面向中国用户，所有 UI 文案中文化；品牌名 costr 保留）。登录页、信息流页（中继状态 chip + 语言下拉 + tag 过滤 chip + 空/错误态）、个人页（头像 + 资料 + npub + 编辑资料入口）、发帖页、帖子详情页、用户主页。Feed/Profile 共用一个底栏导航 shell（`StatefulShellRoute.indexedStack`，保留各 tab 状态）；发帖页 / 用户主页 / 详情页 push 进栈、AppBar 自带返回键。相对时间中文（刚刚/分/时/天）。

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

- `wss://damus.bostr.online/`、`wss://nos.lol/`、`wss://relay.ditto.pub/`（接受写入，被广泛订阅）
- `wss://relay.bostr.online/`（写入需 NIP-42 认证 + 白名单）
- `wss://nostr.wine/`、`wss://relay.nostr.net/`、`wss://relay.0xchat.com/`、`wss://top.testrelay.top/`

> `damus.bostr.online` 是用户自建的 damus 反向代理（真实后端为 `relay.damus.io`），便于中国大陆直连。

搜索专用中继（NIP-50，独立 `searchPoolProvider`，只连这两台）：

- `wss://relay.ditto.pub/`、`wss://search.nos.today/`

中继列表同时是 NIP-65（kind 10002）用户元数据——**每次冷启动后台签发一次 kind 10002**（`["r", url]` tags，replaceable 故重复发布只替换不堆积；首次登录后也补发一次），让其他客户端按 outbox/inbox 模型找到你的中继、拉你的帖子。

## 目录结构

```
lib/
  main.dart              入口（ProviderScope）
  app/                   app 外壳、主题、路由、providers（riverpod）
    app.dart             以 bootstrap 门控的 MaterialApp.router
    router.dart          GoRouter + 登录重定向 + AppShell（4-tab 底栏 + FAB + 引导）
    providers.dart       identity、relayPool、bootstrap、eventStore、feedMode、
                         followingState、followedTags、socialGraph、
                         savedFeedMode/savedLanguageFilter、relayStatus
  models/                NIP-01 Event（解析、p-tag、hashtags、验签 hook）
  nostr/
    identity.dart        Identity（nsec1 → 公钥，bip340）
    actions.dart         NostrActions（reply/repost/quote/reaction/follow）
    nip44.dart           NIP-44 v2 加密（纯 Dart 自实现，私人书签用）
    relay_client.dart    WebSocket 中继连接（长生命周期广播，EOSE/NOTICE）
    relay_pool.dart      RelayPool（去重、重连、重发、NIP-42 AUTH）
    event_store.dart     内存存储（去重/排序/上限）
  services/
    local_cache.dart     drift/SQLite 本地缓存（events/replaceable/event_tags/
                         events_fts/config/drafts，冷启动 hydration + 30 天清理）
    zap.dart             NIP-57 打闪：LNURL-pay + kind-9734 zap 请求 + BOLT11 发票（纯函数）
    secure_storage_service.dart   nsec 持久化（libsecret 不可用时降级）
  features/
    auth/login_page.dart      私钥导入 + 创建账号多步向导
    feed/feed_page.dart       全球/关注切换、列表、状态、空态
    feed/event_card.dart      npub + 相对时间 + 正文 + 反应 chip + 帖子菜单（复制id/全文/打闪）
    feed/zap_sheet.dart       打闪底部页（金额/留言 → 二维码发票 + 钱包 deeplink）
    feed/post_detail_page.dart 帖子详情 + 回复 thread line
    profile/profile_page.dart 用户主页（帖子/回帖/关注/关注者 + 统计 + 分组 chip + 标签）
    compose/compose_page.dart 发帖/回复/引用 + 媒体上传（Blossom）
    notifications/           通知中心（全部/提及 + 聚合）+ 通知设置
    search/search_page.dart  全局搜索（帖子/用户）
    settings/                设置 / 关于 / 账号 / 服务器节点
  widgets/
    onboarding_overlay.dart   首次登录 3 步引导
    markdown_content.dart     帖子正文（九宫格图/视频/mention linkify/折叠）
    post_actions.dart         X 风格动作栏（回复/转发菜单/reaction/收藏/分享）
    avatar.dart, costr_logo.dart
  utils/
    bech32_codec.dart    纯 Dart BIP-173 bech32
    nip19.dart           nsec/npub/note ↔ hex
    language.dart        帖子语言启发式检测
test/             单元与 widget 测试（136 个）
```

## 验证

```bash
flutter analyze          # 0 issue
flutter test             # 136 个测试
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
