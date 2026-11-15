import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/detector.dart';
import '../services/geometry.dart';

/// Meluruskan foto yang diambil miring (perspektif) sehingga bibir pipa tampak bulat menghadap depan.
/// Mengembalikan bytes foto hasil (PNG) atau null bila dibatalkan / tidak ada perubahan.
class StraightenScreen extends StatefulWidget {
  final Uint8List bytes;
  const StraightenScreen({super.key, required this.bytes});
  @override
  State<StraightenScreen> createState() => _StraightenScreenState();
}

class _StraightenScreenState extends State<StraightenScreen> {
  ui.Image? _prev;
  double pitch = 0, yaw = 0, roll = 0, fs = 0.8;
  bool busy = false, grid = true;
  String? msg;
  Rectified? _rect;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final codec = await ui.instantiateImageCodec(widget.bytes, targetWidth: 1400);
    final f = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _prev = f.image);
    _recalc();
  }

  void _recalc() {
    final p = _prev;
    if (p == null) return;
    final r = rectify(p.width, p.height, pitch, yaw, roll, fs);
    setState(() {
      if (r != null) _rect = r;
      if (r == null) {
        msg = 'Sudut terlalu ekstrem untuk dihitung. Kurangi sudutnya.';
      } else if (msg != null && msg!.startsWith('Sudut terlalu')) {
        msg = null;
      }
    });
  }

  bool get _changed => pitch.abs() > 0.2 || yaw.abs() > 0.2 || roll.abs() > 0.2;

  void _reset() {
    setState(() {
      pitch = 0;
      yaw = 0;
      roll = 0;
      msg = null;
    });
    _recalc();
  }

  Future<void> _auto() async {
    setState(() {
      busy = true;
      msg = 'Menganalisis kemiringan foto…';
    });
    try {
      final r = await compute(estimateTilt, {'bytes': widget.bytes, 'fs': fs, 'enh': 0});
      if (!mounted) return;
      if (r['ok'] == true) {
        pitch = (r['pitch'] as double);
        yaw = (r['yaw'] as double);
        roll = 0;
        msg = 'Terdeteksi miring ±${pitch.abs().round()}° (atas-bawah) dan ±${yaw.abs().round()}° (kiri-kanan). Sesuaikan dengan slider bila perlu.';
      } else {
        msg = 'Tidak ada koreksi yang meyakinkan: foto sudah cukup lurus atau sulit dianalisis. Atur manual dengan slider.';
      }
    } catch (e) {
      msg = 'Analisis gagal: $e';
    }
    if (mounted) setState(() => busy = false);
    _recalc();
  }

  Matrix4 _m4(List<double> a) => Matrix4(a[0], a[3], 0, a[6], a[1], a[4], 0, a[7], 0, 0, 1, 0, a[2], a[5], 0, a[8]);

  Future<void> _apply() async {
    if (!_changed) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      busy = true;
      msg = 'Memproses foto…';
    });
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final full = (await codec.getNextFrame()).image;
      final r = rectify(full.width, full.height, pitch, yaw, roll, fs);
      if (r == null) {
        setState(() {
          busy = false;
          msg = 'Sudut terlalu ekstrem untuk dihitung.';
        });
        return;
      }
      final s = math.min(1.0, 2400 / math.max(r.w, r.hgt));
      final ow = math.max(16, (r.w * s).round()), oh = math.max(16, (r.hgt * s).round());
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec, Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble()));
      canvas.clipRect(Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble()));
      canvas.transform(_m4(toCanvas(r, s)).storage);
      canvas.drawImage(full, Offset.zero, Paint()..filterQuality = FilterQuality.high..isAntiAlias = true);
      final out = await rec.endRecording().toImage(ow, oh);
      final bd = await out.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.pop(context, bd!.buffer.asUint8List());
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          msg = 'Gagal memproses: $e';
        });
      }
    }
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> f, {String unit = '°', int dec = 0}) {
    return Row(children: [
      SizedBox(width: 96, child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5))),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(activeTrackColor: Colors.amber, thumbColor: Colors.amber, inactiveTrackColor: Colors.white24),
          child: Slider(
            value: v.clamp(min, max),
            min: min,
            max: max,
            onChanged: busy
                ? null
                : (x) {
                    f(x);
                    _recalc();
                  },
          ),
        ),
      ),
      SizedBox(width: 48, child: Text('${v.toStringAsFixed(dec)}$unit', textAlign: TextAlign.right, style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w800, fontSize: 12))),
    ]);
  }

  Widget _preview() {
    final p = _prev, r = _rect;
    if (p == null || r == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (ctx, box) {
      final k = math.min(box.maxWidth / r.w, box.maxHeight / r.hgt);
      final w = r.w * k, h = r.hgt * k;
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(children: [
            ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: p.width.toDouble(),
                maxWidth: p.width.toDouble(),
                minHeight: p.height.toDouble(),
                maxHeight: p.height.toDouble(),
                child: Transform(
                  transform: _m4(toCanvas(r, k)),
                  child: RawImage(image: p, width: p.width.toDouble(), height: p.height.toDouble(), fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                ),
              ),
            ),
            if (grid) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GridPainter()))),
          ]),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final r = _rect;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D10),
        foregroundColor: Colors.white,
        title: const Text('Luruskan Foto'),
        actions: [
          IconButton(tooltip: 'Garis bantu', onPressed: () => setState(() => grid = !grid), icon: Icon(grid ? Icons.grid_on : Icons.grid_off)),
        ],
      ),
      body: Column(children: [
        Expanded(child: _preview()),
        Container(
          padding: EdgeInsets.fromLTRB(16, 10, 16, bottom + 12),
          color: const Color(0xFF121820),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || _prev == null ? null : _auto,
                  icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_awesome),
                  label: const Text('Otomatis'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(onPressed: busy ? null : _reset, icon: const Icon(Icons.restart_alt), label: const Text('Reset'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38))),
            ]),
            if (msg != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(msg!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            const SizedBox(height: 4),
            _slider('Atas–bawah', pitch, -70, 70, (v) => pitch = v),
            _slider('Kiri–kanan', yaw, -50, 50, (v) => yaw = v),
            _slider('Putar', roll, -30, 30, (v) => roll = v),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                iconColor: Colors.white70,
                collapsedIconColor: Colors.white70,
                title: const Text('Lanjutan: sudut lensa', style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                children: [_slider('Sudut lensa', fs, 0.5, 1.4, (v) => fs = v, unit: '', dec: 2)],
              ),
            ),
            Text(
              r == null ? '' : 'Hasil sekitar ${r.w.round()} x ${r.hgt.round()} px (sebelum dibatasi 2400 px)',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: busy ? null : () => Navigator.pop(context), style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)), child: const Text('Batal'))),
              const SizedBox(width: 12),
              Expanded(child: FilledButton.icon(onPressed: busy || _prev == null || r == null ? null : _apply, icon: const Icon(Icons.check), label: const Text('Terapkan'))),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size z) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      c.drawLine(Offset(z.width * i / 8, 0), Offset(z.width * i / 8, z.height), p);
      c.drawLine(Offset(0, z.height * i / 8), Offset(z.width, z.height * i / 8), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
