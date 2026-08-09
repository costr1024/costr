/// Blossom media upload (BUD-02 + BUD-11).
///
/// Upload flow:
/// 1. SHA-256 the file bytes.
/// 2. Sign a kind-24242 auth event: tags ["t","upload"], ["x",sha256],
///    ["expiration",ts], ["size",bytes], ["m",mimetype]; content = human note.
/// 3. PUT /upload to a Blossom server with raw bytes + header
///    `Authorization: Nostr <base64url-no-padding of JSON event>`.
/// 4. Response JSON: {url, sha256, size, type, uploaded}.
///
/// Tries servers in order; on failure (network error / non-2xx) retries the next.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../models/event.dart';
import '../nostr/identity.dart';

/// Default Blossom servers, tried in order (= upload retry priority = display
/// order on the 服务器节点 page). ditto.pub stays primary; libernet next;
/// nostr.download + jumble.social are error-fallback retries.
const List<String> blossomServers = <String>[
  'https://blossom.ditto.pub/',
  'https://media.libernet.app/',
  'https://nostr.download/',
  'https://blossom.jumble.social/',
];

class BlossomResult {
  const BlossomResult({required this.url, required this.sha256});
  final String url;
  final String sha256;
  @override
  String toString() => 'BlossomResult(url: $url, sha256: $sha256)';
}

/// MIME types for the file types we support (by extension). Accepts a bare
/// extension (".jpg"/"jpg") or a full filename ("photo.jpg"). Anything unknown
/// falls back to application/octet-stream; the server rejects if unsupported.
String mimeForExt(String? ext) {
  if (ext == null || ext.isEmpty) return 'application/octet-stream';
  var e = ext.toLowerCase();
  // If it looks like a filename, extract the last extension segment.
  final slash = e.lastIndexOf('/');
  if (slash >= 0) e = e.substring(slash + 1);
  final dot = e.lastIndexOf('.');
  if (dot >= 0) e = e.substring(dot + 1);
  const map = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'm4v': 'video/x-m4v',
    'mkv': 'video/x-matroska',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
  };
  return map[e] ?? 'application/octet-stream';
}

bool isImageMime(String m) => m.startsWith('image/');
bool isVideoMime(String m) => m.startsWith('video/');

/// Measure real HTTP round-trip latency to a Blossom server: a HEAD request
/// to the server root, timed from send to first response. Any HTTP response
/// (even non-2xx, e.g. 405 for HEAD) means the server is reachable → returns
/// elapsed ms. A network error / timeout → returns null (offline). NOT an
/// ICMP ping; this is the real upload-path HTTP round-trip the app uses.
final http.Client _blossomRttClient = http.Client();

/// Shared client for real uploads (connection reuse). Tests inject their own
/// via [blossomUpload]'s `client` parameter.
final http.Client _uploadClient = http.Client();

Future<int?> measureBlossomRtt(
  String serverUrl, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  try {
    await _blossomRttClient.head(Uri.parse(serverUrl)).timeout(timeout);
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

/// Upload [bytes] as [mimetype]. Tries [servers] (the user's configured
/// Blossom list, falling back to [blossomServers]) in order, retrying on
/// failure. Returns the public URL (with a file extension per BUD-01) or null
/// if all servers fail.
///
/// [timeout] caps EACH per-server attempt (server discovery's test-upload
/// probe passes a short one instead of the 90s real-upload cap). [client] is
/// injectable for tests (MockClient); production shares [_uploadClient].
Future<BlossomResult?> blossomUpload(
  Identity identity,
  List<int> bytes, {
  required String mimetype,
  String note = 'costr upload',
  List<String>? servers,
  Duration timeout = const Duration(seconds: 90),
  http.Client? client,
}) async {
  final sha = crypto.sha256.convert(bytes).toString();
  final auth = _buildAuthEvent(identity, sha, bytes.length, mimetype, note);
  // BUD-11 says base64url without padding, but libernet (Python b64) rejects
  // no-pad with "Incorrect padding"; ditto accepts both. Padded works for all.
  final authHeader =
      'Nostr ${base64Url.encode(utf8.encode(jsonEncode(auth.toWireObject())))}';

  final targets = (servers == null || servers.isEmpty)
      ? blossomServers
      : servers;
  final uploader = client ?? _uploadClient;
  for (final server in targets) {
    final url = '${server.replaceAll(RegExp(r'/+$'), '')}/upload';
    try {
      final res = await uploader
          .put(
            Uri.parse(url),
            headers: <String, String>{
              'Authorization': authHeader,
              'Content-Type': mimetype,
              'Content-Length': '${bytes.length}',
              'X-SHA-256': sha,
            },
            body: bytes,
          )
          .timeout(timeout);
      if (res.statusCode == 200 || res.statusCode == 201) {
        final body = jsonDecode(res.body);
        if (body is Map && body['url'] is String) {
          return BlossomResult(
            url: body['url'] as String,
            sha256: (body['sha256'] as String?) ?? sha,
          );
        }
      }
      // Non-success: try the next server.
    } catch (_) {
      // Network / decode error: try the next server.
    }
  }
  return null;
}

Event _buildAuthEvent(
  Identity id,
  String sha256Hex,
  int size,
  String mimetype,
  String note,
) {
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600; // +1h
  return id.signEvent(
    kind: 24242,
    content: note,
    tags: <List<String>>[
      <String>['t', 'upload'],
      <String>['x', sha256Hex],
      <String>['expiration', '$exp'],
      <String>['size', '$size'],
      <String>['m', mimetype],
    ],
  );
}
