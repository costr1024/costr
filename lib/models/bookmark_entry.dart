import 'event.dart';

/// A bookmarked note id tagged with its origin (public plaintext `e` tag vs
/// private NIP-44-encrypted entry) in a NIP-51 kind-10003 User Bookmarks
/// event. Used so the 收藏 tab can render public and private bookmarks in
/// separate sections (and badge each row), instead of merging them into one
/// indistinguishable flat list.
class BookmarkEntry {
  const BookmarkEntry({required this.id, required this.public});
  final String id;
  final bool public;
}

/// A named bookmark group shown as a chip/section in the 收藏 tab (follows
/// page parity). The two built-in groups (公开书签 / 私人书签) aggregate every
/// entry across kind-10003 + kind-30003; custom groups back onto one
/// kind-30003 labeled list ([source], null for built-ins — kept so the next
/// iteration can hang rename/delete management off it).
class BookmarkGroup {
  const BookmarkGroup(this.name, this.entries, {this.source});

  /// Display name: 公开书签 / 私人书签 / the kind-30003 list's display name.
  final String name;
  final List<BookmarkEntry> entries;

  /// The backing kind-30003 event (newest revision), null for built-ins.
  final Event? source;
}
