/// 打闪 (zap, NIP-57) bottom sheet — entered from the post `⋮` menu.
///
/// Resolves the recipient's lud16/lud06 (Lightning address) → LNURL-pay →
/// signs a kind-9734 zap request → fetches a BOLT11 invoice. Shows the invoice
/// as a QR + selectable text + "在钱包中打开" (lightning: deeplink).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../services/zap.dart';
import '../../widgets/avatar.dart';

/// Show the zap sheet for [event]'s author.
void showZapSheet(BuildContext context, Event event) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ZapSheet(event: event),
  );
}

class _ZapSheet extends ConsumerStatefulWidget {
  const _ZapSheet({required this.event});
  final Event event;

  @override
  ConsumerState<_ZapSheet> createState() => _ZapSheetState();
}

class _ZapSheetState extends ConsumerState<_ZapSheet> {
  final _amountCtrl = TextEditingController(text: '100');
  final _commentCtrl = TextEditingController();
  bool _busy = false;
  String? _invoice;
  String? _recipientName;
  static const List<int> _presets = [100, 500, 1000, 5000, 10000];

  @override
  void dispose() {
    _amountCtrl.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<String> _httpGet(Uri uri) async {
    final res = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ZapException('闪电服务器返回 ${res.statusCode}');
    }
    return res.body;
  }

  Future<void> _generate() async {
    final identity = ref.read(identityProvider).value;
    final meta = ref.read(metadataProvider(widget.event.pubkey)).value;
    final ln = meta?.lud16 ?? meta?.lud06;
    if (identity == null || ln == null || ln.isEmpty) return;
    final sats = int.tryParse(_amountCtrl.text.trim());
    if (sats == null || sats <= 0) {
      _toast('请输入有效的聪数量');
      return;
    }
    setState(() => _busy = true);
    try {
      final pay = await resolveLnurlPay(ln, _httpGet);
      final invoice = await requestZapInvoice(
        pay: pay,
        amountMsat: sats * 1000,
        recipientPubkey: widget.event.pubkey,
        signer: identity,
        relays: defaultRelays,
        zappedNoteId: widget.event.id,
        comment: _commentCtrl.text.trim(),
        httpGet: _httpGet,
      );
      if (!mounted) return;
      setState(() => _invoice = invoice);
    } on ZapException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('打闪失败：网络错误');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = ref.watch(metadataProvider(widget.event.pubkey)).value;
    _recipientName = meta?.bestName ?? '该用户';
    final ln = meta?.lud16 ?? meta?.lud06;
    final theme = Theme.of(context);
    final pad = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.bolt, color: CostrColors.brand),
                  const SizedBox(width: 8),
                  Text('打闪', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (ln == null || ln.isEmpty)
              _noLightningAddress(theme)
            else if (_invoice != null)
              _invoiceView(theme)
            else
              _amountForm(theme),
          ],
        ),
      ),
    );
  }

  Widget _noLightningAddress(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 40, color: CostrColors.text3),
          const SizedBox(height: 12),
          Text(
            '$_recipientName 未配置闪电地址，无法打闪',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '对方需在个人资料里设置 Lightning 地址（lud16）后才能接收打闪。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: CostrColors.text3),
          ),
        ],
      ),
    );
  }

  Widget _amountForm(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Avatar(pubkey: widget.event.pubkey, radius: 16),
              const SizedBox(width: 8),
              Text('打闪给 $_recipientName',
                  style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 16),
          Text('金额（聪）', style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.bolt, size: 20),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _presets)
                ActionChip(
                  label: Text('$s'),
                  onPressed: () => _amountCtrl.text = '$s',
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commentCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '留言（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.bolt, size: 20),
              label: const Text('生成发票'),
              onPressed: _busy ? null : _generate,
            ),
          ),
        ],
      ),
    );
  }

  Widget _invoiceView(ThemeData theme) {
    final invoice = _invoice!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('发票已生成',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: CostrColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: invoice,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CostrColors.bg2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              invoice,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: CostrColors.text2,
              ),
              maxLines: 3,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制发票'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: invoice));
                    _toast('已复制发票');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.account_balance_wallet, size: 18),
                  label: const Text('在钱包中打开'),
                  onPressed: () async {
                    final ok = await launchUrl(
                      Uri.parse('lightning:$invoice'),
                      mode: LaunchMode.externalApplication,
                    );
                    if (!ok) _toast('未找到可处理闪电发票的应用');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
