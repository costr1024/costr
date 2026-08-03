/// Costr logo — broadcast arcs + dot ("你是自己的广播站" metaphor).
/// Used in: AppBar logo, FAB, login page, about page.
library;

import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Size-configurable Costr logo mark (broadcast arcs + dot).
/// [color] defaults to the ambient [CostrColors.of] brand — dark-mode aware.
/// Pass an explicit color only when drawing on a contrasting fill (e.g. the
/// FAB passes its `onBrand`).
class CostrLogo extends StatelessWidget {
  const CostrLogo({super.key, this.size = 28, this.color});

  /// White logo for permanently-dark backgrounds (splash).
  const CostrLogo.light({super.key, this.size = 28}) : color = Colors.white;

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LogoPainter(color: color ?? CostrColors.of(context).brand),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeCap = StrokeCap.round;

    final cx = size.width * 0.28;
    final cy = size.height * 0.5;

    // Three concentric broadcast arcs (right-pointing).
    // Arc 1 (smallest)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: size.width * 0.12),
      -0.5,
      1.0,
      false,
      paint,
    );
    // Arc 2 (medium)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: size.width * 0.22),
      -0.5,
      1.0,
      false,
      paint,
    );
    // Arc 3 (largest)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: size.width * 0.32),
      -0.5,
      1.0,
      false,
      paint,
    );

    // Dot (the source — "you").
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(cx - size.width * 0.08, cy),
      size.width * 0.04,
      dotPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.color != color;
}

/// A text logo: mark + "Costr" wordmark. [color] defaults to the ambient
/// [CostrColors.of] brand (dark-mode aware).
class CostrWordmark extends StatelessWidget {
  const CostrWordmark({
    super.key,
    this.logoSize = 28,
    this.fontSize = 20,
    this.color,
  });

  final double logoSize;
  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? CostrColors.of(context).brand;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CostrLogo(size: logoSize, color: c),
        const SizedBox(width: 8),
        Text(
          'Costr',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: c,
          ),
        ),
      ],
    );
  }
}
