/// Compose page — write a kind-1 note, sign it, publish. Supports reply
/// (replyTo) and quote (quoteOf) contexts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../nostr/actions.dart';

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key, this.replyTo, this.quoteOf});

  final Event? replyTo;
  final Event? quoteOf;

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  static const int _softLimit = 280;

  @override
  void initState() {
    super.initState();
    if (widget.quoteOf != null) {
      // Quote: pre-fill nothing; the quote ref is appended on send.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _hint {
    if (widget.replyTo != null) return '回复…';
    if (widget.quoteOf != null) return '引用评论…';
    return '有什么新鲜事？';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final identity = ref.read(identityProvider).value;
    if (identity == null) {
      _snack('未登录'); return;
    }
    if (text.isEmpty && widget.quoteOf == null) {
      _snack('内容不能为空'); return;
    }
    setState(() => _sending = true);
    try {
      final actions = NostrActions(identity);
      final signed = widget.replyTo != null
          ? actions.reply(widget.replyTo!, text)
          : widget.quoteOf != null
              ? actions.quote(widget.quoteOf!, text)
              : identity.signEvent(kind: 1, content: text, tags: const []);
      final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
      if (!mounted) return;
      _snack(ok.ok ? '已发布' : '发布失败：${ok.reason}');
      if (ok.ok && context.mounted) context.pop();
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
        title: Text(widget.replyTo != null
            ? '回复'
            : widget.quoteOf != null
                ? '引用'
                : '发帖'),
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
            if (widget.replyTo != null) _ContextCard(event: widget.replyTo!, label: '回复'),
            if (widget.quoteOf != null) _ContextCard(event: widget.quoteOf!, label: '引用'),
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: InputDecoration(hintText: _hint, border: InputBorder.none),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Row(
              children: [
                Text('仅文本（附图后续支持）', style: theme.textTheme.labelSmall),
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

/// Compact quoted context (the post being replied to / quoted).
class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.event, required this.label});
  final Event event;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            event.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
