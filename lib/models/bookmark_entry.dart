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
