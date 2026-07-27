/// Compose page — write a kind-1 text note, sign it (NIP-01), publish to relays.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key});

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;

  /// Soft char limit (X-style). Nostr has no hard limit; we warn past this.
  static const int _softLimit = 280;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _snack('内容不能为空');
      return;
    }
    final identity = ref.read(identityProvider).value;
    if (identity == null) {
      _snack('未登录');
      return;
    }
    setState(() => _sending = true);
    try {
      final signed = identity.signEvent(kind: 1, content: text, tags: const []);
      ref.read(relayPoolProvider).publish(signed);
      if (mounted) context.pop();
    } catch (e) {
      _snack('发送失败：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final count = _controller.text.length;
    final over = count > _softLimit;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发帖'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? '发送中…' : '发送'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: '有什么新鲜事？',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Row(
              children: [
                Text(
                  '仅文本（附图后续支持）',
                  style: theme.textTheme.labelSmall,
                ),
                const Spacer(),
                Text(
                  '$count',
                  style: TextStyle(
                    color: over ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
