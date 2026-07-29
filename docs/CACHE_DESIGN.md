# costr 本地缓存架构设计

## Context

costr 当前所有数据（帖子、metadata、reactions、关注列表）纯内存，重启即丢，9+ provider 每次走中继重拉（慢、常空）。需要一套 30 天本地缓存架构，冷启动秒出、搜索/过滤本地查、缓存一致、中继可动态管理、手机空间可控。

调研 Amethyst（内存对象图→迁移嵌入式 relay）、Jumble（IndexedDB 分表+条件 upsert+启动清理）、Damus/nostrdb（LMDB 复合索引 `(pubkey,kind,created_at)`）。选型 **drift**（响应式 SQLite ORM + FTS5）。

---

## 一、架构总览

```
┌─────────────────────────────────────────────┐
│                  UI Layer (Riverpod)         │
│  FeedPage / ProfilePage / SearchPage / ...  │
└──────────────┬──────────────────────────────┘
               │ watch providers
┌──────────────▼──────────────────────────────┐
│            Provider Layer (Riverpod)         │
│  metadataProvider / feedProvider /          │
│  reactionsProvider / searchProvider / ...   │
│                                             │
│  读取顺序：① SQLite 缓存（秒出）           │
│            ② 中继 REQ（后台刷新增量）       │
└──────┬───────────────────┬──────────────────┘
       │                   │
┌──────▼──────┐    ┌───────▼──────────────────┐
│  SQLite     │    │     RelayPool             │
│  LocalCache  │    │  (WebSocket fan-out)     │
│  (drift)     │    │  pool.events stream      │
│              │    │                           │
│  events      │    │  事件到达 → 写入 SQLite   │
│  replaceable │    │  + 更新内存热数据         │
│  event_tags  │    │                           │
│  events_fts  │    │  发布 → publishAndWait    │
│  config      │    │  + 本地 echo              │
└──────────────┘    └───────────────────────────┘
```

**数据流**：

```
中继事件到达
  │
  ├─→ RelayPool._merged (dedup by id)
  │     │
  │     ├─→ EventStoreNotifier (内存 LRU 5000，UI 热数据)
  │     │     └─ 触发 200ms throttle → state = store.events
  │     │
  │     └─→ LocalCache.writeEvent() (SQLite 持久化)
  │           ├─ kind 0/3/10000+/30000+ → replaceable_events 表 (upsert)
  │           └─ kind 1/7/... → events 表 (insert by id)
  │
UI Provider 读取
  │
  ├─→ ① LocalCache.queryXxx() → SQLite 查询（毫秒级）
  │     ├─ feed: SELECT FROM events WHERE kind=1 ORDER BY created_at DESC LIMIT 200
  │     ├─ metadata: SELECT FROM replaceable_events WHERE pubkey=? AND kind=0
  │     ├─ reactions: SELECT FROM events WHERE kind=7 + JOIN event_tags WHERE name='e' AND value=?
  │     └─ search: SELECT FROM events_fts WHERE content MATCH ?
  │
  └─→ ② 同时发中继 REQ（后台刷新）
        └─ 新事件到达 → 写入 SQLite + 更新内存 → provider 自动 rebuild
```

---

## 二、数据模型

### 2.1 不可变事件表 `events`

存储 kind 1（text notes）、kind 7（reactions）、kind 4（DM，未来）、kind 5（deletion）等不可变事件。按 event id 去重，insert 时重复 id 忽略。

```sql
CREATE TABLE events (
  id          TEXT PRIMARY KEY,        -- 32-byte hex event id
  pubkey      TEXT NOT NULL,           -- 作者
  kind        INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,        -- unix seconds
  content     TEXT NOT NULL,
  sig         TEXT NOT NULL,
  raw         TEXT NOT NULL,           -- 原始 JSON（re-broadcast + round-trip）
  tags_json   TEXT NOT NULL,           -- tags JSON array
  received_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- nostrdb/strfry 索引集（SQL 形式）
CREATE INDEX idx_events_pubkind ON events(pubkey, kind, created_at DESC);
CREATE INDEX idx_events_kindtime ON events(kind, created_at DESC);
CREATE INDEX idx_events_pubtime ON events(pubkey, created_at DESC);
CREATE INDEX idx_events_created ON events(created_at DESC);
```

**查询模式**：
- feed 首屏：`WHERE kind=1 ORDER BY created_at DESC LIMIT 200`
- 用户帖子：`WHERE pubkey=? AND kind=1 ORDER BY created_at DESC LIMIT 100`
- reactions：`WHERE kind=7` + tag 查询（见 2.3）
- 按 id 查：`WHERE id=?`（PK，O(1)）

### 2.2 可变事件表 `replaceable_events`

存储 kind 0（metadata）、kind 3（contact list）、kind 10000+（mute/pin/bookmarks 等）、kind 30000+（NIP-33 parameterized，如分组关注列表）。按 `(pubkey, kind, d_tag)` 去重，upsert 时 `created_at` guard 保证只保留最新。

```sql
CREATE TABLE replaceable_events (
  pubkey     TEXT NOT NULL,
  kind       INTEGER NOT NULL,
  d_tag      TEXT DEFAULT '',          -- NIP-33 d-tag value（kind 0/3 用空串）
  id         TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  content    TEXT NOT NULL,
  sig        TEXT NOT NULL,
  raw        TEXT NOT NULL,
  tags_json  TEXT NOT NULL,
  PRIMARY KEY (pubkey, kind, d_tag)
);
```

**Upsert 语义（NIP-01 + NIP-33）**：
```sql
INSERT INTO replaceable_events (pubkey, kind, d_tag, id, created_at, ...)
VALUES (?, ?, ?, ?, ?, ...)
ON CONFLICT(pubkey, kind, d_tag) DO UPDATE SET
  id=excluded.id, created_at=excluded.created_at, content=excluded.content,
  sig=excluded.sig, raw=excluded.raw, tags_json=excluded.tags_json
WHERE excluded.created_at > replaceable_events.created_at
  OR (excluded.created_at = replaceable_events.created_at
      AND excluded.id < replaceable_events.id);  -- lex tie-break
```

**查询模式**：
- metadata：`WHERE pubkey=? AND kind=0`（PK lookup，O(1)）
- contact list：`WHERE pubkey=? AND kind=3`（PK lookup，O(1)）
- 分组关注：`WHERE pubkey=? AND kind=30000`（scan all d_tags）
- bookmarks：`WHERE pubkey=? AND kind=10003`

### 2.3 Tag 索引表 `event_tags`

规范化 tag 存储，支持 `#e`/`#p`/`#d`/`#t` 参数化过滤查询（替代 `#e` 参数化中继查询——已验证默认中继不支持 `#e`）。

```sql
CREATE TABLE event_tags (
  event_id  TEXT NOT NULL,
  name      TEXT NOT NULL,             -- 'e', 'p', 'd', 't', 'imeta', ...
  value     TEXT NOT NULL,             -- tag[1]（对于多值 tag 取第一个）
  position  INTEGER NOT NULL,          -- tag 在事件中的位置
  PRIMARY KEY (event_id, position)
);
CREATE INDEX idx_tags_nameval ON event_tags(name, value);
```

**查询模式**：
- reactions for event X：`SELECT e.* FROM events e JOIN event_tags t ON e.id=t.event_id WHERE e.kind=7 AND t.name='e' AND t.value='X'`
- replies to event X：`SELECT e.* FROM events e JOIN event_tags t ON e.id=t.event_id WHERE e.kind=1 AND t.name='e' AND t.value='X' ORDER BY e.created_at DESC`
- follows (kind=3 p-tags)：从 `replaceable_events` 解析 tags_json

### 2.4 全文搜索 `events_fts`（FTS5）

```sql
CREATE VIRTUAL TABLE events_fts USING fts5(
  content, pubkey, kind,
  content=events, content_rowid=rowid,
  tokenize='unicode61'
);
-- Triggers 保持 FTS 索引与 events 表同步
CREATE TRIGGER events_ai AFTER INSERT ON events BEGIN
  INSERT INTO events_fts(rowid, content, pubkey, kind)
  VALUES (new.rowid, new.content, new.pubkey, new.kind);
END;
CREATE TRIGGER events_ad AFTER DELETE ON events BEGIN
  DELETE FROM events_fts WHERE rowid=old.rowid;
END;
```

**查询模式**：
- 全局搜索帖子：`SELECT e.* FROM events e JOIN events_fts f ON e.rowid=f.rowid WHERE e.kind=1 AND events_fts MATCH ? ORDER BY e.created_at DESC LIMIT 100`
- 用户内搜索：`... WHERE e.kind=1 AND e.pubkey=? AND events_fts MATCH ?`
- 搜索用户：`SELECT * FROM replaceable_events WHERE kind=0 AND content MATCH ?`

### 2.5 本地配置表 `config`

替代 SecureStorage 的 generic readValue/writeValue（后者在 Linux libsecret 不可用时静默丢失）。

```sql
CREATE TABLE config (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

存储：中继列表、NSFW 设置、feed 模式、语言过滤器、最后同步时间戳等。

### 2.6 中继管理表 `relay_config`

```sql
CREATE TABLE relay_config (
  url      TEXT PRIMARY KEY,
  enabled  INTEGER NOT NULL DEFAULT 1,
  read     INTEGER NOT NULL DEFAULT 1,
  write    INTEGER NOT NULL DEFAULT 1,
  added_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
```

支持中继动态添加/删除/启用禁用，读写分离（某些中继只读，某些可写）。

---

## 三、缓存一致性策略

### 3.1 可变 vs 不可变

| 类型 | kind | 表 | 写入策略 | 一致性保证 |
|---|---|---|---|---|
| 不可变 | 1, 7, 4, 5... | events | INSERT by id（重复忽略） | id 全局唯一，不会覆盖 |
| 可变 | 0, 3, 10000-19999 | replaceable_events | UPSERT by (pubkey, kind) | created_at guard，新>旧才覆盖 |
| 参数化可变 | 30000-39999 | replaceable_events | UPSERT by (pubkey, kind, d_tag) | 同上 + d_tag 区分 |
| 删除 | 5 | events | INSERT + 查询时排除 | kind-5 的 `e` tag 指向被删事件 id |

### 3.2 数据流一致性

```
中继事件到达 → RelayPool._merged (dedup)
  ├─→ EventStoreNotifier (内存热数据，200ms throttle)
  └─→ LocalCache.writeEvent (SQLite 持久化)
       ├─ 判断 kind → 选表（events / replaceable_events）
       ├─ 不可变：INSERT OR IGNORE
       ├─ 可变：UPSERT + created_at guard
       └─ 写 event_tags 表（批量）

UI 读取 → Provider
  ├─ ① SQLite 查询（缓存命中，秒出）
  └─ ② 中继 REQ（后台刷新）
       └─ 新事件到达 → 写 SQLite + 更新内存 → Provider 自动 rebuild
```

**关键保证**：SQLite 写入在内存更新之后（同一 listener 回调内），不会出现内存有但 SQLite 没有的窗口（写入失败时内存数据仍可用）。反过来，SQLite 有但内存没有的数据（如重启后冷启动），通过 hydration 加载到内存。

### 3.3 多设备一致性

- 拉取时比对 `created_at`，拒绝旧数据覆盖新数据（upsert guard）
- kind-5 deletion：查询时 `WHERE id NOT IN (SELECT value FROM event_tags WHERE name='e' AND event_id IN (SELECT id FROM events WHERE kind=5))`
- NIP-40 expiration：`DELETE FROM events WHERE id IN (SELECT event_id FROM event_tags WHERE name='expiration' AND value < strftime('%s','now'))`

---

## 四、缓存清理策略

### 4.1 TTL（30 天）

启动后 30 秒执行（Jumble 模式，避免启动卡顿）：

```sql
-- 删除 30 天前的不可变事件（保留可变 metadata/contact list 不受 TTL 限制）
DELETE FROM events
WHERE created_at < strftime('%s','now') - 30*86400
  AND kind NOT IN (5);  -- 保留 deletion 标记

-- NIP-40 过期事件
DELETE FROM events
WHERE id IN (
  SELECT event_id FROM event_tags
  WHERE name='expiration' AND value < strftime('%s','now')
);

-- 清理孤儿 tag 行
DELETE FROM event_tags WHERE event_id NOT IN (SELECT id FROM events);

-- 清理孤儿 FTS 行
DELETE FROM events_fts WHERE rowid NOT IN (SELECT rowid FROM events);
```

### 4.2 空间占用控制

```sql
-- 检查 DB 大小（PRAGMA page_count * page_size）
-- 超过 200MB 时删最旧 10% 不可变事件
DELETE FROM events
WHERE id IN (
  SELECT id FROM events ORDER BY created_at ASC LIMIT
    (SELECT COUNT(*) / 10 FROM events)
);
```

手机端目标：DB < 200MB。可变事件（metadata/contact list）极小（KB 级），不受空间限制。

### 4.3 VACUUM

清理后执行 `VACUUM`（或 `PRAGMA auto_vacuum = INCREMENTAL` + `PRAGMA incremental_vacuum`）回收空间。

---

## 五、搜索/过滤性能优化

### 5.1 搜索（FTS5 本地优先 + 中继后台刷新）

```
用户输入搜索词
  │
  ├─→ ① SQLite FTS5 查询（< 100ms）
  │     SELECT e.* FROM events e
  │     JOIN events_fts f ON e.rowid = f.rowid
  │     WHERE e.kind=1 AND events_fts MATCH ?
  │     ORDER BY rank LIMIT 100
  │     → 立即显示本地结果
  │
  └─→ ② 中继 NIP-50 REQ（nostr.wine）
        └─ 6s 收集窗口 → 新结果追加到 SQLite + UI
```

**优势**：冷启动搜索秒出（本地 FTS5），不再死等 6s 中继响应。

### 5.2 过滤（SQLite 索引查询）

| 过滤类型 | 当前（内存扫描） | 优化后（SQLite 索引） |
|---|---|---|
| 语言过滤 | O(n) 遍历 + regex | 查询时加 WHERE（或内存过滤已 hydrate 的数据） |
| tag 过滤 | O(n) 遍历 + contains | `JOIN event_tags WHERE name='t' AND value=?` |
| 关注人过滤 | 内存 set.contains | `WHERE pubkey IN (follows)` |
| 用户帖子 | 中继 REQ + 等待 | `WHERE pubkey=? AND kind=1 ORDER BY created_at DESC LIMIT 100` |
| reactions | O(n) 遍历 kind=7 | `JOIN event_tags WHERE name='e' AND value=?`（索引 O(log n)） |

### 5.3 查询性能指标（预期）

| 查询 | 表 | 索引 | 复杂度 |
|---|---|---|---|
| feed 首屏 200 条 | events | idx_events_kindtime | O(log n + 200) |
| 用户最新 100 帖 | events | idx_events_pubkind | O(log n + 100) |
| metadata by pubkey | replaceable_events | PK | O(1) |
| reactions by event | events + event_tags | idx_tags_nameval | O(log n + k) |
| 全文搜索 | events_fts | FTS5 inverted index | O(terms) |
| replies by event | events + event_tags | idx_tags_nameval | O(log n + k) |

---

## 六、中继动态管理

### 6.1 中继列表持久化

中继列表存储在 `relay_config` 表 + `config` 表（默认列表）。支持运行时添加/删除/启用/禁用中继，不重启 app。

### 6.2 读写分离

某些中继只读（如 relay.bostr.online 需 NIP-42 + 白名单才能写），某些可读写。`relay_config.read` / `relay_config.write` 控制每条中继的角色。

### 6.3 动态生效

修改 `relay_config` 后，`relayPoolProvider` 检测变更 → 断开旧连接 → 建立新连接 → 重新发活跃订阅。不需要重启 app。

### 6.4 UI

设置页面（或 Profile 页面入口）展示中继列表，每条可切换读写、启用/禁用、添加新中继 URL。

---

## 七、冷启动 Hydration

```
app 启动 → bootstrapProvider
  │
  ├─→ ① 打开 SQLite (drift)
  │
  ├─→ ② 从 SQLite hydrate 内存数据
  │     ├─ events: SELECT kind=1 ORDER BY created_at DESC LIMIT 200 → feed 首屏
  │     ├─ replaceable: SELECT kind=0 → 全部 metadata 到内存 Map
  │     ├─ replaceable: SELECT kind=3 (own pubkey) → contactListCache
  │     └─ events: SELECT kind=7 ORDER BY created_at DESC LIMIT 500 → reactions cache
  │     → UI 立即显示缓存内容（< 1s）
  │
  ├─→ ③ 加载 identity (SecureStorage)
  │
  ├─→ ④ 连接 RelayPool
  │     └─ 发 REQ → 新事件到达 → 写 SQLite + 更新内存 → UI 增量刷新
  │
  └─→ ⑤ 30s 后运行缓存清理
```

---

## 八、扩展性设计

### 8.1 新 kind 支持

只需在 `LocalCache.writeEvent()` 的 kind 路由逻辑里加一行（不可变 → events 表，可变 → replaceable_events 表）。不需要改 schema 或迁移。

### 8.2 新查询模式

在 `LocalCache` 类加新方法（如 `queryDms()`、`queryMuteList()`），复用已有表和索引。

### 8.3 迁移管理

drift 内置 migration 支持。schema 变更时加 migration step，不需要手动 ALTER。

### 8.4 未来：嵌入式 relay

如果未来需要 nostrdb 级别的性能，SQLite schema 和索引设计已与 nostrdb 对齐（`pubkey+kind+created_at` 复合索引），迁移到 nostrdb 只需替换存储层，上层 provider 不变。

---

## 九、依赖

```
drift: ^2.0.0              # 响应式 SQLite ORM
sqlite3_flutter_libs: ^0.5.0  # 原生 SQLite 库
path_provider: ^2.1.0      # 获取 app 数据目录
path: ^1.9.0               # 路径操作
```

---

## 十、不做（out of scope）

- 不替换 RelayPool（中继层不变，SQLite 是持久化层 + 缓存源）
- 不替换 Riverpod（状态管理不变）
- 不替换 EventStore 内存层（保留 LRU 5000 作 UI 热数据，SQLite 是持久化后端）
- 不做嵌入式 relay（nostrdb/Citrine，过于复杂）
- 不做分布式同步（单设备本地缓存）

---

## 十一、缓存持久化与升级/重装

### 场景分析

| 场景 | 缓存是否保留 | 说明 |
|---|---|---|
| **app 升级（覆盖安装新版本）** | ✅ 保留 | SQLite DB 在 app 数据目录，升级不清除 |
| **卸载后重新安装** | ❌ 丢失 | 卸载时 app 数据目录被系统删除（Android/iOS 通用行为） |
| **卸载后安装新版本** | ❌ 丢失 | 同上 |
| **清除 app 数据/缓存** | ❌ 丢失 | 用户手动清除数据 = 删 DB |
| **系统更新** | ✅ 保留 | 不影响 app 数据目录 |

### 缓存丢失后的影响

- **nsec 私钥**：取决于平台——Android Keystore 卸载即清除（需重新登录）；iOS Keychain 卸载后可能保留（取决于设备设置）。
- **metadata / 关注列表 / 帖子缓存**：全部丢失，但可从中继重新拉取（首次启动较慢，逐步恢复）。
- **NSFW 设置 / 中继列表等本地配置**：丢失。中继列表可从默认列表恢复；NSFW 设置回到默认值。

### 缓解方案

1. **中继优先恢复**：缓存丢失后 app 仍可正常工作——从默认中继列表连接、重新 REQ kind-0/1/3/7，数据逐步回填到 SQLite。体验等同于首次安装。

2. **drift 迁移保护**：app 升级时 drift 内置 migration——schema 变更不会丢旧数据，只增补新列/表。版本号在 `@DriftDatabase(schemaVersion: N)` 控制。

3. **（可选，后续版本）缓存导出/导入**：
   - 导出：将 SQLite DB 文件复制到用户选择的目录（如 Downloads 或 share sheet）。
   - 导入：从用户选择的文件恢复 DB。
   - 适用场景：换设备、卸载前备份。
   - 注意：导入的 DB 需验证 schema 版本兼容性（drift migration 自动处理）。

4. **（可选，后续版本）账号绑定的云端备份**：
   - 将关键配置（中继列表、NSFW 设置、关注分组）加密后发布为 kind-30078（app data）或 NIP-44 加密的 kind-10000+。
   - 重装后从中继拉取恢复。
   - 不备份帖子缓存（帖子可从中继重新拉取，不值得占用用户存储配额）。

### 使用限制说明（写入 README）

- 缓存存储在 app 本地数据目录，**卸载 app 会导致缓存丢失**。
- 卸载重装后首次启动会从中继重新加载数据（较慢，几分钟内恢复）。
- nsec 私钥在 Android 上卸载即清除，需重新输入；iOS Keychain 可能保留。
- 建议换设备前使用"缓存导出"功能备份（后续版本支持）。
