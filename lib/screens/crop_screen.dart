import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/detector.dart';

/// Pilih area foto yang akan dihitung. Mengembalikan bytes JPEG hasil crop (atau null jika dibatalkan).
class CropScreen extends StatefulWidget {
  final Uint8List bytes;
  const CropScreen({super.key, required this.bytes});
  @override
  State<CropScreen> createState() => _CropScreenState();
}

enum _H { none, move, tl, tr, bl, br, l, r, t, b }

class _CropScreenState extends State<CropScreen> {
  late Uint8List _bytes = widget.bytes;
  ui.Image? _preview; // versi kecil hanya untuk tampilan & rasio
  // Area crop dalam koordinat ternormalisasi 0..1
  Rect _crop = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
  double? _aspect; // lebar/tinggi piksel; null = bebas
  _H _h = _H.none;
  Rect _startCrop = Rect.zero;
  Offset _startPt = Offset.zero;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final codec = await ui.instantiateImageCodec(_bytes, targetWidth: 1400);
    final f = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _preview = f.image;
      _crop = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
      if (_aspect != null) _applyAspect(_aspect!);
    });
  }

  double get _imgAspect => _preview == null ? 1 : _preview!.width / _preview!.height;

  void _applyAspect(double a) {
    // a = lebar/tinggi piksel -> rasio ternormalisasi w/h = a / imgAspect
    final k = a / _imgAspect;
    final c = _crop.center;
    var w = _crop.width, h = w / k;
    if (h > 1) {
      h = 1;
      w = h * k;
    }
    if (w > 1) {
      w = 1;
      h = w / k;
    }
    var l = (c.dx - w / 2).clamp(0.0, 1.0 - w), t = (c.dy - h / 2).clamp(0.0, 1.0 - h);
    _crop = Rect.fromLTWH(l, t, w, h);
  }

  Rect _fit(Size box) {
    final a = _imgAspect;
    double w = box.width, h = w / a;
    if (h > box.height) {
      h = box.height;
      w = h * a;
    }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  _H _hit(Offset p, Rect px) {
    const t = 34.0;
    final cs = {
      _H.tl: px.topLeft,
      _H.tr: px.topRight,
      _H.bl: px.bottomLeft,
      _H.br: px.bottomRight,
    };
    for (final e in cs.entries) {
      if ((p - e.value).distance <= t) return e.key;
    }
    if (_aspect == null) {
      if ((p.dx - px.left).abs() <= t && p.dy > px.top && p.dy < px.bottom) return _H.l;
      if ((p.dx - px.right).abs() <= t && p.dy > px.top && p.dy < px.bottom) return _H.r;
      if ((p.dy - px.top).abs() <= t && p.dx > px.left && p.dx < px.right) return _H.t;
      if ((p.dy - px.bottom).abs() <= t && p.dx > px.left && p.dx < px.right) return _H.b;
    }
    if (px.contains(p)) return _H.move;
    return _H.none;
  }

  void _drag(Offset p, Rect fit) {
    const minS = 0.06;
    final d = Offset((p.dx - _startPt.dx) / fit.width, (p.dy - _startPt.dy) / fit.height);
    var r = _startCrop;
    double l = r.left, t = r.top, rt = r.right, b = r.bottom;
    switch (_h) {
      case _H.move:
        l = (r.left + d.dx).clamp(0.0, 1.0 - r.width);
        t = (r.top + d.dy).clamp(0.0, 1.0 - r.height);
        _crop = Rect.fromLTWH(l, t, r.width, r.height);
        return;
      case _H.l:
        l = (r.left + d.dx).clamp(0.0, rt - minS);
      case _H.r:
        rt = (r.right + d.dx).clamp(l + minS, 1.0);
      case _H.t:
        t = (r.top + d.dy).clamp(0.0, b - minS);
      case _H.b:
        b = (r.bottom + d.dy).clamp(t + minS, 1.0);
      case _H.tl || _H.tr || _H.bl || _H.br:
        final left = _h == _H.tl || _H.bl == _h;
        final top = _h == _H.tl || _h == _H.tr;
        if (left) {
          l = (r.left + d.dx).clamp(0.0, rt - minS);
        } else {
          rt = (r.right + d.dx).clamp(l + minS, 1.0);
        }
        if (top) {
          t = (r.top + d.dy).clamp(0.0, b - minS);
        } else {
          b = (r.bottom + d.dy).clamp(t + minS, 1.0);
        }
        if (_aspect != null) {
          final k = _aspect! / _imgAspect;
          var w = rt - l;
          var h = w / k;
          if (top) {
            t = b - h;
            if (t < 0) {
              t = 0;
              h = b;
              w = h * k;
              if (left) {
                l = rt - w;
              } else {
                rt = l + w;
              }
            }
          } else {
            b = t + h;
            if (b > 1) {
              b = 1;
              h = b - t;
              w = h * k;
              if (left) {
                l = rt - w;
              } else {
                rt = l + w;
              }
            }
          }
        }
      case _H.none:
        return;
    }
    _crop = Rect.fromLTRB(l, t, rt, b);
  }

  Future<void> _rotate() async {
    setState(() => _busy = true);
    _bytes = await compute(rotateImage, _bytes);
    await _loadPreview();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _apply({bool whole = false}) async {
    if (whole) return Navigator.pop(context, _bytes);
    setState(() => _busy = true);
    final out = await compute(cropImage, {
      'bytes': _bytes,
      'l': _crop.left,
      't': _crop.top,
      'w': _crop.width,
      'h': _crop.height,
      'maxSide': 2400,
    });
    if (mounted) Navigator.pop(context, out);
  }

  Widget _aspectChip(String label, double? a) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: _aspect == a,
          onSelected: (_) => setState(() {
            _aspect = a;
            if (a != null) _applyAspect(a);
          }),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pv = _preview;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D10),
        foregroundColor: Colors.white,
        title: const Text('Pilih Area Hitung'),
        actions: [IconButton(tooltip: 'Putar 90°', onPressed: _busy ? null : _rotate, icon: const Icon(Icons.rotate_90_degrees_cw_outlined))],
      ),
      body: Column(children: [
        Expanded(
          child: pv == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(builder: (ctx, box) {
                  final fit = _fit(Size(box.maxWidth, box.maxHeight));
                  final px = Rect.fromLTWH(fit.left + _crop.left * fit.width, fit.top + _crop.top * fit.height, _crop.width * fit.width, _crop.height * fit.height);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) {
                      _h = _hit(d.localPosition, px);
                      _startCrop = _crop;
                      _startPt = d.localPosition;
                    },
                    onPanUpdate: (d) {
                      if (_h == _H.none) return;
                      setState(() => _drag(d.localPosition, fit));
                    },
                    onPanEnd: (_) => _h = _H.none,
                    child: Stack(children: [
                      Positioned.fromRect(rect: fit, child: RawImage(image: pv, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
                      Positioned.fill(child: CustomPaint(painter: _CropPainter(fit, px))),
                    ]),
                  );
                }),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 12),
          color: const Color(0xFF121820),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _aspectChip('Bebas', null),
                _aspectChip('1:1', 1),
                _aspectChip('4:3', 4 / 3),
                _aspectChip('3:4', 3 / 4),
                _aspectChip('16:9', 16 / 9),
                ActionChip(label: const Text('Reset'), onPressed: () => setState(() => _crop = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9))),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
              pv == null ? '' : 'Area dipilih: ${(_crop.width * 100).round()}% x ${(_crop.height * 100).round()}% dari foto',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _apply(whole: true), child: const Text('Pakai Seluruh Foto'))),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || pv == null ? null : _apply,
                  icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.crop),
                  label: const Text('Terapkan Crop'),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect fit, crop;
  _CropPainter(this.fit, this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()
      ..addRect(fit)
      ..addRect(crop)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRect(crop, line);
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(crop.left + crop.width * i / 3, crop.top), Offset(crop.left + crop.width * i / 3, crop.bottom), thin);
      canvas.drawLine(Offset(crop.left, crop.top + crop.height * i / 3), Offset(crop.right, crop.top + crop.height * i / 3), thin);
    }
    final h = Paint()
      ..color = const Color(0xFFFFB300)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final L = math.min(26.0, math.min(crop.width, crop.height) / 3);
    void corner(Offset c, double sx, double sy) {
      canvas.drawLine(c, c + Offset(sx * L, 0), h);
      canvas.drawLine(c, c + Offset(0, sy * L), h);
    }

    corner(crop.topLeft, 1, 1);
    corner(crop.topRight, -1, 1);
    corner(crop.bottomLeft, 1, -1);
    corner(crop.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.crop != crop || old.fit != fit;
}
