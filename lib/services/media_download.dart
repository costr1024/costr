/// Download remote media and save it to the user's device.
///
/// Two paths, by platform + media kind:
/// - **Mobile (Android/iOS) + image/video** → system gallery via `gal`
///   (Android MediaStore / iOS Photos). The user sees the media appear in
///   their photo gallery, no save-as prompt.
/// - **Desktop, and any generic file (all platforms)** → save-as dialog via
///   `file_picker` (SAF `createDocument` on Android, `UIDocumentPicker` on
///   iOS, native save dialog on desktop). The user picks the destination.
///
/// Download is streamed to a temp file (in `getTemporaryDirectory()`) so
/// large videos never sit fully in memory; the temp file is deleted after
/// saving. `MediaKind.file` covers pdf/zip/txt/etc.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum MediaKind { image, video, file }

class MediaDownload {
  const MediaDownload._();

  /// Save [url] to the device. Returns a user-facing result message, or
  /// `null` if the user cancelled the save-as dialog (desktop/file path).
  static Future<String?> save({
    required String url,
    required MediaKind kind,
    String? filename,
  }) async {
    final name = _safeFileName(
      (filename != null && filename.isNotEmpty) ? filename : _defaultName(url, kind),
    );
    final tempPath = await _downloadToTemp(url, name);
    try {
      final toGallery = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS) &&
          kind != MediaKind.file;
      if (toGallery) {
        return await _saveToGallery(tempPath, kind);
      }
      return await _saveAs(tempPath, name);
    } finally {
      final f = File(tempPath);
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // --- mobile gallery -------------------------------------------------------

  static Future<String> _saveToGallery(String tempPath, MediaKind kind) async {
    final hasAccess = await Gal.hasAccess();
    if (!hasAccess) {
      final granted = await Gal.requestAccess();
      if (!granted) return '相册权限被拒绝';
    }
    try {
      if (kind == MediaKind.image) {
        await Gal.putImage(tempPath);
      } else {
        await Gal.putVideo(tempPath);
      }
      return kind == MediaKind.image ? '图片已保存到相册' : '视频已保存到相册';
    } on GalException catch (e) {
      return '保存失败：${e.type.message}';
    } catch (e) {
      return '保存失败：$e';
    }
  }

  // --- desktop / generic file: save-as dialog -----------------------------

  static Future<String?> _saveAs(String tempPath, String name) async {
    try {
      // file_picker 10's saveFile takes bytes (no filePath option). Generic
      // files are small; desktop has RAM for larger media. Mobile image/
      // video goes through gal instead, so this path is only hit for generic
      // files on mobile and any media on desktop.
      final bytes = await File(tempPath).readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        fileName: name,
        bytes: bytes,
      );
      if (savedPath == null) return null; // user cancelled
      return '已保存到 $savedPath';
    } catch (e) {
      return '保存失败：$e';
    }
  }

  // --- helpers --------------------------------------------------------------

  static String _defaultName(String url, MediaKind kind) {
    final path = Uri.tryParse(url)?.path ?? url;
    final slash = path.lastIndexOf('/');
    final base = slash >= 0 ? path.substring(slash + 1) : path;
    final decoded = Uri.decodeComponent(base);
    if (decoded.isNotEmpty && decoded.contains('.')) return decoded;
    final ext = switch (kind) {
      MediaKind.image => 'jpg',
      MediaKind.video => 'mp4',
      MediaKind.file => 'bin',
    };
    return 'costr_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  /// Strip path separators / non-filename chars so the temp path can't break
  /// and the save-as dialog gets a clean suggested name.
  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[/\\]'), '_');
    return cleaned.isEmpty ? 'costr_media' : cleaned;
  }

  static Future<String> _downloadToTemp(String url, String name) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/costr_$name';
    final sink = File(path).openWrite();
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      // Stream straight to disk — large videos never fully load in memory.
      await resp.stream.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
      client.close();
    }
    return path;
  }
}
