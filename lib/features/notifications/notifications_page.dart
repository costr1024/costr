/// Notification center (DESIGN.md §5).
///
/// Subscribes to mentions (#p) + interactions (#e on my recent posts).
/// Aggregates by type+target (X-style grouping). All/Mentions tabs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';

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
    this.eventContent,
    this.reactionEmoji,
    required this.id,
    required this.unread,
  });
  final NotificationType type;
  final List<String> pubkeys;
  final int extraCount;
  final int time;
  final String? preview;
  final String? targetEventId;
  final String? eventContent;
  final String? reactionEmoji;
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
      final myRecentEvents = ref
          .watch(eventStoreProvider)
          .where((e) => e.pubkey == myPubkey && e.isTextNote)
          .take(200)
          .map((e) => e.id)
          .toList();
      myEventIds.addAll(myRecentEvents);

      final controller = StreamController<List<NotificationItem>>.broadcast();
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
        final itemKey = '${type.name}:${referencedId ?? e.id}';

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
              eventContent: existing.eventContent,
              reactionEmoji: existing.reactionEmoji,
              id: existing.id,
              unread: true,
            );
            final idx = items.indexOf(existing);
            items[idx] = updated;
          }
        } else {
          items.add(
            NotificationItem(
              type: type,
              pubkeys: [e.pubkey],
              extraCount: 0,
              time: e.createdAt,
              preview: e.content.isNotEmpty ? e.content : null,
              targetEventId: referencedId,
              eventContent: e.content,
              reactionEmoji: e.kind == 7
                  ? (e.content.isEmpty ? '+' : e.content)
                  : null,
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        actions: [
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
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const Center(child: Text('通知加载失败')),
              data: (items) {
                final filtered = _tab == 'mentions'
                    ? items
                          .where(
                            (i) =>
                                i.type == NotificationType.mention ||
                                i.type == NotificationType.reply,
                          )
                          .toList()
                    : items;
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
                  itemBuilder: (_, i) =>
                      _NotificationTile(item: filtered[i], myPubkey: myPubkey),
                );
              },
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
    final head = item.extraCount > 0
        ? '${item.pubkeys.length} 人和另外 ${item.extraCount} 人'
        : item.pubkeys.map((pk) => _displayName(ref, pk)).take(3).join('、');
    final verb = _verbForType(item.type);

    return InkWell(
      onTap: () {
        if (item.targetEventId != null) {
          context.push('/n/${item.targetEventId}');
        } else if (item.type == NotificationType.follow) {
          // Go to my followers tab.
          context.go('/profile');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: CostrColors.border)),
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
                  if (item.unread)
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
                      ],
                    ),
                  ),
                  if (item.preview != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.preview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: CostrColors.text2),
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
