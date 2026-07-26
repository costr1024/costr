/// OS keystore wrapper for the nsec.
///
/// Linux desktop backs onto libsecret (GNOME Keyring / KDE Wallet). When no
/// keyring daemon is available (headless servers, some WSL2), reads/writes
/// throw — we catch and degrade to "logged out on restart" rather than crash.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  const SecureStorageService(this._storage);
  final FlutterSecureStorage _storage;

  static const String _nsecKey = 'costr.identity.nsec';

  Future<String?> readNsec() async {
    try {
      return await _storage.read(key: _nsecKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeNsec(String nsec) async {
    try {
      await _storage.write(key: _nsecKey, value: nsec);
    } catch (_) {
      // Best-effort persistence; a failure just means no auto-login.
    }
  }

  Future<void> deleteNsec() async {
    try {
      await _storage.delete(key: _nsecKey);
    } catch (_) {
      // Ignore — logout proceeds regardless.
    }
  }

  /// No resources to release; provided for provider onDispose symmetry.
  Future<void> dispose() async {}
}
