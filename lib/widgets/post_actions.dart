/// X-style action row under a post: reply / repost / like / bookmark / share.
///
/// v1: share works (copies the `note1…` link). Reply/repost/like/bookmark need
/// signing (NIP-25/NIP-18/kind-1 reply) which lands with the compose feature;
/// until then they show a "即将支持" toast so the interaction is honest.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/event.dart';
import '../utils/nip19.dart';

class PostActions extends StatelessWidget {
  const PostActions({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        _Action(
          icon: Icons.chat_bubble_outline,
          onTap: () => _soon(context, '回复'),
          color: fg,
        ),
        _Action(
          icon: Icons.repeat_rounded,
          onTap: () => _soon(context, '转发'),
          color: fg,
        ),
        _Action(
          icon: Icons.favorite_border,
          onTap: () => _soon(context, '点赞'),
          color: fg,
        ),
        _Action(
          icon: Icons.bookmark_border,
          onTap: () => _soon(context, '收藏'),
          color: fg,
        ),
        const Spacer(),
        _Action(
          icon: Icons.ios_share,
          onTap: () => _share(context, event),
          color: fg,
        ),
      ],
    );
  }

  void _soon(BuildContext context, String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name即将支持（待发帖功能上线后启用）'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _share(BuildContext context, Event e) async {
    try {
      final note = hexToNote(e.id);
      await Clipboard.setData(ClipboardData(text: note));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制 note1 链接'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('复制失败')),
        );
      }
    }
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.onTap, required this.color});
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      color: color,
      onPressed: onTap,
    );
  }
}
