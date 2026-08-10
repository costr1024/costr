/// Notification center (DESIGN.md §5).
///
/// Subscribes to mentions (#p) + interactions (#e on my recent posts).
/// Aggregates by type+target (X-style grouping). All/Mentions tabs.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../nostr/relay_pool.dart';
import '../../services/local_cache.dart' as cache;
import '../../utils/nav.dart';
import '../../widgets/avatar.dart';
import '../../widgets/display_name.dart';
import '../../widgets/double_tap_shortcut.dart';
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

  /// The user's own post the notification's event interacts with (the reply's
  /// parent, the reacted/reposted post); null for pure mentions. Reaction/
  /// repost taps open this; reply/mention taps open [sourceEventId] instead.
  final String? targetEventId;

  /// The id of the event that *triggered* the notification (the reply, the
  /// mentioning note, the mentioner's post). Reply/mention taps open THIS —
  /// the incoming post is the new content the user wants to read. For
  /// reactions/reposts it's a kind-7/6 event (not displayable), used only as
  /// a last-resort fallback when [targetEventId] is null.
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

/// Test seam: the follow gate's verdict timeout (6s in production). Tests
/// shorten it so the timeout→skip path is verifiable without a 6s wait.
@visibleForTesting
Duration followGateTimeout = const Duration(seconds: 6);

/// Subscribes to notifications: #p mentions + #e interactions on the user's
/// recent 200 posts. Collects and aggregates into NotificationItem list.
///
/// autoDispose: the provider family is keyed by pubkey, and ONLY the active
/// account's instance stays alive (AppShell's unread badge + the page watch
/// it). On an account switch the old account's instance loses its last
/// listener and is disposed — closing its relay REQs — so non-active accounts
/// hold NO connections and generate NO notifications.
final notificationsProvider = StreamProvider.autoDispose
    .family<List<NotificationItem>, String>((ref, myPubkey) async* {
      final pool = ref.watch(relayPoolProvider);
      // Wait for the event store's cold-start hydration before snapshotting
      // own posts + registering the listener. Reply/mention classification
      // gates e-tags against myEventIds: judging an event BEFORE hydration
      // lands yields a different item id than after (mention:<eventId> vs
      // reply:<myPostId>) — the persisted read-set then misses on the next
      // launch and already-read notifications resurface as unread ("已读通知
      // 复活" bug). Hydration is a local SQLite read; the REQs issued below
      // re-fetch anything the relays pushed while we waited.
      await ref.read(eventStoreProvider.notifier).hydrated;
      if (!ref.mounted) return;
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
      // Persistent own-post ids from SQLite. The in-memory store snapshot only
      // carries the global newest-1000 feed window (queryFeed), so WHICH old
      // own posts are in myEventIds varies with global activity between
      // launches — reply/mention classification (and therefore item keys:
      // `reply:<myPostId>` vs `mention:<eventId>`) flipped across cold starts
      // and the persisted read-set missed ("已读通知复活" RC2: v0.8.7 fixed the
      // hydration TIMING race, not the snapshot CONTENT divergence). The DB
      // copy is stable across launches. Ordering at the store/DB boundary is
      // only approximate (store eviction is kind-priority, not per-author) —
      // harmless: take(200) below still targets ~the newest own posts, and
      // gating membership is order-agnostic.
      try {
        final db = await ref.read(localCacheProvider.future);
        final rows = await db.queryUserPosts(myPubkey, limit: 500);
        if (ref.mounted) {
          for (final row in rows) {
            myEventIds.add(row.id);
          }
        }
      } catch (_) {
        // DB unavailable (open failure / test environment without a cache
        // override) — the store snapshot alone still classifies recent posts.
      }
      if (!ref.mounted) return;
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
      // Follow gate: only the NEWEST kind-3 revision per author gets judged —
      // a contact-list revision by a LONG-TIME follower (they followed
      // someone new and re-published kind 3, still listing me) must not
      // surface as a fresh "X 开始关注你" ("重复关注通知" bug). Relays answer
      // the #p REQ newest-first, so the first-seen revision per author is
      // their latest.
      final followEvaluated = <String>{};

      void emit() {
        dirty = false;
        items.sort((a, b) => b.time.compareTo(a.time));
        controller.add(List.unmodifiable(items));
      }

      final rawSub = pool.rawEvents.listen((e) {
        if (e.pubkey == myPubkey) return; // skip my own events
        if (!seen.add(e.id)) return; // already processed this event
        // Muted accounts don't generate notifications (mute applies to the
        // feed AND the notification center — a muted spam/ad account that
        // keeps following or @-mentioning you must not keep surfacing here).
        if (muteSet.isMutedPubkey(e.pubkey)) return;
        // Kind whitelist: relay output is UNTRUSTED — a buggy/misbehaving
        // relay can deliver events no active filter requested (real attack:
        // spam kind-30000 people-lists re-published every few minutes with
        // dozens of p-tags, "mention farming" — each revision surfaced as
        // "在帖子里 @了你" and opened into an empty non-post). Classify only
        // the four kinds the notification center understands: 1 mention/
        // reply, 3 follow, 6 repost, 7 reaction.
        if (e.kind != 1 && e.kind != 3 && e.kind != 6 && e.kind != 7) return;

        // Check #p mention (kind 1, 7, 6 with p tag = me)
        bool mentionsMe = false;
        for (final t in e.tags) {
          if (t.length >= 2 && t[0] == 'p' && t[1] == myPubkey) {
            mentionsMe = true;
            break;
          }
        }

        // Check #e interaction (kind 1/7/6 referencing my post) — NIP-10
        // marker precedence so root+reply tags both mine resolve to the post
        // actually interacted with, not the thread root.
        final referencedId = notificationReferencedId(e, myEventIds);

        if (!mentionsMe && referencedId == null) return;

        final type = _classify(e, mentionsMe, referencedId != null);
        // Navigation + aggregation target. For reactions/reposts this is the
        // post interacted with: prefer the gated referencedId, but when it
        // misses (liked/reposted own post is OLDER than the recent-200 own
        // posts held in memory) fall back to the un-gated primary e-tag —
        // otherwise targetEventId stayed null and the tap fell back to the
        // kind-7/6 event itself ("点赞通知跳到点赞事件本身" bug).
        final targetId =
            (type == NotificationType.reaction ||
                type == NotificationType.repost)
            ? (referencedId ?? primaryETagTarget(e))
            : referencedId;
        final itemKey = notificationItemKey(type, e, targetId);

        void addOrUpdate() {
          // Aggregate: if an item with the same type+target exists, add pubkey.
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
                targetEventId: targetId,
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
        }

        if (type == NotificationType.follow) {
          // Follow gate (async): a contact-list REVISION by an existing
          // follower (previous revision already listed me) is not a new
          // follow — skip it. Only the newest revision per author is judged;
          // older revisions of the same author never spawn their own item.
          if (!followEvaluated.add(e.pubkey)) return;
          unawaited(
            previousContactListContainsMe(
              pool,
              e.pubkey,
              e.createdAt,
              myPubkey,
              timeout: followGateTimeout,
            ).then((already) {
              // TRI-STATE: only a CONFIRMED new follow (== false) emits.
              // true = contact-list revision (skip); null = gate timed out
              // (skip — a slow relay must not re-notify old followers).
              if (already == false) addOrUpdate();
            }),
          );
          return;
        }
        addOrUpdate();
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
        rawSub.cancel();
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

/// NIP-10 marker precedence (reply > positional > root) over [e]'s `e` tags.
/// When [onlyIds] is given, only ids in that set are considered (gated);
/// otherwise every `e` tag is a candidate (un-gated).
///
/// Marker handling: NIP-10 defines `root` / `reply` / `mention`. Some clients
/// — notably Amethyst, which generates many of the reactions on this network —
/// put the interacted post's AUTHOR PUBKEY in the marker slot of a reaction's
/// `e` tag (`["e", <liked-id>, <relay>, <pubkey>]`, plus a `["k", <kind>]`
/// tag). Any unrecognized non-empty marker is therefore treated as a direct
/// (positional) reference — the `e` tag still names the interacted post, so
/// it must resolve. Only `mention` is excluded (never an interaction).
String? _primaryETagTarget(Event e, {Set<String>? onlyIds}) {
  String? replyRef;
  String? positionalRef;
  String? rootRef;
  for (final t in e.tags) {
    if (t.length < 2 || t[0] != 'e' || t[1] is! String) continue;
    final id = t[1] as String;
    if (onlyIds != null && !onlyIds.contains(id)) continue;
    final marker = (t.length >= 4 && t[3] is String) ? (t[3] as String) : '';
    if (marker == 'reply') {
      replyRef ??= id;
    } else if (marker == 'root') {
      rootRef ??= id;
    } else if (marker == 'mention') {
      // A mention marker is never an interaction — skip.
    } else {
      // Empty marker (legacy positional) OR an unrecognized one (e.g.
      // Amethyst's pubkey-in-marker-slot) → direct reference to the post.
      positionalRef ??= id;
    }
  }
  return replyRef ?? positionalRef ?? rootRef;
}

/// The id of the user's own post an incoming event interacts with, or null.
///
/// NIP-10 marker precedence (reply > positional > root) restricted to
/// [myEventIds]: a reply/reaction that carries BOTH a root and a reply
/// `e`-tag — both mine (e.g. I wrote the thread root AND the post being
/// replied to) — must resolve to the post actually interacted with, NOT the
/// thread root. The old first-match scan grabbed the root (tags list it
/// first), so tapping the notification opened the root main post instead of
/// the replied/liked post ("跳到 root 主贴" bug). `mention` markers are never
/// interactions.
@visibleForTesting
String? notificationReferencedId(Event e, Set<String> myEventIds) =>
    _primaryETagTarget(e, onlyIds: myEventIds);

/// The post an event references via `e` tags (NIP-10 precedence), NOT gated
/// on [myEventIds]. Used as the navigation/aggregation target for reactions
/// and reposts when the gated [notificationReferencedId] misses: `myEventIds`
/// only holds the recent-200 own posts currently in memory, so a like on an
/// OLDER own post resolved to null there and the tap fell back to the kind-7
/// reaction event itself ("点赞通知跳到点赞事件本身" bug). The reaction's
/// `e` tag still names the liked post — use it directly.
@visibleForTesting
String? primaryETagTarget(Event e) => _primaryETagTarget(e);

/// True when [contactList] (a kind-3 event) carries a `p` tag for
/// [pubkeyHex].
@visibleForTesting
bool contactListContains(Event contactList, String pubkeyHex) {
  for (final t in contactList.tags) {
    if (t.length >= 2 && t[0] == 'p' && t[1] == pubkeyHex) return true;
  }
  return false;
}

/// One-shot kind-3 fetch for the follow gate: the newest kind-3 by [author]
/// (optionally older than [until]), first hit wins. `timedOut` distinguishes
/// "no relay answered" from "every relay EOSEd empty" (author has no such
/// list).
Future<({bool timedOut, Event? event})> _fetchAuthorContactList(
  RelayPool pool,
  String author, {
  int? until,
  required Duration timeout,
  required String subIdPrefix,
}) async {
  final completer = Completer<Event?>();
  var timedOut = false;
  final relayCount = pool.states.length;
  var eoses = 0;
  final sub = pool.rawEvents.listen((e) {
    if (e.kind != 3 || e.pubkey != author) return;
    if (until != null && e.createdAt >= until) return;
    if (!completer.isCompleted) completer.complete(e);
  });
  final subId = nextSubId(subIdPrefix);
  final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (relayCount > 0 && eoses >= relayCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(subId, <String, dynamic>{
    'kinds': [3],
    'authors': [author],
    'until': ?until,
    'limit': 1,
  }, closeOnEose: true);
  Event? hit;
  try {
    hit = await completer.future.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        return null;
      },
    );
  } finally {
    await sub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
  return (timedOut: timedOut, event: hit);
}

/// Whether the incoming kind-3 (by [author], created at [untilCreatedAt]) is
/// a genuine NEW follow of [me] — the gate behind every "开始关注你"
/// notification ("重复关注通知" bug: followers re-publish kind 3 whenever
/// they follow anyone, and the #p subscription surfaced every revision).
///
/// Decision tree (tri-state; null always means SKIP):
/// 1. Previous list (REQ until: created-1) found → it decides:
///    contains me → `true` (contact-list REVISION by an existing follower,
///    skip); doesn't → `false` (new follow, notify).
/// 2. No older list anywhere: might be a genuinely new follow, OR a STALE
///    re-serve of an old revision whose successors the relays already hold
///    (real case: a follower churned 10 list versions in minutes, then
///    UNfollowed — the old lists-me=true versions kept being re-served on
///    cold starts while the newest list no longer held me). Compare the
///    author's LATEST list: strictly newer than the incoming event → the
///    incoming one is stale → `null` (skip); otherwise the incoming event is
///    itself the latest → `false` (notify).
/// 3. Any timeout (slow/dead relays) → `null` (skip): a slow relay must not
///    resurface an old follower as "开始关注你"; a genuinely new follower
///    missed here still appears in the followers list.
@visibleForTesting
Future<bool?> previousContactListContainsMe(
  RelayPool pool,
  String author,
  int untilCreatedAt,
  String me, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final prev = await _fetchAuthorContactList(
    pool,
    author,
    until: untilCreatedAt - 1,
    timeout: timeout,
    subIdPrefix: 'notif-prev',
  );
  if (prev.timedOut) return null;
  if (prev.event != null) return contactListContains(prev.event!, me);
  // No older list found — check whether the incoming event is still the
  // author's latest list before declaring a new follow.
  final latest = await _fetchAuthorContactList(
    pool,
    author,
    timeout: timeout,
    subIdPrefix: 'notif-latest',
  );
  if (latest.timedOut) return null;
  final l = latest.event;
  if (l != null && l.createdAt > untilCreatedAt) return null; // stale
  return false; // genuinely new (or the incoming IS the latest)
}

/// Aggregation key for an incoming event — two events that should collapse
/// into one notification item return the same key.
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

/// The event id the detail page should open when [item] is tapped, or null
/// (follow items navigate to a profile instead).
///
/// - reply / mention / quote: open the INCOMING post itself (the reply, the
///   mentioning note) — that's the new content the user wants to read
///   ("跳转到我点击的那条回帖"). [NotificationItem.targetEventId] is the
///   user's OWN post, which is wrong here.
/// - reaction / repost: open the user's OWN post that was interacted with
///   ("被点赞/转发的帖子"). [NotificationItem.sourceEventId] is a kind-7/6
///   event, not a displayable post, so prefer targetEventId.
@visibleForTesting
String? notificationNavTarget(NotificationItem item) {
  switch (item.type) {
    case NotificationType.reply:
    case NotificationType.mention:
    case NotificationType.quote:
      return item.sourceEventId ?? item.targetEventId;
    case NotificationType.reaction:
    case NotificationType.repost:
      return item.targetEventId ?? item.sourceEventId;
    case NotificationType.follow:
      return null;
  }
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
  if (e.kind == 1 && e.content.isNotEmpty) return flattenPreview(e.content);
  if (e.kind == 6) {
    if (e.content.isEmpty) return null;
    try {
      final obj = jsonDecode(e.content);
      if (obj is Map) {
        final c = obj['content'];
        if (c is String && c.isNotEmpty) return flattenPreview(c);
      }
    } catch (_) {
      // Embedded repost payload wasn't valid JSON — no preview.
    }
  }
  return null;
}

/// Collapse every whitespace run (incl. newlines) in a preview to single
/// spaces. Post bodies nearly always carry newlines ("#Costr\nv0.6-beta发布…")
/// and rendering them verbatim in the 2-line preview wastes a whole line on
/// "#Costr" alone (通知排版截图) — flattened, both lines show real content.
@visibleForTesting
String flattenPreview(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

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

/// Config-table key prefix holding the JSON array of read notification
/// item-ids, per account (`<prefix><pubkey>`). Pre-per-account builds wrote a
/// single global key ([_legacyReadKey]); that key seeds the migration and is
/// NEVER deleted (a second account logging in on this device migrates from it
/// too).
const _readKeyPrefix = 'read_notifications:';
const _legacyReadKey = 'read_notifications';

/// Config-table key prefix holding the per-account read watermark (decimal
/// seconds). Everything at/below the watermark is read regardless of the
/// item-id set — see [notificationWatermarkProvider].
const _watermarkKeyPrefix = 'read_notifications_watermark:';

/// True when [item] should still display as unread.
///
/// An item is unread iff it is NEWER than the account's read watermark AND
/// its id is absent from the persisted read set. The watermark makes read
/// state survive read-set eviction and item-key churn across launches — the
/// "已读通知反复复活" fix (a set-only model resurrected ancient notifications
/// whenever their id was evicted from the capped set, or re-classified into a
/// different key between cold start and a long session).
bool notificationIsUnread(
  NotificationItem item,
  Set<String> read,
  int watermark,
) => item.time > watermark && !read.contains(item.id);

/// The set of notification item-ids the user has already seen (read),
/// PER ACCOUNT. Persisted to SQLite so the unread badge survives across
/// sessions / cold starts. Hydrated asynchronously from the config table on
/// build.
///
/// A notification item is "unread" iff [notificationIsUnread] says so (id
/// not in this set AND newer than the watermark). The set is capped (oldest
/// evicted) to bound growth — eviction no longer resurrects old items because
/// the watermark covers everything fully read; the cap only bounds
/// partially-read history since the last watermark advance.
final notificationReadProvider =
    NotifierProvider.family<NotificationReadNotifier, Set<String>, String>(
      NotificationReadNotifier.new,
    );

class NotificationReadNotifier extends Notifier<Set<String>> {
  NotificationReadNotifier(this.pubkey);

  /// The account this read-set belongs to (family arg). Two accounts on one
  /// device keep separate sets — a follow notification marked read by one
  /// must not vanish for the other.
  final String pubkey;

  Timer? _save;
  bool _dirty = false;
  cache.LocalCache? _db;

  /// Cached at build: onDispose may not read [ref] (Riverpod lifecycle
  /// assertion), so the dispose-flush awaits the DB open via this future.
  late Future<cache.LocalCache> _dbFuture;

  /// Mirror of [state] as a list, kept in sync on every mutation. onDispose
  /// may not read [state] or [ref] (Riverpod lifecycle assertion), so the
  /// dispose-flush writes this snapshot instead.
  List<String> _snapshot = const [];

  @override
  Set<String> build() {
    _db = ref.read(localCacheProvider).value;
    _dbFuture = ref.read(localCacheProvider.future);
    if (_db == null) {
      // Cache not ready yet (cold start) — hydrate once it resolves.
      ref.listen(localCacheProvider, (_, next) {
        if (next.hasValue && next.value != null) {
          _db = next.value;
          _hydrate(next.value!);
        }
      });
    } else {
      _hydrate(_db!);
    }
    ref.onDispose(() {
      _save?.cancel();
      // Flush a pending debounced write instead of dropping it — killing the
      // app right after 全部已读 must not lose the marks. No state/ref access
      // here (Riverpod forbids both inside life-cycles); the DB-write future
      // was cached at build. Instance fields (pubkey/_snapshot) ARE readable.
      if (_dirty) {
        _dirty = false;
        final encoded = jsonEncode(_snapshot);
        final key = '$_readKeyPrefix$pubkey';
        final db = _db;
        if (db != null) {
          db.writeConfig(key, encoded);
        } else {
          _dbFuture.then((d) => d.writeConfig(key, encoded), onError: (_) {});
        }
      }
    });
    return <String>{};
  }

  Future<void> _hydrate(cache.LocalCache db) async {
    try {
      final key = '$_readKeyPrefix$pubkey';
      var raw = await db.readConfig(key);
      var migratedFromLegacy = false;
      if (raw == null || raw.isEmpty) {
        // Migration: seed from the legacy GLOBAL key (pre-per-account
        // builds). Never deleted — the device's second account migrates
        // from it too.
        raw = await db.readConfig(_legacyReadKey);
        migratedFromLegacy = raw != null && raw.isNotEmpty;
      }
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<String>();
        // UNION with the in-memory set: markRead may have run BEFORE hydration
        // completed (cold-start tap on 全部已读 while SQLite still opens) —
        // replacing the set would clobber those fresh marks and resurrect
        // unread dots for items the user just cleared.
        final merged = LinkedHashSet<String>.from(list)..addAll(state);
        _snapshot = merged.toList();
        state = merged;
        if (migratedFromLegacy) {
          // Persist the migrated set under the per-account key right away so
          // it survives even if the user never marks anything read again.
          db.writeConfig(key, jsonEncode(_snapshot));
        }
      }
    } catch (_) {
      // Corrupt JSON — start fresh (next markRead rewrites a clean array).
    }
  }

  /// Mark [ids] read (idempotent). Persists debounced (500ms) to SQLite.
  void markRead(Iterable<String> ids) {
    if (ids.isEmpty) return;
    final next = LinkedHashSet<String>.from(state)..addAll(ids);
    // Cap: evict oldest-inserted ids beyond 5000 (linked iteration order).
    // Eviction no longer resurrects notifications: everything fully read is
    // covered by the watermark (see notificationWatermarkProvider); the cap
    // only bounds partially-read history since the last watermark advance.
    while (next.length > 5000) {
      next.remove(next.first);
    }
    // Only dirty + schedule a write if the set actually grew.
    if (next.length == state.length && state.containsAll(next)) return;
    _snapshot = next.toList();
    state = next;
    _dirty = true;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), () {
      _save = null;
      _persist();
    });
  }

  /// Write the current set to SQLite. Awaits the DB OPEN (`.future`, not
  /// `.value`) so a cold-start markRead fired before the cache is ready still
  /// lands instead of being silently dropped.
  void _persist() {
    _dirty = false;
    final encoded = jsonEncode(state.toList());
    final key = '$_readKeyPrefix$pubkey';
    final db = _db;
    if (db != null) {
      db.writeConfig(key, encoded);
      return;
    }
    try {
      ref.read(localCacheProvider.future).then((d) {
        _db ??= d;
        return d.writeConfig(key, encoded);
      }, onError: (_) {});
    } catch (_) {
      // Container already gone — nothing to persist to.
    }
  }

  bool isUnread(String id) => !state.contains(id);
}

/// Per-account read WATERMARK (seconds): every notification at/below this
/// time is read, full stop. The anti-resurrection anchor:
///
/// - The capped read set evicts old ids; a set-only model re-counted the
///   evicted items' (ancient) notifications as unread every launch — and
///   marking them read evicted OTHER old ids, rotating the resurrection
///   ("很早之前就通知过的信息反复重新通知").
/// - Reply/mention item keys can churn across launches (own-post snapshot
///   divergence) — the watermark is key-independent.
///
/// Advanced by 全部已读 (over every tab) and by [compactIfFullyRead] when the
/// user has read the last unread item; per-item taps do NOT move it (DESIGN
/// §5.2 per-item semantics).
final notificationWatermarkProvider =
    NotifierProvider.family<NotificationWatermarkNotifier, int, String>(
      NotificationWatermarkNotifier.new,
    );

class NotificationWatermarkNotifier extends Notifier<int> {
  NotificationWatermarkNotifier(this.pubkey);
  final String pubkey;

  cache.LocalCache? _db;
  late Future<cache.LocalCache> _dbFuture;

  String get _key => '$_watermarkKeyPrefix$pubkey';

  @override
  int build() {
    _db = ref.read(localCacheProvider).value;
    _dbFuture = ref.read(localCacheProvider.future);
    if (_db == null) {
      // Cache not ready yet (cold start) — hydrate once it resolves.
      ref.listen(localCacheProvider, (_, next) {
        if (next.hasValue && next.value != null) {
          _db = next.value;
          _hydrate(next.value!);
        }
      });
    } else {
      _hydrate(_db!);
    }
    return 0;
  }

  Future<void> _hydrate(cache.LocalCache db) async {
    try {
      final raw = await db.readConfig(_key);
      if (raw == null || raw.isEmpty) return;
      final parsed = int.tryParse(raw);
      if (parsed == null) return;
      // MAX-merge: advance() may have run BEFORE hydration completed —
      // replacing would roll the watermark back and resurrect items.
      final merged = parsed > state ? parsed : state;
      state = merged;
    } catch (_) {
      // Corrupt value — keep the in-memory watermark.
    }
  }

  /// Advance the watermark to [t] (monotonic). WRITE-THROUGH (no debounce):
  /// this is the anti-resurrection anchor — losing it to a hard kill would
  /// bring the bug straight back. Capped at wall-clock NOW so a future-dated
  /// event (author clock skew) can never push the watermark into the future
  /// and silently mark legitimate later notifications read.
  void advance(int t) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final capped = t > now ? now : t;
    if (capped <= state) return;
    state = capped;
    final encoded = '$capped';
    final db = _db;
    if (db != null) {
      db.writeConfig(_key, encoded);
      return;
    }
    try {
      _dbFuture.then((d) {
        _db ??= d;
        return d.writeConfig(_key, encoded);
      }, onError: (_) {});
    } catch (_) {
      // Container already gone — nothing to persist to.
    }
  }
}

/// When the LAST unread item has just been read, collapse the entire current
/// list into the watermark: future evictions from the capped read set (or
/// item-key churn across launches) can never resurrect this history.
///
/// MUST be called from the widget layer (a [WidgetRef] is outside the
/// provider graph): the unread count watches the watermark, so reading it
/// from INSIDE the watermark notifier trips Riverpod's circular-dependency
/// assert.
void compactNotificationWatermarkIfFullyRead(WidgetRef ref, String myPubkey) {
  if (ref.read(unreadNotificationCountProvider(myPubkey)) != 0) return;
  final items =
      ref.read(notificationsProvider(myPubkey)).value ??
      const <NotificationItem>[];
  if (items.isEmpty) return;
  var maxTime = items.first.time;
  for (final i in items) {
    if (i.time > maxTime) maxTime = i.time;
  }
  ref.read(notificationWatermarkProvider(myPubkey).notifier).advance(maxTime);
}

/// Number of currently-unread notifications for [myPubkey]. Watching this
/// (e.g. from the bottom-nav badge in [AppShell]) keeps [notificationsProvider]
/// alive across tabs so the badge updates while the user is elsewhere in the
/// app — the notification subscription is a foreground-live feed per
/// DESIGN §5.1 / §10 (background pauses via the relay pool disconnect).
///
/// autoDispose (like [notificationsProvider]): when the active account
/// changes, AppShell watches the NEW pubkey's count, this instance loses its
/// last listener and the whole per-account chain (including the relay REQs)
/// is disposed — non-active accounts keep no live notification state.
final unreadNotificationCountProvider = Provider.autoDispose
    .family<int, String>((ref, myPubkey) {
      final items =
          ref.watch(notificationsProvider(myPubkey)).value ??
          const <NotificationItem>[];
      final read = ref.watch(notificationReadProvider(myPubkey));
      final watermark = ref.watch(notificationWatermarkProvider(myPubkey));
      var count = 0;
      for (final i in items) {
        if (notificationIsUnread(i, read, watermark)) count++;
      }
      return count;
    });

// --- UI ---

/// Double-tap-on-the-bottom-nav-bell jump requests. A counter: the
/// notifications page ref.listens and treats every increment as one request
/// to scroll to the topmost unread notification. Global (not per-account):
/// only one account is active at a time, and the page re-listens on rebuild.
final notificationJumpProvider =
    NotifierProvider<NotificationJumpNotifier, int>(
      NotificationJumpNotifier.new,
    );

class NotificationJumpNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});
  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  String _tab = 'all';

  /// Drives the double-tap-on-tab "jump to the newest notification" shortcut.
  final ScrollController _controller = ScrollController();

  /// Stable GlobalKeys per notification item id, so the double-tap-bell jump
  /// can locate the topmost unread tile's BuildContext for
  /// [Scrollable.ensureVisible]. Item ids are unique within the list and only
  /// ONE ListView is ever mounted (全部/提及 swap the filtered data inside the
  /// same ListView), so a key is never attached twice.
  final Map<String, GlobalKey> _tileKeys = {};

  /// The item currently flashing after a jump (cleared by [_highlightOff]).
  String? _highlightId;
  Timer? _highlightOff;

  /// Retry-chain state for pending jumps (list still loading / target not yet
  /// laid out). A newer request bumps [_jumpGen] and supersedes the older
  /// chain.
  int _jumpGen = 0;
  int _jumpRetries = 0;

  GlobalKey _keyFor(String id) => _tileKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void dispose() {
    _highlightOff?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Double-tap on the 全部/提及 tab row: jump back to the newest
  /// notification (same shortcut as the home feed's 全球/关注 row).
  void _scrollToTop() {
    if (!_controller.hasClients) return;
    final px = _controller.offset;
    if (px <= 0) return;
    final ms = (px / 60).clamp(250, 700).toInt();
    _controller.animateTo(
      0,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  /// Double-tap on the bottom-nav bell: scroll to the TOPMOST UNREAD
  /// notification (and flash it) so the user sees which one is unread. Falls
  /// back to [_scrollToTop] when nothing is unread.
  void _requestJump() {
    _jumpGen++;
    _jumpRetries = 0;
    _tryJump(_jumpGen);
  }

  void _tryJump(int gen) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || gen != _jumpGen) return;
      final myPubkey = ref.read(identityProvider).value?.pubkeyHex;
      if (myPubkey == null) return;
      final all = ref.read(notificationsProvider(myPubkey)).value;
      if (all == null) {
        // Still loading — retry for up to ~5s of frames.
        if (_jumpRetries++ < 300) _tryJump(gen);
        return;
      }
      _jumpToFirstUnread(myPubkey, all, gen);
    });
  }

  List<NotificationItem> _itemsForTab(String tab, List<NotificationItem> all) =>
      tab == 'mentions'
      ? all
            .where(
              (i) =>
                  i.type == NotificationType.mention ||
                  i.type == NotificationType.reply,
            )
            .toList()
      : all;

  int? _firstUnreadIndex(String myPubkey, List<NotificationItem> items) {
    final read = ref.read(notificationReadProvider(myPubkey));
    final watermark = ref.read(notificationWatermarkProvider(myPubkey));
    for (var i = 0; i < items.length; i++) {
      if (notificationIsUnread(items[i], read, watermark)) return i;
    }
    return null;
  }

  void _jumpToFirstUnread(
    String myPubkey,
    List<NotificationItem> all,
    int gen,
  ) {
    var items = _itemsForTab(_tab, all);
    var index = _firstUnreadIndex(myPubkey, items);
    if (index == null) {
      // Nothing unread on this tab — try the other one before giving up.
      final other = _tab == 'all' ? 'mentions' : 'all';
      final otherItems = _itemsForTab(other, all);
      if (_firstUnreadIndex(myPubkey, otherItems) != null) {
        setState(() => _tab = other);
        _tryJump(gen);
        return;
      }
      _scrollToTop(); // nothing unread anywhere — classic back-to-top
      return;
    }
    final target = items[index];
    _flash(target.id);
    _scrollToItem(index, target.id, items.length, gen, 0);
  }

  void _scrollToItem(
    int index,
    String id,
    int itemCount,
    int gen,
    int attempt,
  ) {
    if (!mounted || gen != _jumpGen) return;
    if (!_controller.hasClients) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToItem(index, id, itemCount, gen, attempt + 1),
        );
      }
      return;
    }
    final ctx = _tileKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.15,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    // Target tile not built yet (far down the list): estimate the offset
    // proportionally, jump there so the tile builds, then re-locate.
    if (attempt == 0 && _controller.position.maxScrollExtent > 0) {
      final est =
          _controller.position.maxScrollExtent *
          index /
          math.max(1, itemCount - 1);
      _controller.jumpTo(est.clamp(0.0, _controller.position.maxScrollExtent));
    }
    if (attempt < 5) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToItem(index, id, itemCount, gen, attempt + 1),
      );
    }
  }

  void _flash(String id) {
    setState(() => _highlightId = id);
    _highlightOff?.cancel();
    _highlightOff = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider).value;
    final myPubkey = identity?.pubkeyHex;
    // Double-tap-bell jump requests arrive via this counter (AppShell
    // increments it). Listen in build so the subscription tracks rebuilds.
    ref.listen(notificationJumpProvider, (prev, next) {
      if (prev != next) _requestJump();
    });
    if (myPubkey == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('通知')),
        body: const Center(child: Text('未登录')),
      );
    }
    final async = ref.watch(notificationsProvider(myPubkey));
    final unreadCount = ref.watch(unreadNotificationCountProvider(myPubkey));
    // Lifted out of `.when` so the AppBar action can mark-all-read without
    // rebuilding the body. `filtered` follows the current _tab.
    final allItems = async.value ?? const <NotificationItem>[];
    final filtered = _itemsForTab(_tab, allItems);
    return ImmersiveScaffold(
      topBar: AppBar(
        title: const Text('通知'),
        actions: [
          // Mark ALL notifications read (both tabs). First login can surface a
          // large backlog of historical unread (DESIGN §5.2) — tapping
          // one-by-one isn't practical, so this clears everything in one
          // shot. Also advances the read watermark over the whole list so
          // read-set eviction / item-key churn can never resurrect these
          // items (the "已读通知反复复活" fix). Hidden when nothing unread.
          if (unreadCount > 0)
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: '全部标记已读',
              onPressed: () {
                final read = ref.read(notificationReadProvider(myPubkey));
                final watermark = ref.read(
                  notificationWatermarkProvider(myPubkey),
                );
                final ids = allItems
                    .where((i) => notificationIsUnread(i, read, watermark))
                    .map((i) => i.id)
                    .toList();
                if (ids.isNotEmpty) {
                  ref
                      .read(notificationReadProvider(myPubkey).notifier)
                      .markRead(ids);
                }
                var maxTime = 0;
                for (final i in allItems) {
                  if (i.time > maxTime) maxTime = i.time;
                }
                if (maxTime > 0) {
                  ref
                      .read(notificationWatermarkProvider(myPubkey).notifier)
                      .advance(maxTime);
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings/notifications'),
          ),
        ],
      ),
      // The 全部/提及 tab row is part of the top chrome — collapse it WITH
      // the AppBar on scroll-down (user: "提及和全部不会隐藏"). _TabButton
      // fills the fixed 52 height so the collapse math is exact.
      belowBarHeight: 52,
      belowBar: DoubleTapShortcut(
        onDoubleTap: _scrollToTop,
        child: SizedBox(
          height: 52,
          child: Material(
            color: CostrColors.of(context).bg,
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
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ImmersiveScrollDetector(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
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
                    controller: _controller,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => _NotificationTile(
                      key: _keyFor(filtered[i].id),
                      item: filtered[i],
                      myPubkey: myPubkey,
                      highlight: filtered[i].id == _highlightId,
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
          height: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? CostrColors.of(context).brand
                    : Colors.transparent,
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
              color: selected
                  ? CostrColors.of(context).text
                  : CostrColors.of(context).text3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview line for a reaction/repost notification: the content of the post
/// that was interacted with. The incoming event itself is just an emoji
/// (kind-7) or a repost envelope (kind-6) — the useful context is the liked/
/// reposted post's own text ("在通知中心就能看到点赞对应的帖子内容", like the
/// reply preview). Resolved via [eventByIdProvider]'s 3-tier lookup; the
/// user's own posts are SQLite-cached (TTL-exempt) so this is instant. Shown
/// only while [item]'s own [NotificationItem.preview] is null (reposts embed
/// the reposted text directly, so they usually don't need this).
class _InteractPreview extends ConsumerWidget {
  const _InteractPreview({required this.targetId});
  final String targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ev = ref.watch(eventByIdProvider(targetId)).value;
    final content = flattenPreview(ev?.content ?? '');
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        linkifyMentions(
          content,
          ref,
          baseStyle: TextStyle(
            fontSize: 14,
            color: CostrColors.of(context).text2,
          ),
          mentionStyle: TextStyle(
            fontSize: 14,
            color: CostrColors.of(context).brand,
            fontWeight: FontWeight.w600,
          ),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _NotificationTile extends ConsumerWidget {
  const _NotificationTile({
    super.key,
    required this.item,
    required this.myPubkey,
    this.highlight = false,
  });
  final NotificationItem item;
  final String myPubkey;

  /// Flash-tint after the double-tap-bell jump located this tile as the
  /// topmost unread one ("方便知道是哪条通知").
  final bool highlight;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final icon = _iconForType(item.type);
    final iconColor = _colorForType(item.type, CostrColors.of(context));
    // Unread is derived from the persisted read-set + watermark (not the
    // vestigial item.unread flag, which is always true at creation).
    // Per-item: stays unread until the user taps it (stable styling — no
    // whole-page clear); the watermark additionally keeps fully-read history
    // read across launches (see notificationWatermarkProvider).
    final unread = notificationIsUnread(
      item,
      ref.watch(notificationReadProvider(myPubkey)),
      ref.watch(notificationWatermarkProvider(myPubkey)),
    );
    // Bold style for the "who" part of the title; name spans carry it
    // explicitly (custom-emoji names render inline images — see
    // [displayNameSpans]).
    const headStyle = TextStyle(fontWeight: FontWeight.w700);
    final verb = _verbForType(item.type);

    return InkWell(
      onTap: () {
        // Mark this item read (per-item; stable unread styling until tap).
        ref.read(notificationReadProvider(myPubkey).notifier).markRead([
          item.id,
        ]);
        // Reading the LAST unread item collapses the whole list into the
        // watermark — evictions from the capped read set can then never
        // resurrect this history (the "已读通知反复复活" fix).
        compactNotificationWatermarkIfFullyRead(ref, myPubkey);
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
        // Navigation target per type — see [notificationNavTarget].
        final target = notificationNavTarget(item);
        if (target != null) {
          pushPostDetail(context, target);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // Subtle background tint on unread items (X-style); read items stay
        // plain. Combined with the dot below for a stable read/unread split.
        // [highlight] (just jumped to via the bottom-nav bell double-tap)
        // flashes a brand tint over either.
        decoration: BoxDecoration(
          color: highlight
              ? CostrColors.of(context).brand.withValues(alpha: 0.12)
              : unread
              ? CostrColors.of(context).bg2
              : null,
          border: Border(
            bottom: BorderSide(color: CostrColors.of(context).border),
          ),
        ),
        // Feed-style layout (user: "参考帖子信息流的头像和帖子内容排版"):
        // row 1 = icon + avatar stack + head line (avatar sits level with
        // the names, like the feed), then preview + time flow BELOW at the
        // avatar's left edge — the old layout kept preview/time beside the
        // avatar, leaving a tall empty strip under it on multi-line rows
        // ("头像下面还有很多空间").
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
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
                          decoration: BoxDecoration(
                            color: CostrColors.of(context).brand,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Avatars (up to 3, overlapping 50% like X's stacks). Cumulative
                // -16 offset per index lays them out at x 0/16/32 (visual width
                // 64); Padding disallows negative values, so we translate
                // instead. Fixed 64-wide strip so the text column starts at
                // the SAME x whether the row shows 1, 2 or 3 avatars —
                // previously a 3-avatar row's layout width pushed its text ~2
                // avatars right of single rows (通知排版错位 screenshot).
                // Transform.translate doesn't affect layout, so we pin the
                // strip width here.
                SizedBox(
                  width: 64,
                  child: Row(
                    children: [
                      for (var i = 0; i < item.pubkeys.length && i < 3; i++)
                        Transform.translate(
                          offset: Offset(-16.0 * i, 0),
                          child: Avatar(pubkey: item.pubkeys[i], radius: 16),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Head line: who + verb (+ reaction emoji inline).
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium,
                      children: [
                        if (item.extraCount > 0)
                          TextSpan(
                            text:
                                '${item.pubkeys.length} 人和另外 ${item.extraCount} 人',
                            style: headStyle,
                          )
                        else
                          for (final (i, pk)
                              in item.pubkeys.take(3).indexed) ...[
                            if (i > 0) TextSpan(text: '、', style: headStyle),
                            ...displayNameSpans(
                              pubkey: pk,
                              meta: ref.watch(metadataProvider(pk)).value,
                              style: headStyle,
                            ),
                          ],
                        TextSpan(
                          text: ' $verb',
                          style: TextStyle(
                            color: CostrColors.of(context).text2,
                          ),
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
                ),
              ],
            ),
            // Preview + time below, at the avatar's left edge (icon column
            // 40 + gap 12) so the space under the avatar carries content.
            if (item.preview != null)
              Padding(
                padding: const EdgeInsets.only(left: 52, top: 4),
                child: Text.rich(
                  linkifyMentions(
                    item.preview!,
                    ref,
                    baseStyle: TextStyle(
                      fontSize: 14,
                      color: CostrColors.of(context).text2,
                    ),
                    mentionStyle: TextStyle(
                      fontSize: 14,
                      color: CostrColors.of(context).brand,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else if ((item.type == NotificationType.reaction ||
                    item.type == NotificationType.repost) &&
                item.targetEventId != null)
              // No inline preview (a reaction's own content is just the
              // emoji) — show the liked/reposted post's content instead.
              Padding(
                padding: const EdgeInsets.only(left: 52, top: 4),
                child: _InteractPreview(targetId: item.targetEventId!),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 52, top: 4),
              child: Text(
                _relativeTime(item.time),
                style: TextStyle(
                  fontSize: 12,
                  color: CostrColors.of(context).text3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

Color _colorForType(NotificationType t, CostrPalette c) {
  switch (t) {
    case NotificationType.reaction:
      return c.red;
    case NotificationType.repost:
      return c.green;
    case NotificationType.follow:
      return c.blue;
    default:
      return c.text2;
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
