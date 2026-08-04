/// OS keystore wrapper for the nsec, with a file fallback.
///
/// Strategy: prefer flutter_secure_storage (libsecret on Linux, Keystore on
/// Android, Keychain on iOS/macOS, DPAPI on Windows). When it fails — most
/// commonly `KeyringLocked` on a Linux session whose login keyring isn't
/// auto-unlocked (non-PAM/auto-login/SSH-forwarded desktop) — fall back to a
/// 0600-permission JSON file under the user's config dir.
///
/// The file fallback is roughly as secure as an empty-password GNOME keyring
/// (which also reduces to plaintext-on-disk); it is appropriate for a
/// single-user host where OS keystore auto-unlock is not set up.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Testable file-backed secret store. Stores key→value in a single 0600 JSON
/// file under [dir] (which is created 0700).
class FileSecretStore {
  FileSecretStore(this.dir);

  final String dir;

  File get _file => File('$dir/secret.json');

  Future<void> _ensureDir() async {
    final d = Directory(dir);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    await _chmod(Directory(dir), '0700');
  }

  Future<Map<String, String>> _readMap() async {
    final f = _file;
    if (!await f.exists()) return <String, String>{};
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return <String, String>{};
      final m = jsonDecode(raw);
      if (m is! Map) return <String, String>{};
      return {for (final e in m.entries) e.key.toString(): e.value.toString()};
    } catch (e) {
      debugPrint('[costr] file secret store read failed: $e');
      return <String, String>{};
    }
  }

  Future<void> _writeMap(Map<String, String> m) async {
    await _ensureDir();
    final f = _file;
    await f.writeAsString(jsonEncode(m), flush: true);
    await _chmod(f, '0600');
  }

  Future<String?> read(String key) async {
    final m = await _readMap();
    return m[key];
  }

  Future<void> write(String key, String value) async {
    final m = await _readMap();
    m[key] = value;
    await _writeMap(m);
  }

  Future<void> delete(String key) async {
    final m = await _readMap();
    if (m.remove(key) != null) {
      if (m.isEmpty) {
        if (await _file.exists()) await _file.delete();
      } else {
        await _writeMap(m);
      }
    }
  }

  Future<void> deleteAll() async {
    if (await _file.exists()) await _file.delete();
  }

  /// Best-effort chmod; no-op where chmod isn't available.
  Future<void> _chmod(FileSystemEntity entity, String mode) async {
    final path = entity.path;
    try {
      final r = await Process.run('chmod', [mode, path]);
      if (r.exitCode != 0) {
        debugPrint('[costr] chmod $mode $path failed: ${r.stderr}');
      }
    } catch (e) {
      // chmod unavailable (e.g. Windows) — best effort, ignore.
    }
  }
}

class SecureStorageService {
  SecureStorageService(this._secure, {String? fileDir})
    : _file = FileSecretStore(fileDir ?? _defaultFileDir);

  final FlutterSecureStorage _secure;
  final FileSecretStore _file;
  bool _secureOk =
      true; // false once libsecret has failed → skip further tries.

  static const String _nsecKey = 'costr.identity.nsec';

  static String get _defaultFileDir {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/.config/costr';
  }

  Future<String?> readNsec() async {
    if (_secureOk) {
      try {
        // Bounded: on some Android devices the Keystore read HANGS after an
        // overlay upgrade (entry carried over, keystore in a bad state) —
        // identity is the first thing bootstrap awaits, so an unbounded
        // read here freezes the app on the splash screen. Time out and fall
        // back to the file store instead of hanging forever.
        final v = await _secure
            .read(key: _nsecKey)
            .timeout(const Duration(seconds: 8));
        return v;
      } on TimeoutException {
        debugPrint(
          '[costr] secureStorage.read timed out (keystore hung), '
          'using file fallback',
        );
        _secureOk = false;
      } catch (e, s) {
        debugPrint(
          '[costr] secureStorage.read failed, using file fallback: $e',
        );
        if (kDebugMode) debugPrint('$s');
        _secureOk = false;
      }
    }
    return _file.read(_nsecKey);
  }

  Future<void> writeNsec(String nsec) async {
    if (_secureOk) {
      try {
        await _secure.write(key: _nsecKey, value: nsec);
        // libsecret worked; remove any stale file copy.
        await _file.delete(_nsecKey);
        return;
      } catch (e, s) {
        debugPrint(
          '[costr] secureStorage.write failed, using file fallback: $e',
        );
        if (kDebugMode) debugPrint('$s');
        _secureOk = false;
      }
    }
    await _file.write(_nsecKey, nsec);
  }

  Future<void> deleteNsec() async {
    if (_secureOk) {
      try {
        await _secure.delete(key: _nsecKey);
      } catch (e) {
        debugPrint('[costr] secureStorage.delete failed: $e');
        _secureOk = false;
      }
    }
    await _file.delete(_nsecKey);
  }

  Future<void> dispose() async {}

  // --- Generic key-value storage (for local settings like NSFW) ---

  Future<String?> readValue(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeValue(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } catch (_) {}
  }

  Future<void> deleteValue(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
  }
}
