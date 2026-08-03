/// Notification center (DESIGN.md §5).
///
/// Subscribes to mentions (#p) + interactions (#e on my recent posts).
/// Aggregates by type+target (X-style grouping). All/Mentions tabs.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../services/local_cache.dart' as cache;
import '../../utils/nav.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import '../../widgets/immersive.dart';
import '../../widgets/mention_linkifier.dart';

// --- Notification data model ---

enum NotificationType { reply, mention, reaction, repost, follow, quote }

class NotificationItem {
  const NotificationItem({
    required this.type,
    required this.pubkeys,
    required this.extraCount,
    required this.time,
    this.preview,
    this.targetEventId,
    this.sourceEventId,
    this.eventContent,
    this.reactionEmoji,
    this.reactionEmojiUrl,
    required this.id,
    required this.unread,
  });
  final NotificationType type;
  final List<String> pubkeys;
  final int extraCount;
  final int time;
  final String? preview;

  /// The event the notification points at: for replies/reactions/reposts the
  /// user's own post that was interacted with; null for pure mentions.
  final String? targetEventId;

  /// The id of the event that *triggered* the notification (the mentioner's
  /// own post, the reply, etc.). Used as a navigation fallback for mentions,
  /// which have no `targetEventId` — tapping a mention opens this post.
  final String? sourceEventId;
  final String? eventContent;

  /// For kind-7 reactions: the reaction payload. For a unicode reaction ("+",
  /// "🔥") this is the raw content; for a NIP-30 custom-emoji reaction it is
  /// the shortcode *without* the surrounding colons (e.g. "fire", not
  /// ":fire:") — pair it with [reactionEmojiUrl] to render the image.
  final String? reactionEmoji;

  /// The image URL for a NIP-30 custom-emoji reaction; null for unicode
  /// reactions. When present, [reactionEmoji] is the shortcode.
  final String? reactionEmojiUrl;

  final String id;
  final bool unread;
}

// --- Notification subscription provider ---

/// Subscribes to notifications: #p mentions + #e interactions on the user's
/// recent 200 posts. Collects and aggregates into NotificationItem list.
final notificationsProvider =
    StreamProvider.family<List<NotificationItem>, String>((
      ref,
      myPubkey,
    ) async* {
      final pool = ref.watch(relayPoolProvider);
      final items = <NotificationItem>[];
      final myEventIds = <String>{};
      // Mute set (read once + reactively updated WITHOUT restarting the
      // generator — same pattern as myEventIds above). Muted pubkeys' events
      // (mentions, follows, replies, reactions, reposts) are skipped so a
      // muted account stops generating notifications, not just feed entries.
      // Defaults to an empty set until muteListProvider resolves.
      var muteSet = ref.read(myMuteSetProvider);
      // One-time snapshot (NOT ref.watch): watching eventStoreProvider
      // reactively would RESTART this whole generator on every incoming feed
      // event (esp. kind-0 metadata bursts), and each restart yields [] first
      // → the list flickers empty repeatedly until the burst settles. Read
      // once so the generator runs a single time; grow myEventIds via
      // ref.listen below as the user's own posts arrive.
      final myRecentEvents = ref
          .read(eventStoreProvider)
          .where((e) => e.pubkey == myPubkey && e.isTextNote)
          .take(200)
          .map((e) => e.id)
          .toList();
      myEventIds.addAll(myRecentEvents);
      // Reactively grow myEventIds when the user's own new posts arrive —
      // WITHOUT restarting the generator (which would clear the list). Re-fetch
      // interactions on just the newly-seen ids.
      ref.listen(eventStoreProvider, (_, next) {
        final fresh = <String>[];
        for (final e in next) {
          if (e.pubkey == myPubkey && e.isTextNote && myEventIds.add(e.id)) {
            fresh.add(e.id);
          }
        }
        if (fresh.isNotEmpty) {
          final subId = nextSubId('notif-late');
          pool.request(subId, <String, dynamic>{
            'kinds': [1, 7, 6],
            '#e': fresh,
            'limit': 500,
          }, closeOnEose: false);
          ref.onDispose(() => pool.closeSubscription(subId));
        }
      });

      final controller = StreamController<List<NotificationItem>>.broadcast();
      // Reactively update the mute set WITHOUT restarting the generator (same
      // pattern as eventStoreProvider above). On mute, also drop any already-
      // collected notifications from the now-muted pubkey so muting clears
      // their stale items live (not just on the next generator restart).
      ref.listen(myMuteSetProvider, (_, next) {
        muteSet = next;
        if (muteSet.pubkeys.isEmpty) return;
        final before = items.length;
        items.removeWhere((i) => i.pubkeys.any(muteSet.isMutedPubkey));
        if (items.length != before) {
          items.sort((a, b) => b.time.compareTo(a.time));
          controller.add(List.unmodifiable(items));
        }
      });
      Timer? flush;
      bool dirty = false;
      // Per-session seen set: rawEvents (un-deduped) re-emits events already
      // seen on the global feed — without this, the targeted #p/#e REQ's
      // re-fetch of past mentions/replies would be swallowed by the pool's
      // global dedup and the listener would never fire (the "no
      // notifications" bug). Dedup locally by event id instead.
      final seen = <String>{};

      void emit() {
        dirty = false;
        items.sort((a, b) => b.time.compareTo(a.time));
        controller.add(List.unmodifiable(items));
      }

      pool.rawEvents.listen((e) {
        if (e.pubkey == myPubkey) return; // skip my own events
        if (!seen.add(e.id)) return; // already processed this event
        // Muted accounts don't generate notifications (mute applies to the
        // feed AND the notification center — a muted spam/ad account that
        // keeps following or @-mentioning you must not keep surfacing here).
        if (muteSet.isMutedPubkey(e.pubkey)) return;

        // Check #p mention (kind 1, 7, 6 with p tag = me)
        bool mentionsMe = false;
        for (final t in e.tags) {
          if (t.length >= 2 && t[0] == 'p' && t[1] == myPubkey) {
            mentionsMe = true;
            break;
          }
        }

        // Check #e interaction (kind 1/7/6 referencing my post)
        String? referencedId;
        for (final t in e.tags) {
          if (t.length >= 2 && t[0] == 'e' && myEventIds.contains(t[1])) {
            referencedId = t[1];
            break;
          }
        }

        if (!mentionsMe && referencedId == null) return;

        final type = _classify(e, mentionsMe, referencedId != null);
        final itemKey = notificationItemKey(type, e, referencedId);

        // Aggregate: if an item with the same type+target exists, add this pubkey.
        final existing = items.where((i) => i.id == itemKey).firstOrNull;
        if (existing != null) {
          if (!existing.pubkeys.contains(e.pubkey)) {
            final updated = NotificationItem(
              type: existing.type,
              pubkeys: [...existing.pubkeys, e.pubkey].take(5).toList(),
              extraCount: existing.extraCount + 1,
              time: e.createdAt,
              preview: existing.preview,
              targetEventId: existing.targetEventId,
              sourceEventId: existing.sourceEventId,
              eventContent: existing.eventContent,
              reactionEmoji: existing.reactionEmoji,
              reactionEmojiUrl: existing.reactionEmojiUrl,
              id: existing.id,
              unread: true,
            );
            final idx = items.indexOf(existing);
            items[idx] = updated;
          }
        } else {
          final preview = notificationPreview(e);
          final emojiPair = reactionEmojiFor(e);
          final emoji = emojiPair?.emoji;
          final emojiUrl = emojiPair?.url;

          items.add(
            NotificationItem(
              type: type,
              pubkeys: [e.pubkey],
              extraCount: 0,
              time: e.createdAt,
              preview: preview,
              targetEventId: referencedId,
              sourceEventId: e.id,
              eventContent: e.content,
              reactionEmoji: emoji,
              reactionEmojiUrl: emojiUrl,
              id: itemKey,
              unread: true,
            ),
          );
        }
        dirty = true;
        flush ??= Timer(const Duration(milliseconds: 300), () {
          flush = null;
          if (dirty) emit();
        });
      });

      // Subscribe: #p for mentions + #e for interactions on my posts.
      final subId = nextSubId('notif');
      if (myEventIds.isNotEmpty) {
        pool.request(subId, <String, dynamic>{
          'kinds': [1, 7, 6],
          '#e': myEventIds.take(200).toList(),
          'limit': 500,
        }, closeOnEose: false);
      }
      final subId2 = nextSubId('notif-p');
      pool.request(subId2, <String, dynamic>{
        'kinds': [1, 3],
        '#p': [myPubkey],
        'limit': 500,
      }, closeOnEose: false);

      ref.onDispose(() {
        pool.closeSubscription(subId);
        pool.closeSubscription(subId2);
        controller.close();
        flush?.cancel();
      });

      // Initial empty state.
      yield [];
      yield* controller.stream;
    });

NotificationType _classify(Event e, bool mentionsMe, bool interactsMyPost) {
  if (e.kind == 3) return NotificationType.follow;
  if (e.kind == 7) return NotificationType.reaction;
  if (e.kind == 6) return NotificationType.repost;
  // kind 1
  if (mentionsMe && !interactsMyPost) return NotificationType.mention;
  if (interactsMyPost) return NotificationType.reply;
  return NotificationType.mention;
}

/// Aggregation key for an incoming event — two events that should collapse
/// into one notification item return the same key.
///
/// For most types this is `type:target` so multiple people interacting with
/// the same post roll up into one grouped item. Follow is special: a contact
/// list (kind 3) is re-published on every follow/unfollow change with a
/// brand-new event id, so keying on the event id would spawn a duplicate
/// "X followed you" notification for every revision of X's list. Key on the
/// *follower's pubkey* instead so all of X's revisions collapse into one.
String notificationItemKey(
  NotificationType type,
  Event e,
  String? referencedId,
) {
  if (type == NotificationType.follow) return 'follow:${e.pubkey}';
  return '${type.name}:${referencedId ?? e.id}';
}

/// The 2-line preview text shown under the notification head, or null.
///
/// - kind-1 replies/mentions: the author's own words.
/// - kind-6 repost: NIP-18 content is the stringified-JSON of the reposted
///   event — parse it and show the reposted post's OWN text, so the user
///   sees WHICH of their posts was reposted (not the raw JSON, and not
///   nothing). Falls back to null if the embedded JSON is missing/empty.
/// - kind-7 reaction: content is just the emoji payload ("+", "🔥", or
///   ":shortcode:") and is rendered via [reactionEmojiFor] instead, so it
///   must not also appear as preview text (it would show the literal
///   ":shortcode:" token).
String? notificationPreview(Event e) {
  if (e.kind == 1 && e.content.isNotEmpty) return e.content;
  if (e.kind == 6) {
    if (e.content.isEmpty) return null;
    try {
      final obj = jsonDecode(e.content);
      if (obj is Map) {
        final c = obj['content'];
        if (c is String && c.isNotEmpty) return c;
      }
    } catch (_) {
      // Embedded repost payload wasn't valid JSON — no preview.
    }
  }
  return null;
}

/// Kind-7 reaction payload: `(emoji, url?)`. `url` is set for a NIP-30
/// custom-emoji reaction (rendered as an inline image); null for unicode
/// reactions. Returns null for non-kind-7 events.
///
/// - Empty content → the default "+" like (legacy NIP-25).
/// - `:shortcode:` content with a matching `["emoji", shortcode, url]` tag →
///   `(shortcode, url)` — caller renders the image.
/// - `:shortcode:` content with no emoji tag → `(shortcode, null)` — show the
///   bare shortcode (no surrounding colons) rather than the raw token.
/// - Anything else (unicode "🔥", legacy "+") → `(content, null)`.
({String emoji, String? url})? reactionEmojiFor(Event e) {
  if (e.kind != 7) return null;
  // NIP-25: empty content OR literal "+" = the default "like" → render 👍
  // (a real glyph) rather than a bare "+" that users mistook for a stray
  // UI element. Matches Amethyst's default-reaction rendering.
  if (e.content.isEmpty || e.content == '+') {
    return (emoji: '👍', url: null);
  }
  final match = RegExp(r'^:([a-zA-Z0-9_+-]+):$').firstMatch(e.content);
  String? shortcode = match?.group(1);
  String? url;
  for (final t in e.tags) {
    if (t.length >= 3 &&
        t[0] == 'emoji' &&
        t[1] is String &&
        t[2] is String &&
        (shortcode == null || t[1] == shortcode)) {
      shortcode = t[1] as String;
      url = t[2] as String;
      break;
    }
  }
  if (url != null && shortcode != null) {
    return (emoji: shortcode, url: url);
  }
  if (shortcode != null) return (emoji: shortcode, url: null);
  return (emoji: e.content, url: null);
}

// --- Read state (persisted) -----------------------------------------------

/// Config-table key holding the JSON array of read notification item-ids.
const _readKey = 'read_notifications';

/// The set of notification item-ids the user has already seen (read).
/// Persisted to SQLite so the unread badge survives across sessions /
/// cold starts. Hydrated asynchronously from the config table on build.
///
/// A notification item is "unread" iff its id is NOT in this set. The set is
/// capped (oldest evicted) to bound growth — notification ids are short
/// stable strings (`type:target`), and only the recent ~1500 matter for
/// distinguishing unread; older interactions are long gone from the live list.
final notificationReadProvider =
    NotifierProvider<NotificationReadNotifier, Set<String>>(
      NotificationReadNotifier.new,
    );

class NotificationReadNotifier extends Notifier<Set<String>> {
  Timer? _save;

  @override
  Set<String> build() {
    final db = ref.read(localCacheProvider).value;
    if (db == null) {
      // Cache not ready yet (cold start) — hydrate once it resolves.
      ref.listen(localCacheProvider, (_, next) {
        if (next.hasValue && next.value != null) _hydrate(next.value!);
      });
    } else {
      _hydrate(db);
    }
    ref.onDispose(() => _save?.cancel());
    return <String>{};
  }

  Future<void> _hydrate(cache.LocalCache db) async {
    try {
      final raw = await db.readConfig(_readKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<String>();
        state = LinkedHashSet<String>.from(list);
      }
    } catch (_) {
      // Corrupt JSON — start fresh (next markRead rewrites a clean array).
    }
  }

  /// Mark [ids] read (idempotent). Persists debounced (500ms) to SQLite.
  void markRead(Iterable<String> ids) {
    if (ids.isEmpty) return;
    final next = LinkedHashSet<String>.from(state)..addAll(ids);
    // Cap: evict oldest-inserted ids beyond 1500 (linked iteration order).
    while (next.length > 1500) {
      next.remove(next.first);
    }
    // Only dirty + schedule a write if the set actually grew.
    if (next.length == state.length && state.containsAll(next)) return;
    state = next;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), () {
      _save = null;
      final db = ref.read(localCacheProvider).value;
      if (db == null) return;
      db.writeConfig(_readKey, jsonEncode(next.toList()));
    });
  }

  bool isUnread(String id) => !state.contains(id);
}

/// Number of currently-unread notifications for [myPubkey]. Watching this
/// (e.g. from the bottom-nav badge in [AppShell]) keeps [notificationsProvider]
/// alive across tabs so the badge updates while the user is elsewhere in the
/// app — the notification subscription is a foreground-live feed per
/// DESIGN §5.1 / §10 (background pauses via the relay pool disconnect).
final unreadNotificationCountProvider = Provider.family<int, String>((
  ref,
  myPubkey,
) {
  final items =
      ref.watch(notificationsProvider(myPubkey)).value ??
      const <NotificationItem>[];
  final read = ref.watch(notificationReadProvider);
  var count = 0;
  for (final i in items) {
    if (!read.contains(i.id)) count++;
  }
  return count;
});

// --- UI ---

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});
  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  String _tab = 'all';

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider).value;
    final myPubkey = identity?.pubkeyHex;
    if (myPubkey == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('通知')),
        body: const Center(child: Text('未登录')),
      );
    }
    final async = ref.watch(notificationsProvider(myPubkey));
    final unreadCount =
        ref.watch(unreadNotificationCountProvider(myPubkey));
    // Lifted out of `.when` so the AppBar action can mark-all-read without
    // rebuilding the body. `filtered` follows the current _tab.
    final allItems = async.value ?? const <NotificationItem>[];
    final filtered = _tab == 'mentions'
        ? allItems
              .where(
                (i) =>
                    i.type == NotificationType.mention ||
                    i.type == NotificationType.reply,
              )
              .toList()
        : allItems;
    return ImmersiveScaffold(
      topBar: AppBar(
        title: const Text('通知'),
        actions: [
          // Mark all currently-shown notifications as read. First login can
          // surface a large backlog of historical unread (DESIGN §5.2) —
          // tapping one-by-one isn't practical, so this clears the visible
          // tab in one shot. Hidden when there's nothing unread.
          if (unreadCount > 0)
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: '全部标记已读',
              onPressed: () {
                final ids = filtered
                    .where((i) => !ref
                        .read(notificationReadProvider)
                        .contains(i.id))
                    .map((i) => i.id)
                    .toList();
                if (ids.isEmpty) return;
                ref.read(notificationReadProvider.notifier).markRead(ids);
              },
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings/notifications'),
          ),
        ],
      ),
      body: Column(
        children: [
          // All / Mentions tabs.
          Material(
            color: CostrColors.bg,
            child: Row(
              children: [
                _TabButton(
                  '全部',
                  _tab == 'all',
                  () => setState(() => _tab = 'all'),
                ),
                _TabButton(
                  '提及',
                  _tab == 'mentions',
                  () => setState(() => _tab = 'mentions'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ImmersiveScrollDetector(
              child: async.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (_, _) => const Center(child: Text('通知加载失败')),
                data: (_) {
                  // Read/unread is per-item, marked read on tap (DESIGN §5.2
                  // updated): no whole-page auto-markRead — unread styling stays
                  // stable until the user actually opens an item. The bottom-nav
                  // badge counts items not yet marked read. The done_all action
                  // above is the explicit bulk-clear path.
                  if (filtered.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '还没有通知。\n有人 @你、回复、喜欢你的帖子时会出现在这里。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => _NotificationTile(
                      item: filtered[i],
                      myPubkey: myPubkey,
                    ),
                  );
              },
            ),
          ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton(this.label, this.selected, this.onTap);
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? CostrColors.brand : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: selected ? CostrColors.text : CostrColors.text3,
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends ConsumerWidget {
  const _NotificationTile({required this.item, required this.myPubkey});
  final NotificationItem item;
  final String myPubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final icon = _iconForType(item.type);
    final iconColor = _colorForType(item.type);
    // Unread is derived from the persisted read-set (not the vestigial
    // item.unread flag, which is always true at creation). Per-item: stays
    // unread until the user taps it (stable styling — no whole-page clear).
    final unread = !ref.watch(notificationReadProvider).contains(item.id);
    final head = item.extraCount > 0
        ? '${item.pubkeys.length} 人和另外 ${item.extraCount} 人'
        : item.pubkeys.map((pk) => _displayName(ref, pk)).take(3).join('、');
    final verb = _verbForType(item.type);

    return InkWell(
      onTap: () {
        // Mark this item read (per-item; stable unread styling until tap).
        ref.read(notificationReadProvider.notifier).markRead([item.id]);
        // Follow → open the follower's profile. MUST be checked before the
        // target-event fallback below: a follow item carries sourceEventId
        // (the kind-3 event's own id) but that is NOT a post to open —
        // without this guard, tapping "X 关注你" would push a post-detail
        // page for the kind-3 id (which isn't a post) instead of X's profile.
        if (item.type == NotificationType.follow) {
          if (item.pubkeys.isNotEmpty) {
            context.push('/u/${item.pubkeys.first}');
          } else {
            context.go('/profile');
          }
          return;
        }
        // Replies/reactions/reposts point at the user's own post
        // (targetEventId); pure mentions have no target, so fall back to the
        // mentioner's own post (sourceEventId) — tapping a mention opens the
        // post that mentioned you.
        final target = item.targetEventId ?? item.sourceEventId;
        if (target != null) {
          pushPostDetail(context, target);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // Subtle background tint on unread items (X-style); read items stay
        // plain. Combined with the dot below for a stable read/unread split.
        decoration: BoxDecoration(
          color: unread ? CostrColors.bg2 : null,
          border: const Border(bottom: BorderSide(color: CostrColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon + unread dot.
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  Icon(icon, size: 22, color: iconColor),
                  const SizedBox(height: 6),
                  if (unread)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: CostrColors.brand,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Avatars (up to 3, overlapping). Transform.translate shifts each
            // avatar left so they overlap visually; Padding disallows negative
            // values (asserts padding.isNonNegative), so we must not use a
            // negative EdgeInsets here.
            Row(
              children: [
                for (var i = 0; i < item.pubkeys.length && i < 3; i++)
                  Transform.translate(
                    offset: Offset(i == 0 ? 0 : -8.0, 0),
                    child: Avatar(pubkey: item.pubkeys[i], radius: 16),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            // Description + preview + time.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium,
                      children: [
                        TextSpan(
                          text: head,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: ' $verb',
                          style: TextStyle(color: CostrColors.text2),
                        ),
                        // For reactions, show the actual emoji inline after the
                        // verb — a NIP-30 custom-emoji image when we have a URL,
                        // otherwise the unicode payload (e.g. "🔥" or "+").
                        // This replaces the old behavior of dumping the raw
                        // ":shortcode:" content as preview text.
                        if (item.type == NotificationType.reaction &&
                            item.reactionEmoji != null) ...[
                          const TextSpan(text: ' '),
                          if (item.reactionEmojiUrl != null)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: CachedNetworkImage(
                                imageUrl: item.reactionEmojiUrl!,
                                width: 18,
                                height: 18,
                                memCacheHeight: 72,
                                errorWidget: (_, _, _) => Text(
                                  item.reactionEmoji!,
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            )
                          else
                            TextSpan(
                              text: item.reactionEmoji,
                              style: const TextStyle(fontSize: 16),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (item.preview != null) ...[
                    const SizedBox(height: 4),
                    Text.rich(
                      linkifyMentions(
                        item.preview!,
                        ref,
                        baseStyle: TextStyle(
                          fontSize: 14,
                          color: CostrColors.text2,
                        ),
                        mentionStyle: TextStyle(
                          fontSize: 14,
                          color: CostrColors.brand,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _relativeTime(item.time),
                    style: TextStyle(fontSize: 12, color: CostrColors.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _displayName(WidgetRef ref, String pubkey) {
    final meta = ref.read(metadataProvider(pubkey)).value;
    final name = meta?.bestName;
    if (name != null && name.isNotEmpty) return name;
    try {
      return shortenEntity(hexToNpub(pubkey));
    } catch (_) {
      return pubkey.substring(0, 8);
    }
  }

  String _relativeTime(int createdAt) {
    final eventTime = DateTime.fromMillisecondsSinceEpoch(
      createdAt * 1000,
      isUtc: true,
    );
    final delta = DateTime.now().difference(eventTime);
    if (delta.isNegative) return '刚刚';
    final mins = delta.inMinutes;
    if (mins < 1) return '刚刚';
    if (mins < 60) return '$mins分钟前';
    final hours = delta.inHours;
    if (hours < 24) return '$hours小时前';
    return '${delta.inDays}天前';
  }
}

IconData _iconForType(NotificationType t) {
  switch (t) {
    case NotificationType.reply:
    case NotificationType.mention:
    case NotificationType.quote:
      return Icons.chat_bubble_outline;
    case NotificationType.reaction:
      return Icons.favorite;
    case NotificationType.repost:
      return Icons.repeat;
    case NotificationType.follow:
      return Icons.person_add;
  }
}

Color _colorForType(NotificationType t) {
  switch (t) {
    case NotificationType.reaction:
      return CostrColors.red;
    case NotificationType.repost:
      return CostrColors.green;
    case NotificationType.follow:
      return CostrColors.blue;
    default:
      return CostrColors.text2;
  }
}

String _verbForType(NotificationType t) {
  switch (t) {
    case NotificationType.reply:
      return '回复了你的帖子';
    case NotificationType.mention:
      return '在帖子里 @了你';
    case NotificationType.reaction:
      return '喜欢了你的帖子';
    case NotificationType.repost:
      return '转发了你的帖子';
    case NotificationType.follow:
      return '开始关注你';
    case NotificationType.quote:
      return '引用了你的帖子';
  }
}
