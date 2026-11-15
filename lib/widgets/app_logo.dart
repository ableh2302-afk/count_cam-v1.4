import 'package:flutter/material.dart';

/// Logo aplikasi (kamera dengan lensa berlapis = pipa bersarang). Sama dengan ikon peluncur.
class AppLogo extends StatelessWidget {
  final double size;
  final bool withBackground;
  const AppLogo({super.key, this.size = 56, this.withBackground = true});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LogoPainter(withBackground));
}

class _LogoPainter extends CustomPainter {
  final bool bg;
  _LogoPainter(this.bg);

  @override
  void paint(Canvas c, Size z) {
    final w = z.width;
    Offset p(double x, double y) => Offset(x * w, y * w);
    if (bg) {
      final rr = RRect.fromRectAndRadius(Offset.zero & z, Radius.circular(w * 0.22));
      c.drawRRect(
        rr,
        Paint()..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0A3D62), Color(0xFF12B0BE)]).createShader(Offset.zero & z),
      );
    }
    const s = 0.92;
    double t(double v) => 0.5 + (v - 0.5) * s;
    RRect rect(double x0, double y0, double x1, double y1, double r) => RRect.fromLTRBR(t(x0) * w, t(y0) * w, t(x1) * w, t(y1) * w, Radius.circular(r * s * w));
    final white = Paint()..color = Colors.white;
    // bayangan lembut
    c.drawRRect(rect(0.15, 0.347, 0.85, 0.787, 0.10), Paint()..color = Colors.black.withValues(alpha: 0.18)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.012));
    c.drawRRect(rect(0.30, 0.245, 0.52, 0.40, 0.04), white);
    c.drawRRect(rect(0.15, 0.325, 0.85, 0.775, 0.10), white);
    c.drawRRect(rect(0.60, 0.265, 0.72, 0.31, 0.02), white);
    c.drawCircle(p(t(0.735), t(0.405)), 0.03 * s * w, Paint()..color = const Color(0xFFFF9F1C));
    final ctr = p(t(0.5), t(0.555));
    void ring(double r, Color col) => c.drawCircle(ctr, r * s * w, Paint()..color = col);
    ring(0.222, const Color(0xFF0A3550));
    ring(0.2, const Color(0xFFE2F4F8));
    ring(0.172, const Color(0xFF0A3550));
    ring(0.152, const Color(0xFF78DEE6));
    ring(0.124, const Color(0xFF0A3550));
    ring(0.104, const Color(0xFFE2F4F8));
    ring(0.078, const Color(0xFF061E2E));
    c.drawCircle(ctr + Offset(-0.03 * s * w, -0.035 * s * w), 0.02 * s * w, Paint()..color = Colors.white.withValues(alpha: 0.8));
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.bg != bg;
}
