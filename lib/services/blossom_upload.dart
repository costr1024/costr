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
///
/// Also hosts the manual Blossom SPEED TEST (customize sheet's 「测速」):
/// [measureBlossomSpeed] uploads a fresh 10 MiB random file (video/mp4) to ONE
/// server and times it, downloads that file back and times it, then
/// best-effort DELETEs the test file so speed tests don't pile garbage on the
/// server. Results are never persisted — see features/settings/server_list_sheet.dart.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
    'oga': 'audio/ogg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'opus': 'audio/opus',
    'flac': 'audio/flac',
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
  final authHeader = _nostrAuthHeader(auth);

  final targets = (servers == null || servers.isEmpty)
      ? blossomServers
      : servers;
  final uploader = client ?? _uploadClient;
  for (final server in targets) {
    final result = await _putToServer(
      uploader,
      server,
      bytes,
      sha: sha,
      authHeader: authHeader,
      mimetype: mimetype,
      timeout: timeout,
    );
    if (result != null) return result;
    // Non-success: try the next server.
  }
  return null;
}

/// Encodes a signed kind-24242 auth event into the `Authorization` header
/// value. Shared by upload and speed-test delete (both use the padded
/// base64url encoding — see [blossomUpload]).
String _nostrAuthHeader(Event authEvent) =>
    'Nostr ${base64Url.encode(utf8.encode(jsonEncode(authEvent.toWireObject())))}';

/// A single PUT /upload attempt against ONE [server]. Returns the parsed
/// [BlossomResult], or null on any failure (non-2xx, malformed body, network
/// error, timeout) — the caller decides whether to retry another server.
Future<BlossomResult?> _putToServer(
  http.Client uploader,
  String server,
  List<int> bytes, {
  required String sha,
  required String authHeader,
  required String mimetype,
  required Duration timeout,
}) async {
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
  } catch (_) {
    // Network / decode error — the caller decides what's next.
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

// ---------------------------------------------------------------------------
// Speed test (customize sheet 「测速」 — manual, results never persisted)
// ---------------------------------------------------------------------------

/// Size of the speed-test payload: 10 MiB.
const int blossomSpeedTestBytesSize = 10 * 1024 * 1024;

/// Generates the speed-test payload: [size] bytes of pseudo-random data,
/// FRESH on every call. One 32-bit seed comes from [Random.secure], the rest
/// from a fast PRNG seeded with it (filling via 32-bit writes, ~tens of ms
/// for 10 MiB). Freshness matters: if the bytes were the same across runs, a
/// server that dedupes by sha256 could short-circuit the re-upload and the
/// measured "upload speed" would be fictitious.
Uint8List blossomSpeedTestBytes({int size = blossomSpeedTestBytesSize}) {
  final seed = Random.secure().nextInt(1 << 32);
  final rand = Random(seed);
  final out = Uint8List(size);
  final data = out.buffer.asByteData();
  var i = 0;
  for (; i + 4 <= size; i += 4) {
    data.setUint32(i, rand.nextInt(1 << 32));
  }
  for (; i < size; i++) {
    out[i] = rand.nextInt(256);
  }
  return out;
}

/// Upload + download bandwidth measured against ONE Blossom server.
/// Both speeds null = the upload failed (unreachable / auth rejected /
/// timeout); only [downloadMBps] null = upload succeeded but download failed.
class BlossomSpeed {
  const BlossomSpeed({this.uploadMBps, this.downloadMBps});
  final double? uploadMBps;
  final double? downloadMBps;

  @override
  String toString() =>
      'BlossomSpeed(upload: $uploadMBps MB/s, download: $downloadMBps MB/s)';
}

/// Measures real upload AND download bandwidth against ONE Blossom [server]:
///
/// 1. UPLOAD — PUTs [testBytes] (default: a fresh [blossomSpeedTestBytesSize]
///    random file declared as video/mp4, i.e. the exact real-upload path with
///    BUD-02 auth) and times the full round trip. package:http's `put` only
///    returns after the whole body is sent and the response received, so the
///    stopwatch spans the entire transfer — true end-to-end throughput.
/// 2. DOWNLOAD — GETs the public URL the upload returned (whole body received
///    before `get` returns) and times it.
/// 3. CLEANUP — best-effort `DELETE <server>/<sha256>` (BUD delete endpoint)
///    so repeated speed tests don't pile 10 MiB files on the server. Any
///    delete failure (unsupported, rejected, timeout) is ignored and never
///    taints the measured result.
///
/// [timeout] caps EACH direction separately (30s default ≈ 0.35 MB/s floor —
/// a server slower than that is unusable for media uploads anyway).
/// [client] is injectable for tests (MockClient); production shares
/// [_uploadClient] (connection reuse, same as real uploads).
Future<BlossomSpeed> measureBlossomSpeed(
  Identity identity,
  String server, {
  List<int>? testBytes,
  Duration timeout = const Duration(seconds: 30),
  http.Client? client,
}) async {
  final bytes = testBytes ?? blossomSpeedTestBytes();
  final sha = crypto.sha256.convert(bytes).toString();
  final authHeader = _nostrAuthHeader(
    _buildAuthEvent(
      identity,
      sha,
      bytes.length,
      'video/mp4',
      'costr speed test',
    ),
  );
  final c = client ?? _uploadClient;

  // Upload.
  final upSw = Stopwatch()..start();
  final uploaded = await _putToServer(
    c,
    server,
    bytes,
    sha: sha,
    authHeader: authHeader,
    mimetype: 'video/mp4',
    timeout: timeout,
  );
  upSw.stop();
  if (uploaded == null) return const BlossomSpeed();
  final uploadMBps = _mbPerSecond(bytes.length, upSw.elapsed);

  // Download.
  double? downloadMBps;
  try {
    final downSw = Stopwatch()..start();
    final res = await c.get(Uri.parse(uploaded.url)).timeout(timeout);
    downSw.stop();
    if (res.statusCode == 200) {
      downloadMBps = _mbPerSecond(res.bodyBytes.length, downSw.elapsed);
    }
  } catch (_) {
    // Download failed / timed out — still report the upload speed.
  }

  // Best-effort cleanup.
  try {
    final deleteAuth = _nostrAuthHeader(_buildDeleteEvent(identity, sha));
    await c
        .delete(
          Uri.parse('${server.replaceAll(RegExp(r'/+$'), '')}/$sha'),
          headers: <String, String>{'Authorization': deleteAuth},
        )
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // Cleanup is best-effort; the result stands either way.
  }

  return BlossomSpeed(uploadMBps: uploadMBps, downloadMBps: downloadMBps);
}

/// MB/s (MiB basis, matching the UI's 「MB/s」 label) from a byte count and
/// an elapsed time; clamps the divisor so an instant (cached) transfer can't
/// divide by zero.
double _mbPerSecond(int byteCount, Duration elapsed) {
  final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  return byteCount / (1024 * 1024) / (seconds < 0.001 ? 0.001 : seconds);
}

/// BUD delete auth event: same kind-24242 as upload auth but with
/// `t=delete` and only the hash tag. Kept separate from [_buildAuthEvent]
/// (which hardcodes `t=upload` plus the size/m tags).
Event _buildDeleteEvent(Identity id, String sha256Hex) {
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600; // +1h
  return id.signEvent(
    kind: 24242,
    content: 'costr speed test cleanup',
    tags: <List<String>>[
      <String>['t', 'delete'],
      <String>['x', sha256Hex],
      <String>['expiration', '$exp'],
    ],
  );
}
