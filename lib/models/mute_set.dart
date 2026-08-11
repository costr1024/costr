/// The logged-in user's muted set, parsed from a NIP-51 kind-10000 mute list.
///
/// Amethyst stores mutes as a single kind-10000 event: public mutes are plain
/// tags (`p` user, `word` word, `t` hashtag, `e` event) and private mutes are
/// the same tag shape NIP-44-encrypted in `.content`. This model is the
/// flattened union of both (private entries only decryptable by the owner).
/// See https://github.com/nostr-protocol/nips/blob/master/51.md
library;

import 'event.dart';

/// An immutable muted-set. Empty sets are cheap to share.
class MuteSet {
  const MuteSet({
    this.pubkeys = const <String>{},
    this.words = const <String>{},
    this.hashtags = const <String>{},
    this.eventIds = const <String>{},
  });

  /// Muted user pubkeys (`["p", hex]`) — hide all posts from these authors.
  final Set<String> pubkeys;

  /// Muted words (`["word", str]`) — hide posts whose content contains the
  /// word (case-insensitive substring).
  final Set<String> words;

  /// Muted hashtags (`["t", str]`) — hide posts carrying this hashtag.
  final Set<String> hashtags;

  /// Muted specific event ids (`["e", hex]`) — hide these individual posts.
  final Set<String> eventIds;

  bool get isEmpty =>
      pubkeys.isEmpty && words.isEmpty && hashtags.isEmpty && eventIds.isEmpty;

  /// True if [pubkey] is muted.
  bool isMutedPubkey(String pubkey) => pubkeys.contains(pubkey);

  /// True if [content] contains any muted word (case-insensitive). Empty
  /// content is never word-muted.
  bool contentHasMutedWord(String content) {
    if (words.isEmpty || content.isEmpty) return false;
    final lower = content.toLowerCase();
    for (final w in words) {
      if (w.isNotEmpty && lower.contains(w.toLowerCase())) return true;
    }
    return false;
  }

  /// True if any of [hashtags] is muted. Hashtags are compared lowercased.
  bool hasMutedHashtag(Iterable<String> hashtags) {
    if (this.hashtags.isEmpty) return false;
    for (final t in hashtags) {
      if (t.isNotEmpty && this.hashtags.contains(t.toLowerCase())) return true;
    }
    return false;
  }

  bool isMutedEvent(String id) => eventIds.contains(id);

  /// True when [e] must be hidden entirely: muted author, individually muted
  /// event, or — for text notes — a muted word/hashtag in the content. The
  /// single predicate every rendering surface applies (feed filter, reply
  /// context, quote/repost embeds, thread replies, search) so a muted post
  /// cannot leak back in through a secondary surface ("屏蔽了他，关注的人一
  /// 回复/转发就又能看到他的帖子" bug).
  bool hidesEvent(Event e) {
    if (isMutedPubkey(e.pubkey)) return true;
    if (isMutedEvent(e.id)) return true;
    if (e.isTextNote) {
      if (contentHasMutedWord(e.content)) return true;
      if (hasMutedHashtag(e.hashtags)) return true;
    }
    return false;
  }

  /// User-facing hint for a hidden event — names the reason without leaking
  /// any content: a blocked author vs. some other mute rule (word/hashtag/
  /// the event itself). Shown wherever a muted post would surface; the
  /// content itself only appears if the user explicitly opens it.
  String hintFor(Event e) =>
      isMutedPubkey(e.pubkey) ? '该账号已被屏蔽' : '已屏蔽的内容';
}

/// An entry to add/remove from the mute list — a Nostr tag pair.
/// `(['p', pubkey])` / `(['word', str])` / `(['t', hashtag])` / `(['e', id])`.
typedef MuteEntry = List<String>;
