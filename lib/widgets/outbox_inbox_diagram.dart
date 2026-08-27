/// Outbox/inbox explainer diagram (NIP-65): where your feed content comes
/// from and how replies reach you. Two flows:
/// - 读路 — 你刷的帖子/评论/点赞/转发，是去**对方的发件箱**（read 中继）取的；
/// - 写路 — 别人回复/@/私信你，是写进**你的收件箱**（write 中继）的。
///
/// Follows the app's diagram convention (see `_NostrProtocolDiagram` in
/// settings_page.dart): a bordered rounded card, 13px/w600 title, CustomPaint
/// arrows themed via [CostrColors] (dark-mode aware), 12px caption. No SVG
/// library / no bundled assets.
library;

import 'package:flutter/material.dart';

import '../app/theme.dart';

class OutboxInboxDiagram extends StatelessWidget {
  const OutboxInboxDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '发件箱 与 收件箱',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.text2,
            ),
          ),
          const SizedBox(height: 14),
          // Lane 1 — where your feed comes from: you FETCH other people's
          // posts/comments/likes/reposts from THEIR outbox (read relays).
          _FlowLane(
            left: const _LaneNode(icon: Icons.smartphone, label: '你'),
            right: const _LaneNode(
              icon: Icons.dns_outlined,
              label: '对方的发件箱',
            ),
            label: '你刷的帖子·评论·点赞·转发，去对方的发件箱取',
            pointLeft: true, // content flows from their outbox → you
          ),
          const SizedBox(height: 18),
          // Lane 2 — how replies reach you: others WRITE to YOUR inbox
          // (write relays).
          _FlowLane(
            left: const _LaneNode(icon: Icons.smartphone, label: '别人'),
            right: const _LaneNode(
              icon: Icons.move_to_inbox_outlined,
              label: '你的收件箱',
            ),
            label: '别人回复你·@你·私信你，写进你的收件箱',
            pointLeft: false, // content flows from others → your inbox
          ),
          const SizedBox(height: 12),
          Text(
            '发件箱＝一个人帖子所在的中继（NIP-65 read）；'
            '收件箱＝投递给本人的中继（NIP-65 write）。'
            '大多数中继两者都是，所以上面两个列表大量重合。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.text3, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// One horizontal flow lane: [left] node → labelled arrow → [right] node.
/// [pointLeft] flips the arrowhead so the arrow points at [left] (content
/// flowing right→left) instead of at [right] (left→right).
class _FlowLane extends StatelessWidget {
  const _FlowLane({
    required this.left,
    required this.right,
    required this.label,
    required this.pointLeft,
  });
  final Widget left;
  final Widget right;
  final String label;
  final bool pointLeft;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: colors.text3),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: left),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 18,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _ArrowPainter(
                    color: colors.text3,
                    pointLeft: pointLeft,
                  ),
                ),
              ),
            ),
            Expanded(child: right),
          ],
        ),
      ],
    );
  }
}

/// A small icon + label node used by [_FlowLane].
class _LaneNode extends StatelessWidget {
  const _LaneNode({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: colors.text2),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: colors.text2),
        ),
      ],
    );
  }
}

/// Draws a horizontal line with an arrowhead on one end.
class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.color, required this.pointLeft});
  final Color color;
  final bool pointLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    final head = Paint()..color = color;
    final y = size.height / 2;
    const headW = 7.0;
    const headH = 4.0;
    if (pointLeft) {
      canvas.drawLine(Offset(size.width, y), Offset(headW, y), line);
      canvas.drawPath(
        Path()
          ..moveTo(0, y)
          ..lineTo(headW, y - headH)
          ..lineTo(headW, y + headH)
          ..close(),
        head,
      );
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width - headW, y), line);
      canvas.drawPath(
        Path()
          ..moveTo(size.width, y)
          ..lineTo(size.width - headW, y - headH)
          ..lineTo(size.width - headW, y + headH)
          ..close(),
        head,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
