import 'package:flutter/material.dart';
import '../settings.dart';

/// Lembar "Gaya Penanda" (Basic / Advanced). Perubahan langsung tampil di foto.
Future<void> showMarkerStyleSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black26,
    builder: (_) => const _StyleSheet(),
  );
}

class _StyleSheet extends StatefulWidget {
  const _StyleSheet();
  @override
  State<_StyleSheet> createState() => _StyleSheetState();
}

class _StyleSheetState extends State<_StyleSheet> {
  final s = appSettings;
  int _tab = 0;

  void _upd(VoidCallback f) {
    setState(f);
    s.save();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: h * 0.62),
      decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ---- Header: reset | tab | selesai ----
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
            child: Row(children: [
              IconButton(tooltip: 'Kembalikan default', onPressed: () => _upd(s.resetMarkStyle), icon: Icon(Icons.restart_alt_rounded, color: cs.primary)),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    for (final e in const [(0, 'Dasar'), (1, 'Lanjutan')])
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _tab = e.$1),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            decoration: BoxDecoration(color: _tab == e.$1 ? cs.surface : Colors.transparent, borderRadius: BorderRadius.circular(11)),
                            alignment: Alignment.center,
                            child: Text(e.$2, style: TextStyle(fontWeight: FontWeight.w800, color: _tab == e.$1 ? cs.onSurface : cs.outline)),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              IconButton(tooltip: 'Selesai', onPressed: () => Navigator.pop(context), icon: Icon(Icons.check_rounded, color: cs.primary, size: 28)),
            ]),
          ),
          Flexible(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: _tab == 0 ? _basic(cs) : _advanced(cs))),
        ]),
      ),
    );
  }

  // ---------- Dasar ----------
  Widget _basic(ColorScheme cs) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [for (var i = 0; i < 6; i++) Expanded(child: Padding(padding: EdgeInsets.only(right: i < 5 ? 8 : 0), child: _styleTile(i, cs)))]),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Saring objek menyimpang', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text('Sembunyikan lingkaran yang ukurannya jauh beda atau terpencil', style: TextStyle(fontSize: 12)),
        value: s.filterOutliers,
        onChanged: (v) => _upd(() => s.filterOutliers = v),
      ),
      _sl('Ukuran label', s.textSize, 8, 32, (v) => s.textSize = v, div: 24),
      _sl('Opasitas masker', s.maskOpacity, 0.05, 1.0, (v) => s.maskOpacity = v, pct: true),
    ]);
  }

  Widget _styleTile(int i, ColorScheme cs) {
    final sel = s.markStyle == i;
    return GestureDetector(
      onTap: () => _upd(() => s.markStyle = i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 62,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sel ? cs.primary : Colors.transparent, width: 2),
        ),
        child: Center(child: CustomPaint(size: const Size(34, 34), painter: _StylePreview(i, s))),
      ),
    );
  }

  // ---------- Lanjutan ----------
  Widget _advanced(ColorScheme cs) {
    final fixed = <int>[0xFF84CC16, 0xFF2563EB, 0xFFEF4444, 0xFFFFFFFF, 0xFF000000, 0xFF22D3EE, 0xFFFACC15, 0xFF818CF8, 0xFF22C55E, 0xFFEC4899, 0xFFC084FC];
    Widget sw(Widget child, bool sel, VoidCallback f) => GestureDetector(
          onTap: f,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: sel ? cs.primary : cs.outlineVariant, width: sel ? 3 : 1)),
            child: ClipRRect(borderRadius: BorderRadius.circular(5), child: child),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Warna penanda', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        sw(Container(color: cs.primaryContainer, alignment: Alignment.center, child: Icon(Icons.straighten, size: 18, color: cs.primary)), s.markColorMode == -1, () => _upd(() => s.markColorMode = -1)),
        sw(
          Row(children: [for (final c in AppSettings.multiColors) Expanded(child: Container(color: Color(c)))]),
          s.markColorMode == -2,
          () => _upd(() => s.markColorMode = -2),
        ),
        for (final c in fixed) sw(Container(color: Color(c)), s.markColorMode == c, () => _upd(() => s.markColorMode = c)),
      ]),
      const SizedBox(height: 4),
      Text(
        s.markColorMode == -1 ? 'Warna mengikuti ukuran pipa (atur di Pengaturan)' : (s.markColorMode == -2 ? 'Warna berganti agar pipa bersebelahan mudah dibedakan' : 'Satu warna untuk semua penanda'),
        style: TextStyle(fontSize: 11.5, color: cs.outline),
      ),
      const SizedBox(height: 10),
      _sl('Opasitas label', s.labelOpacity, 0.2, 1.0, (v) => s.labelOpacity = v, pct: true),
      _sl('Ketebalan garis', s.ringWidth, 1, 8, (v) => s.ringWidth = v, div: 28),
      _sl('Kebulatan sudut (kotak)', s.roundness, 0, 1, (v) => s.roundness = v, pct: true),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Tampilkan nomor urut', style: TextStyle(fontWeight: FontWeight.w700)),
        value: s.showNumbers,
        onChanged: (v) => _upd(() => s.showNumbers = v),
      ),
    ]);
  }

  Widget _sl(String label, double v, double min, double max, ValueChanged<double> f, {int? div, bool pct = false}) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      SizedBox(width: 128, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
      Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, onChanged: (x) => _upd(() => f(x)))),
      SizedBox(width: 40, child: Text(pct ? '${(v * 100).round()}%' : v.toStringAsFixed(0), textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary, fontSize: 12))),
    ]);
  }
}

/// Pratinjau kecil tiap gaya penanda.
class _StylePreview extends CustomPainter {
  final int style;
  final AppSettings s;
  _StylePreview(this.style, this.s);

  @override
  void paint(Canvas c, Size z) {
    final ctr = Offset(z.width / 2, z.height / 2);
    final r = z.width / 2 - 2;
    final filled = style == 0 || style == 1 || style == 3 || style == 4;
    final square = style == 1 || style == 4;
    final numbered = style >= 3;
    Color col(int k) => s.markColorMode == -2 ? Color(AppSettings.multiColors[k % 3]) : (s.markColorMode >= 0 ? Color(s.markColorMode) : const Color(0xFF7CCB2E));

    void shape(Offset o, double rr, Color color) {
      final fill = Paint()..color = color.withValues(alpha: filled ? 0.95 : 0.15);
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = color;
      if (square) {
        final rect = Rect.fromCenter(center: o, width: rr * 1.7, height: rr * 1.7);
        final rr2 = RRect.fromRectAndRadius(rect, Radius.circular(rr * 0.85 * s.roundness));
        c.drawRRect(rr2, fill);
        if (!filled) c.drawRRect(rr2, line);
      } else {
        c.drawCircle(o, rr, fill);
        if (!filled) c.drawCircle(o, rr, line);
      }
    }

    if (style == 2 || style == 5) {
      // cincin bertumpuk berwarna ganda seperti pada referensi
      final cols = s.markColorMode == -2 ? [0, 1, 2] : [0, 0, 0];
      shape(ctr + const Offset(-4, -3), r * 0.78, col(cols[0]));
      shape(ctr + const Offset(4, -3), r * 0.78, col(cols[1]));
      shape(ctr + const Offset(0, 4), r * 0.78, col(cols[2]));
    } else {
      shape(ctr, r, col(0));
    }
    if (numbered) {
      final tp = TextPainter(
        text: TextSpan(text: '1', style: TextStyle(color: filled ? Colors.white : Colors.black87, fontWeight: FontWeight.w900, fontSize: 15)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, ctr - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _StylePreview old) => true;
}
