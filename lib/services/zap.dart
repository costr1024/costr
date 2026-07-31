/// NIP-57 zap (打闪) — resolve a recipient's Lightning address (lud16 /
/// lud06 from kind-0 metadata) to a LNURL-pay request, optionally sign a
/// kind-9734 zap request, and fetch a BOLT11 invoice.
///
/// Functions take an [httpGet] callback (returns the response body) so they
/// are unit-testable without a network. The UI wires `package:http` in.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../nostr/identity.dart';
import '../utils/bech32_codec.dart';

class ZapException implements Exception {
  const ZapException(this.message);
  final String message;
  @override
  String toString() => 'ZapException: $message';
}

/// A resolved LNURL-pay request (LUD-06). Amounts are millisatoshis.
class LnurlPayRequest {
  const LnurlPayRequest({
    required this.callback,
    required this.minSendable,
    required this.maxSendable,
    required this.metadata,
    this.allowsNostr = false,
    this.nostrPubkey,
  });
  final String callback;
  final int minSendable;
  final int maxSendable;
  final String metadata;
  final bool allowsNostr;
  final String? nostrPubkey;
}

/// The LNURL-pay request URL for a lud16 ("user@host") or lud06 ("lnurl1…").
@visibleForTesting
Uri payRequestUri(String lud16OrLud06) {
  final v = lud16OrLud06.trim();
  if (v.toLowerCase().startsWith('lnurl1')) {
    // lud06: decode bech32 (hrp "lnurl") → UTF-8 URL.
    final decoded = decodeBech32(v);
    final url = utf8.decode(decoded.data);
    return Uri.parse(url);
  }
  final at = v.lastIndexOf('@');
  if (at <= 0 || at >= v.length - 1) {
    throw ZapException('无效的闪电地址：$v');
  }
  final user = v.substring(0, at);
  final host = v.substring(at + 1);
  return Uri.parse('https://$host/.well-known/lnurlp/$user');
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? -1;
}

/// Resolve the payRequest JSON for [lud16OrLud06]. [httpGet] returns the
/// response body; throws [ZapException] on any malformation.
Future<LnurlPayRequest> resolveLnurlPay(
  String lud16OrLud06,
  Future<String> Function(Uri) httpGet,
) async {
  final uri = payRequestUri(lud16OrLud06);
  final body = await httpGet(uri);
  final j = jsonDecode(body);
  if (j is! Map<String, dynamic>) {
    throw const ZapException('闪电地址返回格式错误');
  }
  final callback = j['callback']?.toString();
  if (callback == null || callback.isEmpty) {
    throw const ZapException('闪电地址未提供 callback');
  }
  final minS = _asInt(j['minSendable']);
  final maxS = _asInt(j['maxSendable']);
  if (minS < 0 || maxS < 0) {
    throw const ZapException('闪电地址未提供金额范围');
  }
  return LnurlPayRequest(
    callback: callback,
    minSendable: minS,
    maxSendable: maxS,
    metadata: (j['metadata'] ?? '').toString(),
    allowsNostr: j['allowsNostr'] == true,
    nostrPubkey: j['nostrPubkey']?.toString(),
  );
}

/// Fetch a BOLT11 invoice for zapping [recipientPubkey] (optionally for a
/// note [zappedNoteId]) for [amountMsat] millisatoshis. If [pay] supports
/// NIP-57 (allowsNostr), signs a kind-9734 zap request via [signer] and
/// includes it; otherwise falls back to a plain LNURL-pay invoice.
///
/// [relays] is the relays tag (where the recipient's zap provider should
/// publish the kind-9735 zap receipt).
Future<String> requestZapInvoice({
  required LnurlPayRequest pay,
  required int amountMsat,
  required String recipientPubkey,
  required Identity signer,
  required List<String> relays,
  String? zappedNoteId,
  String? comment,
  required Future<String> Function(Uri) httpGet,
}) async {
  if (amountMsat < pay.minSendable || amountMsat > pay.maxSendable) {
    throw ZapException(
      '金额超出范围（${pay.minSendable ~/ 1000}–${pay.maxSendable ~/ 1000} 聪）',
    );
  }
  final base = Uri.parse(pay.callback);
  final params = Map<String, String>.from(base.queryParameters);
  params['amount'] = '$amountMsat';
  if (comment != null && comment.isNotEmpty) {
    params['comment'] = comment;
  }
  if (pay.allowsNostr) {
    final zapReq = signer.signEvent(
      kind: 9734,
      content: '',
      tags: <List<String>>[
        ['p', recipientPubkey],
        ['amount', '$amountMsat'],
        ['lnurl', base.toString()],
        if (zappedNoteId != null) ['e', zappedNoteId],
        ['relays', ...relays],
      ],
    );
    params['nostr'] = jsonEncode(zapReq.toWireObject());
    params['lnurl'] = base.toString();
  }
  final uri = base.replace(queryParameters: params);
  final body = await httpGet(uri);
  final j = jsonDecode(body);
  if (j is! Map<String, dynamic>) {
    throw const ZapException('闪电服务器返回格式错误');
  }
  final pr = j['pr']?.toString();
  if (pr == null || pr.isEmpty) {
    final reason = j['reason']?.toString();
    throw ZapException(reason != null && reason.isNotEmpty ? '闪电服务器拒绝：$reason' : '未取到发票');
  }
  return pr;
}
