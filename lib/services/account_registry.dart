/// Multi-account registry model: the accounts logged in on this device +
/// which one is active. Pure data + JSON codec (no storage/IO) so it can be
/// unit-tested directly; persistence lives in [SecureStorageService]
/// (`costr.accounts.v1` blob) and the reactive layer in `providers.dart`
/// (`accountsProvider`).
///
/// Multi-account model (Amethyst-style): many accounts stored, ONE active.
/// Only the active account drives connections, feeds and notifications —
/// switching tears down the old account's subscriptions via the reactive
/// identity chain, it does not add parallel per-account connections.
library;

import '../nostr/identity.dart';

/// One stored account: the key pair in its two representations.
class AccountEntry {
  const AccountEntry({
    required this.pubkeyHex,
    required this.nsec,
    required this.npub,
  });

  factory AccountEntry.fromIdentity(Identity identity) => AccountEntry(
    pubkeyHex: identity.pubkeyHex,
    nsec: identity.nsec,
    npub: identity.npub,
  );

  final String pubkeyHex;
  final String nsec;
  final String npub;

  Map<String, dynamic> toJson() => {
    'pubkey': pubkeyHex,
    'nsec': nsec,
    'npub': npub,
  };

  static AccountEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final pubkey = raw['pubkey'];
    final nsec = raw['nsec'];
    if (pubkey is! String || nsec is! String) return null;
    final npub = raw['npub'];
    return AccountEntry(
      pubkeyHex: pubkey,
      nsec: nsec,
      npub: npub is String ? npub : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountEntry &&
          other.pubkeyHex == pubkeyHex &&
          other.nsec == nsec &&
          other.npub == npub);

  @override
  int get hashCode => Object.hash(pubkeyHex, nsec, npub);

  @override
  String toString() => 'AccountEntry(npub: $npub, nsec: <redacted>)';
}

/// The device's account set: stored accounts + the active one's pubkey.
/// Invariant: [activePubkey] (when non-null) is always the pubkey of one of
/// [accounts] — enforced by [upsert]/[remove]/[withActive].
class AccountSet {
  const AccountSet({this.accounts = const [], this.activePubkey});

  final List<AccountEntry> accounts;
  final String? activePubkey;

  bool get isEmpty => accounts.isEmpty;
  bool get isNotEmpty => accounts.isNotEmpty;

  /// The active account entry, or null when logged out.
  AccountEntry? get active {
    final pk = activePubkey;
    if (pk == null) return null;
    for (final a in accounts) {
      if (a.pubkeyHex == pk) return a;
    }
    return null;
  }

  bool contains(String pubkeyHex) =>
      accounts.any((a) => a.pubkeyHex == pubkeyHex);

  /// Add or replace an account; optionally make it the active one. Adding a
  /// pubkey that already exists replaces its entry (re-login with the same
  /// key) and does not duplicate it.
  AccountSet upsert(AccountEntry entry, {required bool activate}) {
    final next = accounts.where((a) => a.pubkeyHex != entry.pubkeyHex).toList()
      ..add(entry);
    return AccountSet(
      accounts: next,
      activePubkey: activate ? entry.pubkeyHex : activePubkey,
    );
  }

  /// Switch the active account. [pubkeyHex] must already be stored —
  /// switching to an unknown pubkey is a no-op (returns `this`).
  AccountSet withActive(String pubkeyHex) {
    if (!contains(pubkeyHex)) return this;
    if (activePubkey == pubkeyHex) return this;
    return AccountSet(accounts: accounts, activePubkey: pubkeyHex);
  }

  /// Remove an account. When the ACTIVE account is removed, the first
  /// remaining account becomes active (or none — logged out).
  AccountSet remove(String pubkeyHex) {
    if (!contains(pubkeyHex)) return this;
    final next = accounts.where((a) => a.pubkeyHex != pubkeyHex).toList();
    final String? nextActive;
    if (activePubkey != pubkeyHex) {
      nextActive = activePubkey;
    } else {
      nextActive = next.isEmpty ? null : next.first.pubkeyHex;
    }
    return AccountSet(accounts: next, activePubkey: nextActive);
  }

  Map<String, dynamic> toJson() => {
    'accounts': accounts.map((a) => a.toJson()).toList(),
    if (activePubkey != null) 'active': activePubkey,
  };

  /// Parse a stored blob. Malformed input yields an empty set (never throws —
  /// a corrupted blob must not wedge startup; the user can log in again).
  static AccountSet tryFromJson(Object? raw) {
    if (raw is! Map) return const AccountSet();
    final list = raw['accounts'];
    if (list is! List) return const AccountSet();
    final accounts = <AccountEntry>[];
    for (final e in list) {
      final entry = AccountEntry.tryFromJson(e);
      if (entry != null &&
          !accounts.any((a) => a.pubkeyHex == entry.pubkeyHex)) {
        accounts.add(entry);
      }
    }
    final active = raw['active'];
    final activePubkey =
        active is String && accounts.any((a) => a.pubkeyHex == active)
        ? active
        : (accounts.isEmpty ? null : accounts.first.pubkeyHex);
    return AccountSet(accounts: accounts, activePubkey: activePubkey);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AccountSet || other.activePubkey != activePubkey) {
      return false;
    }
    if (other.accounts.length != accounts.length) return false;
    for (var i = 0; i < accounts.length; i++) {
      if (other.accounts[i] != accounts[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(accounts), activePubkey);

  @override
  String toString() =>
      'AccountSet(${accounts.length} account(s), '
      'active: ${activePubkey ?? '<none>'})';
}
