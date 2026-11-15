import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models.dart';
import '../services/db.dart';
import '../services/detector.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/style_sheet.dart';
import 'crop_screen.dart';
import 'straighten_screen.dart';

// ============================================================
//  Rendering penanda (dipakai layar & ekspor foto)
// ============================================================

class _Ping extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Data yang digambar; diubah langsung tanpa setState agar interaksi tetap halus.
class _Brush {
  final List<Offset> pts;
  final double r; // radius dalam piksel gambar
  _Brush(this.pts, this.r);
}

class _Vm {
  final markers = <Marker>[];
  final strokes = <Stroke>[];
  final brush = <_Brush>[];
  _Brush? curBrush;
  int? solo; // tampilkan hanya ukuran ini (mode Auto-All)
  Offset? lineStart; // titik awal garis (coret mode tap)
  Stroke? cur;
  Offset? refCenter;
  double refRadius = 35;
  bool showRef = false;
}

class _TextCache {
  final _m = <String, TextPainter>{};
  TextPainter get(String t, Color c, double fs) {
    if (_m.length > 2500) _m.clear();
    final key = '$t|${c.toARGB32()}|$fs';
    return _m.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(text: t, style: TextStyle(color: c, fontSize: fs, fontWeight: FontWeight.w800, height: 1.0)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }
}

const _fontSteps = [6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 28.0, 32.0];

/// Ukuran font diskret yang muat di dalam lingkaran (cache efektif, tidak berkedip).
double _fitFont(double maxFs, double screenR) {
  final target = math.min(maxFs, screenR * 1.1);
  var best = _fontSteps.first;
  for (final f in _fontSteps) {
    if (f <= target) best = f;
  }
  return best;
}

class MarkerPainter extends CustomPainter {
  final _Vm vm;
  final AppSettings s;
  final TransformationController tc;
  final _TextCache cache;
  MarkerPainter({required this.vm, required this.s, required this.tc, required this.cache, required Listenable repaint}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final sc = tc.value.entry(0, 0).abs();
    final scale = sc <= 0 ? 1.0 : sc;
    draw(canvas, vm, s, cache, 1 / scale, minTextScreenR: 5.5, showRef: vm.showRef);
  }

  /// [u] = ukuran 1 piksel layar dalam piksel gambar. Garis & teks selalu konstan di layar.
  static void draw(Canvas canvas, _Vm vm, AppSettings s, _TextCache cache, double u, {double minTextScreenR = 5.5, bool showRef = false}) {
    if (vm.brush.isNotEmpty || vm.curBrush != null) {
      final maskCol = const Color(0xFFE53935).withValues(alpha: 0.38);
      final bp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = maskCol;
      final fp = Paint()..color = maskCol;
      for (final b in [...vm.brush, if (vm.curBrush != null) vm.curBrush!]) {
        if (b.pts.length == 1) {
          canvas.drawCircle(b.pts.first, b.r, fp);
          continue;
        }
        final path = Path()..moveTo(b.pts.first.dx, b.pts.first.dy);
        for (final q in b.pts.skip(1)) {
          path.lineTo(q.dx, q.dy);
        }
        bp.strokeWidth = b.r * 2;
        canvas.drawPath(path, bp);
      }
    }

    final ring = Paint()..style = PaintingStyle.stroke;
    final fill = Paint()..style = PaintingStyle.fill;
    final badge = Paint()..color = Colors.black.withValues(alpha: 0.42);
    ring.strokeWidth = s.ringWidth * u;
    final st = s.markStyle;
    final filled = st == 0 || st == 1 || st == 3 || st == 4;
    final square = st == 1 || st == 4;
    final numbered = st >= 3 && s.showNumbers;
    final alpha = filled ? math.max(0.15, math.min(1.0, s.maskOpacity)) : s.maskOpacity * 0.2;
    var seq = -1;
    for (var i = 0; i < vm.markers.length; i++) {
      final m = vm.markers[i];
      if (vm.solo != null && m.sizeIdx != vm.solo) continue;
      seq++;
      final col = s.markColor(m.sizeIdx, seq);
      final c = Offset(m.x, m.y);
      fill.color = col.withValues(alpha: alpha);
      if (square) {
        final half = m.r * 0.88;
        final rr = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: half * 2, height: half * 2), Radius.circular(half * s.roundness));
        canvas.drawRRect(rr, fill);
        if (!filled) {
          ring.color = col;
          canvas.drawRRect(rr, ring);
        }
      } else {
        canvas.drawCircle(c, m.r, fill);
        if (!filled) {
          ring.color = col;
          canvas.drawCircle(c, m.r, ring);
        }
      }
      if (numbered) {
        final screenR = m.r / u;
        if (screenR >= minTextScreenR) {
          final fs = _fitFont(s.textSize, screenR);
          final base = filled ? (col.computeLuminance() > 0.55 ? Colors.black : Colors.white) : Colors.white;
          final tp = cache.get('${seq + 1}', base.withValues(alpha: s.labelOpacity), fs);
          if (!filled) canvas.drawCircle(c, math.min(m.r * 0.9, math.max(tp.width, tp.height) * 0.62 * u), badge);
          canvas.save();
          canvas.translate(m.x, m.y);
          canvas.scale(u);
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
          canvas.restore();
        }
      }
    }

    if (showRef && vm.refCenter != null && vm.refRadius > 0) {
      final c = vm.refCenter!, r = vm.refRadius;
      canvas.drawCircle(c, r, Paint()..color = Colors.yellowAccent.withValues(alpha: 0.10));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6 * u
          ..color = Colors.yellowAccent,
      );
      final cross = Paint()
        ..color = Colors.yellowAccent
        ..strokeWidth = 1.8 * u;
      canvas.drawLine(c - Offset(9 * u, 0), c + Offset(9 * u, 0), cross);
      canvas.drawLine(c - Offset(0, 9 * u), c + Offset(0, 9 * u), cross);
      // Pegangan ubah ukuran di 4 sisi
      final hp = Paint()..color = Colors.white;
      final hb = Paint()..color = Colors.amber.shade800;
      for (final d in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]) {
        final hc = c + d * r;
        canvas.drawCircle(hc, 8.5 * u, hb);
        canvas.drawCircle(hc, 6 * u, hp);
      }
    }

    if (vm.lineStart != null) {
      final ls = vm.lineStart!;
      canvas.drawCircle(ls, 9 * u, Paint()..color = Colors.redAccent.withValues(alpha: 0.9));
      canvas.drawCircle(
        ls,
        15 * u,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * u
          ..color = Colors.white,
      );
    }

    final all = [...vm.strokes, if (vm.cur != null) vm.cur!];
    for (var i = 0; i < all.length; i++) {
      final st = all[i];
      if (st.pts.isEmpty) continue;
      final path = Path()..moveTo(st.pts.first.dx, st.pts.first.dy);
      for (final q in st.pts.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = s.strokeWidth * u
          ..color = Colors.redAccent.withValues(alpha: 0.85),
      );
      final end = st.pts.last;
      canvas.drawCircle(end, 13 * u, Paint()..color = Colors.redAccent.shade700);
      final tp = cache.get('${i + 1}', Colors.white, 14);
      canvas.save();
      canvas.translate(end.dx, end.dy);
      canvas.scale(u);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant MarkerPainter old) => true;
}

// ============================================================
//  Layar hitung
// ============================================================

enum _RefDrag { none, move, resize }

class CountScreen extends StatefulWidget {
  final Uint8List bytes;
  const CountScreen({super.key, required this.bytes});
  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  final s = appSettings;
  final vm = _Vm();
  final _rp = _Ping();
  final _cache = _TextCache();
  late Uint8List _bytes = widget.bytes;
  ui.Image? _img;
  int mode = 1, active = 0;
  late int refIdx = s.refSizeIdx;
  final manual = <ManualEntry>[];
  bool busy = false, drawing = true, _fitted = false, _scanned = false, nestedOn = false;
  String busyMsg = '';
  Size _viewSize = Size.zero;
  double _lastScale = 0;

  // Patokan Tap-Match
  int _refSizeIdx = 5; // ukuran pipa yang sesuai dengan refRadius saat ini
  _RefDrag _refDrag = _RefDrag.none;
  Offset _grab = Offset.zero;
  final _ptrs = <int>{};
  bool _refLock = false;

  // Kuas masker: area yang TIDAK dihitung (bisa berbentuk bebas, tidak seperti crop)
  bool _maskTool = false, _maskPaint = true;
  double _brushPx = 44;
  Uint8List? _maskGrid;
  int _mw = 0, _mh = 0;
  double _mcell = 1;
  int? _penPtr;

  // Wizard Auto-All: pilih ukuran apa saja + 1 pipa contoh per ukuran
  List<int>? _wizSizes;
  int _wizStep = 0;
  final _wizRefs = <List<double>>[]; // [sizeIdx, x, y, r]
  List<List<double>> _lastRefs = [];
  bool get _wizActive => _wizSizes != null;
  bool _lineTool = false; // Coret: mode tap (tap titik awal, tap titik akhir)
  int _enh = 0; // kontras: 0 mati, 1 sedang, 2 kuat (tampilan + deteksi)
  final _history = <Uint8List>[]; // untuk urungkan edit foto (crop / luruskan)
  bool get _penMode => !busy && ((_maskTool && _maskPaint) || (!_maskTool && mode == 2 && drawing && !_lineTool));

  // Zoom/geser 2 jari saat pena aktif
  final _gp = <int, Offset>{};
  bool _pinch = false;
  Offset _pf0 = Offset.zero;
  double _pd0 = 1;
  final _canvasKey = GlobalKey();

  // Undo untuk Clear
  List<Marker>? _undoMarkers;
  List<ManualEntry>? _undoManual;

  final tc = TransformationController();
  final perCtl = TextEditingController(text: '8');
  final noteCtl = TextEditingController();
  String gudang = '', rak = '', level = '';

  List<Marker> get markers => vm.markers;
  List<Stroke> get strokes => vm.strokes;
  Offset? get refCenter => vm.refCenter;
  double get refRadius => vm.refRadius;
  double get _scale => math.max(1e-6, tc.value.entry(0, 0).abs());

  @override
  void initState() {
    super.initState();
    _refSizeIdx = active;
    tc.addListener(_onTc);
    s.addListener(_onSettings);
    _lastFilter = s.filterOutliers;
    _loadImage();
  }

  ScaffoldMessengerState? _sm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sm = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    _sm?.clearSnackBars();
    s.removeListener(_onSettings);
    tc.removeListener(_onTc);
    tc.dispose();
    perCtl.dispose();
    noteCtl.dispose();
    _rp.dispose();
    super.dispose();
  }

  bool _lastFilter = false;

  void _onSettings() {
    if (!mounted) return;
    if (s.filterOutliers != _lastFilter) {
      _lastFilter = s.filterOutliers;
      if (_lastFilter) {
        final auto = markers.where((m) => m.auto).toList();
        final kept = _filtered(auto);
        if (kept.length != auto.length) {
          markers.removeWhere((m) => m.auto);
          markers.addAll(kept);
          _snack('${auto.length - kept.length} objek menyimpang disaring');
        }
      }
    }
    setState(() {});
    _rp.ping();
  }

  /// Saring lingkaran yang ukurannya jauh dari median ukurannya atau terpencil dari yang lain.
  List<Marker> _filtered(List<Marker> ms) {
    if (!s.filterOutliers || ms.length < 6) return ms;
    final by = <int, List<Marker>>{};
    for (final m in ms) {
      by.putIfAbsent(m.sizeIdx, () => []).add(m);
    }
    final out = <Marker>[];
    for (final e in by.entries) {
      final rs = e.value.map((m) => m.r).toList()..sort();
      final med = rs[rs.length ~/ 2];
      for (final m in e.value) {
        if (m.r < 0.7 * med || m.r > 1.4 * med) continue;
        if (e.value.length >= 6) {
          var nb = false;
          for (final o in e.value) {
            if (!identical(o, m) && (Offset(o.x, o.y) - Offset(m.x, m.y)).distance <= 4.5 * med) {
              nb = true;
              break;
            }
          }
          if (!nb) continue;
        }
        out.add(m);
      }
    }
    return out;
  }

  // Gambar ulang overlay hanya jika skala berubah (geser saja tidak perlu).
  void _onTc() {
    final sc = _scale;
    if (_lastScale == 0 || (sc - _lastScale).abs() / _lastScale > 0.004) {
      _lastScale = sc;
      _rp.ping();
    }
  }

  Future<void> _loadImage() async {
    final c = await ui.instantiateImageCodec(_bytes);
    final f = await c.getNextFrame();
    if (!mounted) return;
    setState(() {
      _img = f.image;
      _fitted = false;
      vm.refRadius = math.min(f.image.width, f.image.height) * 0.04;
      vm.brush.clear();
      _maskGrid = null;
    });
  }

  String get rackLabel => [if (gudang.isNotEmpty) gudang, if (rak.isNotEmpty) 'Rak $rak', if (level.isNotEmpty) 'Tk $level'].join(' / ');

  List<int> _totals() {
    final t = List<int>.filled(kPipeSizes.length, 0);
    for (final m in markers) {
      t[m.sizeIdx]++;
    }
    for (final e in manual) {
      t[e.sizeIdx] += e.total;
    }
    return t;
  }

  void _feedback() {
    if (!s.haptic) return;
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
  }

  void _snack(String m, {SnackBarAction? action}) {
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(content: Text(m), action: action, persist: false, duration: Duration(seconds: action != null ? 5 : 3)));
  }

  void _setBusy(bool b, [String msg = '']) {
    if (!mounted) return;
    setState(() {
      busy = b;
      busyMsg = msg;
    });
  }

  // ---------- Tampilan ----------
  void _fitView() {
    final img = _img;
    if (img == null || _viewSize == Size.zero) return;
    final w = img.width.toDouble(), h = img.height.toDouble();
    final k = math.min(_viewSize.width / w, _viewSize.height / h) * 0.98;
    tc.value = Matrix4(k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1, 0, (_viewSize.width - w * k) / 2, (_viewSize.height - h * k) / 2, 0, 1);
  }

  void _zoomBy(double f) {
    final cx = _viewSize.width / 2, cy = _viewSize.height / 2;
    final m = Matrix4.identity()
      ..translate(cx, cy)
      ..scale(f, f, 1.0)
      ..translate(-cx, -cy);
    tc.value = m * tc.value;
  }

  // ---------- Backup untuk Urungkan ----------
  void _backup() {
    _undoMarkers = markers.map((m) => Marker(m.x, m.y, m.r, m.sizeIdx, m.auto)).toList();
    _undoManual = List.of(manual);
  }

  void _restore() {
    if (_undoMarkers == null) return;
    setState(() {
      markers
        ..clear()
        ..addAll(_undoMarkers!);
      manual
        ..clear()
        ..addAll(_undoManual ?? []);
    });
    _rp.ping();
  }

  // ---------- CLEAR ----------
  /// Mode Auto: hapus semua hasil deteksi. Tap-Match: hapus hitungan ukuran aktif & reset patokan
  /// supaya bisa langsung memilih ukuran lain. Coret: hapus coretan yang belum disimpan.
  void _clear() {
    _backup();
    setState(() {
      if (mode == 0) {
        markers.clear();
      } else if (mode == 1) {
        markers.removeWhere((m) => m.sizeIdx == active);
        vm.refCenter = null;
        vm.showRef = false;
        _scanned = false;
      } else {
        strokes.clear();
        vm.cur = null;
        manual.removeWhere((e) => e.sizeIdx == active);
      }
    });
    _rp.ping();
    _snack(
      mode == 0
          ? 'Semua penanda dihapus'
          : mode == 1
              ? 'Hitungan ${kPipeSizes[active]} dihapus. Pilih ukuran lain atau ketuk pipa untuk patokan baru.'
              : 'Coretan dibersihkan',
      action: SnackBarAction(label: 'Urungkan', onPressed: _restore),
    );
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hapus semua hasil?'),
        content: const Text('Semua penanda, coretan, dan hitungan semua ukuran akan dihapus.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Hapus Semua'))],
      ),
    );
    if (ok != true) return;
    _backup();
    setState(() {
      markers.clear();
      strokes.clear();
      manual.clear();
      vm.cur = null;
      vm.brush.clear();
      _maskGrid = null;
      vm.refCenter = null;
      vm.showRef = false;
      _scanned = false;
      _wizSizes = null;
    });
    _rp.ping();
    _snack('Semua hasil dihapus', action: SnackBarAction(label: 'Urungkan', onPressed: _restore));
  }

  ColorFilter? get _enhFilter {
    if (_enh == 0) return null;
    final c = _enh == 1 ? 1.25 : 1.6;
    final b = (1 - c) * 128;
    return ColorFilter.matrix([c, 0, 0, 0, b, 0, c, 0, 0, b, 0, 0, c, 0, b, 0, 0, 0, 1, 0]);
  }

  // ---------- CROP / LURUSKAN ----------
  Future<void> _recrop() async {
    if (markers.isNotEmpty || manual.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Crop ulang foto?'),
          content: const Text('Hasil hitungan saat ini akan dihapus karena posisi pipa berubah.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lanjut'))],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final out = await Navigator.push<Uint8List>(context, MaterialPageRoute(builder: (_) => CropScreen(bytes: _bytes)));
    if (out == null || !mounted) return;
    await _applyNewBytes(out);
  }

  /// Ganti foto kerja (hasil crop / luruskan): hasil hitungan lama dihapus karena posisi pipa berubah.
  Future<void> _applyNewBytes(Uint8List out) async {
    _history.add(_bytes);
    if (_history.length > 5) _history.removeAt(0);
    setState(() {
      _bytes = out;
      markers.clear();
      strokes.clear();
      manual.clear();
      vm.refCenter = null;
      vm.showRef = false;
      _scanned = false;
      _img = null;
      _lastRefs = [];
      _wizSizes = null;
    });
    await _loadImage();
  }

  Future<void> _straighten() async {
    if (markers.isNotEmpty || manual.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Luruskan foto?'),
          content: const Text('Hasil hitungan saat ini akan dihapus karena posisi pipa berubah.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lanjut'))],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final out = await Navigator.push<Uint8List>(context, MaterialPageRoute(builder: (_) => StraightenScreen(bytes: _bytes)));
    if (out == null || !mounted) return;
    await _applyNewBytes(out);
  }

  Future<void> _undoEdit() async {
    if (_history.isEmpty) return;
    final prev = _history.removeLast();
    setState(() {
      _bytes = prev;
      markers.clear();
      strokes.clear();
      manual.clear();
      vm.refCenter = null;
      vm.showRef = false;
      _scanned = false;
      _img = null;
      _lastRefs = [];
      _wizSizes = null;
    });
    await _loadImage();
  }

  /// Lembar "Perbaiki foto": crop, luruskan, kontras, urungkan.
  void _editSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, setSheet) {
        final cs = Theme.of(c).colorScheme;
        Widget tile(IconData i, String t, String sub, VoidCallback f) => ListTile(
              leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)), child: Icon(i, color: cs.onPrimaryContainer)),
              title: Text(t, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(c);
                f();
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            tile(Icons.crop, 'Crop area hitung', 'Pilih bagian foto yang akan dihitung', _recrop),
            tile(Icons.transform_rounded, 'Luruskan foto (perspektif)', 'Foto miring dibuat tampak depan agar bibir pipa bulat', _straighten),
            if (_history.isNotEmpty) tile(Icons.undo_rounded, 'Urungkan edit foto', 'Kembali ke foto sebelum crop / luruskan terakhir', _undoEdit),
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(children: [
                Icon(Icons.contrast_rounded, color: cs.primary),
                const SizedBox(width: 10),
                const Text('Kontras bibir pipa', style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Mempertegas tepi pipa pada tampilan dan pada analisis scan. Dianjurkan bila foto gelap, kusam, atau bibir pipa kurang jelas.', style: TextStyle(fontSize: 12, color: cs.outline)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Row(children: [
                for (final e in const [(0, 'Mati'), (1, 'Sedang'), (2, 'Kuat')])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(e.$2),
                      selected: _enh == e.$1,
                      onSelected: (_) {
                        setState(() => _enh = e.$1);
                        setSheet(() {});
                      },
                    ),
                  ),
              ]),
            ),
          ]),
        );
      }),
    );
  }

  // ---------- MODE 0: AUTO-ALL ----------
  Future<void> _runAuto() async {
    _setBusy(true, 'Mendeteksi semua pipa…');
    try {
      final cs = await compute(autoDetect, {'bytes': _bytes, 'p1': s.param1, 'p2': s.param2, 'nested': nestedOn, 'enh': _enh});
      markers.removeWhere((m) => m.auto);
      if (cs.isNotEmpty) {
        final idx = classifyRadii(cs.map((e) => e[2]).toList(), refIdx, kPipeOdMm);
        final add = <Marker>[for (var i = 0; i < cs.length; i++) Marker(cs[i][0], cs[i][1], cs[i][2], idx[i], true)];
        add.sort((a, b) => (a.y / 40).round() != (b.y / 40).round() ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
        final kept = _dropMasked(_filtered(add));
        markers.addAll(kept);
        vm.solo = null;
        _snack('${kept.length} pipa terdeteksi. Cek ukuran lalu koreksi dengan ketuk.');
      } else {
        _snack('Tidak ada pipa terdeteksi. Coba crop lebih dekat ke area pipa, atau turunkan "Sensitivitas deteksi" di Pengaturan.');
      }
    } catch (e) {
      _snack('Deteksi gagal: $e');
    }
    _rp.ping();
    _setBusy(false);
  }

  // ---------- MODE 1: TAP-MATCH ----------
  Future<void> _snapRef({bool silent = false}) async {
    final c = refCenter;
    if (c == null) return;
    _setBusy(true, 'Memaskan lingkaran ke bibir pipa…');
    try {
      final r = await compute(snapCircle, {'bytes': _bytes, 'x': c.dx, 'y': c.dy, 'r': vm.refRadius, 'p1': s.param1, 'enh': _enh});
      if (r.isNotEmpty && r[3] >= 0.45) {
        vm.refCenter = Offset(r[0], r[1]);
        vm.refRadius = r[2];
        _refSizeIdx = active;
        if (!silent) _snack('Lingkaran dipaskan ke bibir pipa');
      } else if (!silent) {
        _snack('Tepi pipa tidak terdeteksi. Geser lingkaran ke ujung pipa dan atur ukurannya, lalu coba lagi.');
      }
    } catch (e) {
      if (!silent) _snack('Gagal memaskan: $e');
    }
    _rp.ping();
    _setBusy(false);
  }

  Future<void> _scanByReference() async {
    final c = refCenter;
    if (c == null) {
      _snack('Ketuk satu pipa di foto untuk meletakkan lingkaran patokan.');
      return;
    }
    _setBusy(true, 'Memindai pipa ${kPipeSizes[active]}…');
    try {
      final res = await compute(scanFromReference, {
        'bytes': _bytes,
        'x': c.dx,
        'y': c.dy,
        'r': vm.refRadius,
        'tol': s.tolerance / 100,
        'p1': s.param1,
        'p2': s.param2,
        'uniform': s.uniformRadius,
        'snap': false,
        'enh': _enh,
      });
      final found = (res['found'] as List).map((e) => (e as List).cast<double>()).toList();
      markers.removeWhere((m) => m.auto && m.sizeIdx == active);
      final add = found.map((c) => Marker(c[0], c[1], c[2], active, true)).toList();
      final rc = vm.refCenter!;
      if (!add.any((m) => (Offset(m.x, m.y) - rc).distance < vm.refRadius * 0.7)) {
        add.add(Marker(rc.dx, rc.dy, vm.refRadius, active, true)); // lingkaran yang di-TAP tetap ada
      }
      add.sort((a, b) => (a.y / 40).round() != (b.y / 40).round() ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
      markers.addAll(_dropMasked(_filtered(add)));
      _scanned = true;
      vm.showRef = false;
      _refSizeIdx = active;
      _snack(add.length <= 1
          ? 'Hanya 1 pipa ditemukan. Pastikan lingkaran pas di bibir pipa (tekan "Pas-kan") atau naikkan toleransi di Pengaturan.'
          : 'Ditemukan ${add.length} pipa ukuran ${kPipeSizes[active]}');
    } catch (e) {
      _snack('Gagal memindai: $e');
    }
    _rp.ping();
    _setBusy(false);
  }

  // ---------- Kuas masker ----------
  void _rebuildMask() {
    final img = _img;
    if (img == null || vm.brush.isEmpty) {
      _maskGrid = null;
      return;
    }
    _mcell = math.max(1.0, math.max(img.width, img.height) / 700);
    _mw = (img.width / _mcell).ceil() + 1;
    _mh = (img.height / _mcell).ceil() + 1;
    final g = Uint8List(_mw * _mh);
    void stamp(Offset p, double r) {
      final cx = p.dx / _mcell, cy = p.dy / _mcell, rr = r / _mcell;
      final x0 = math.max(0, (cx - rr).floor()), x1 = math.min(_mw - 1, (cx + rr).ceil());
      final y0 = math.max(0, (cy - rr).floor()), y1 = math.min(_mh - 1, (cy + rr).ceil());
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          final dx = x - cx, dy = y - cy;
          if (dx * dx + dy * dy <= rr * rr) g[y * _mw + x] = 1;
        }
      }
    }

    for (final b in vm.brush) {
      stamp(b.pts.first, b.r);
      for (var i = 1; i < b.pts.length; i++) {
        final a = b.pts[i - 1], c = b.pts[i];
        final n = math.max(1, ((c - a).distance / math.max(1.0, b.r * 0.4)).ceil());
        for (var k = 1; k <= n; k++) {
          stamp(Offset.lerp(a, c, k / n)!, b.r);
        }
      }
    }
    _maskGrid = g;
  }

  bool _inMask(double x, double y) {
    final g = _maskGrid;
    if (g == null) return false;
    final gx = (x / _mcell).floor(), gy = (y / _mcell).floor();
    if (gx < 0 || gy < 0 || gx >= _mw || gy >= _mh) return false;
    return g[gy * _mw + gx] == 1;
  }

  /// Penanda dianggap di dalam masker jika pusat + minimal separuh titik lingkarnya tertutup kuas.
  bool _maskedMarker(Marker m) {
    if (_maskGrid == null) return false;
    var n = _inMask(m.x, m.y) ? 1 : 0;
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4;
      if (_inMask(m.x + math.cos(a) * m.r * 0.6, m.y + math.sin(a) * m.r * 0.6)) n++;
    }
    return n >= 4;
  }

  List<Marker> _dropMasked(List<Marker> ms) => _maskGrid == null ? ms : ms.where((m) => !_maskedMarker(m)).toList();

  void _maskUndo() {
    if (vm.brush.isEmpty) return;
    setState(() {
      vm.brush.removeLast();
      _rebuildMask();
    });
    _rp.ping();
  }

  void _maskClear() {
    setState(() {
      vm.brush.clear();
      _maskGrid = null;
    });
    _rp.ping();
  }

  // ---------- Pena langsung (coret & kuas) tanpa jeda awal ----------
  void _penStart(Offset p) {
    if (_maskTool) {
      vm.curBrush = _Brush([p], _brushPx / 2 / _scale);
    } else {
      vm.cur = Stroke([p]);
    }
    _rp.ping();
  }

  void _penMove(Offset p) {
    final minStep = 0.8 / _scale;
    if (_maskTool) {
      final b = vm.curBrush;
      if (b == null) return;
      if ((p - b.pts.last).distance >= minStep) {
        b.pts.add(p);
        _rp.ping();
      }
    } else {
      final st = vm.cur;
      if (st == null) return;
      if ((p - st.pts.last).distance >= minStep) {
        st.pts.add(p);
        _rp.ping();
      }
    }
  }

  void _penEnd() {
    if (_maskTool) {
      final b = vm.curBrush;
      vm.curBrush = null;
      if (b != null) {
        vm.brush.add(b);
        _rebuildMask();
        final before = markers.length;
        markers.removeWhere(_maskedMarker);
        final removed = before - markers.length;
        setState(() {});
        if (removed > 0) _snack('$removed penanda di area masker dihapus');
      }
    } else {
      setState(() {
        if (vm.cur != null && vm.cur!.pts.length > 1) {
          strokes.add(vm.cur!);
          _feedback();
        }
        vm.cur = null;
      });
    }
    _rp.ping();
  }

  // ---------- Wizard Auto-All: pilih ukuran + contoh ----------
  Future<void> _startWizard() async {
    final sel = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SizePickSheet(initial: _lastRefs.map((e) => e[0].round()).toList(), st: s),
    );
    if (sel == null || sel.isEmpty || !mounted) return;
    sel.sort((a, b) => kPipeOdMm[b].compareTo(kPipeOdMm[a])); // terbesar dulu
    setState(() {
      _wizSizes = sel;
      _wizStep = 0;
      _wizRefs.clear();
      active = sel[0];
      _refSizeIdx = sel[0];
      vm.refCenter = null;
      vm.showRef = false;
      _scanned = false;
    });
    _rp.ping();
  }

  void _wizNext() {
    final c = vm.refCenter;
    if (c == null) {
      _snack('Ketuk 1 pipa ukuran ${kPipeSizes[active]} dulu.');
      return;
    }
    _wizRefs.add([active.toDouble(), c.dx, c.dy, vm.refRadius]);
    final sizes = _wizSizes!;
    if (_wizStep >= sizes.length - 1) {
      _runMulti();
      return;
    }
    final cur = active, next = sizes[_wizStep + 1];
    setState(() {
      _wizStep++;
      active = next;
      vm.refRadius = (vm.refRadius * kPipeOdMm[next] / kPipeOdMm[cur]).clamp(6.0, math.min(_img!.width, _img!.height) * 0.45);
      _refSizeIdx = next;
      vm.refCenter = null;
      vm.showRef = false;
    });
    _rp.ping();
  }

  void _wizBack() {
    if (_wizStep == 0 || _wizRefs.isEmpty) return;
    final last = _wizRefs.removeLast();
    setState(() {
      _wizStep--;
      active = _wizSizes![_wizStep];
      vm.refCenter = Offset(last[1], last[2]);
      vm.refRadius = last[3];
      vm.showRef = true;
      _refSizeIdx = active;
    });
    _rp.ping();
  }

  void _wizCancel() {
    setState(() {
      _wizSizes = null;
      _wizRefs.clear();
      vm.refCenter = null;
      vm.showRef = false;
    });
    _rp.ping();
  }

  Future<void> _runMulti({List<List<double>>? refs}) async {
    final use = refs ?? _wizRefs.map((e) => [...e]).toList();
    if (use.isEmpty) return;
    _setBusy(true, 'Mendeteksi ${use.length} ukuran pipa…');
    try {
      final res = await compute(scanMulti, {'bytes': _bytes, 'refs': use, 'tol': s.tolerance / 100, 'p1': s.param1, 'p2': s.param2, 'uniform': s.uniformRadius, 'snap': false, 'enh': _enh});
      final outRefs = (res['refs'] as List).map((e) => (e as List).cast<double>()).toList();
      final found = (res['found'] as List).map((e) => (e as List).cast<double>()).toList();
      final sizes = use.map((e) => e[0].round()).toSet();
      markers.removeWhere((m) => m.auto && sizes.contains(m.sizeIdx));
      var add = <Marker>[for (final f in found) Marker(f[0], f[1], f[2], f[4].round(), true)];
      add.sort((a, b) => (a.y / 40).round() != (b.y / 40).round() ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
      add = _dropMasked(_filtered(add));
      markers.addAll(add);
      _lastRefs = outRefs.map((e) => e.sublist(0, 4)).toList();
      final per = <int, int>{};
      for (final m in add) {
        per[m.sizeIdx] = (per[m.sizeIdx] ?? 0) + 1;
      }
      final order = sizes.toList()..sort((a, b) => kPipeOdMm[a].compareTo(kPipeOdMm[b]));
      _snack('Selesai: ${order.map((i) => '${kPipeSizes[i]} = ${per[i] ?? 0}').join('  •  ')}');
      _wizSizes = null;
      _wizRefs.clear();
      vm.showRef = false;
      vm.refCenter = null;
      active = order.last;
      vm.solo = null;
    } catch (e) {
      _snack('Deteksi gagal: $e');
    }
    _rp.ping();
    _setBusy(false);
  }

  // ---------- Gestur patokan (geser / ubah ukuran) ----------
  bool get _refEditable => ((mode == 1 && !_scanned) || _wizActive) && vm.refCenter != null;

  Offset _canvasOrigin() {
    final ro = _canvasKey.currentContext?.findRenderObject();
    return ro is RenderBox ? ro.localToGlobal(Offset.zero) : Offset.zero;
  }

  /// Zoom + geser memakai dua jari (dipakai saat mode pena mengunci InteractiveViewer).
  void _applyPinch(Offset f0, Offset f1, double k) {
    final cur = _scale;
    final target = math.min(30.0, math.max(0.05, cur * k));
    final kk = target / cur;
    final o = _canvasOrigin();
    final v0 = f0 - o, v1 = f1 - o;
    final m = Matrix4.identity()
      ..translate(v1.dx, v1.dy)
      ..scale(kk, kk, 1.0)
      ..translate(-v0.dx, -v0.dy);
    tc.value = m * tc.value;
  }

  void _ptrDown(PointerDownEvent e) {
    _ptrs.add(e.pointer);
    _gp[e.pointer] = e.position;
    if (_ptrs.length > 1) {
      _endRefDrag();
      if (_penMode || _penPtr != null) {
        // dua jari: batalkan coretan yang sedang berjalan, lalu zoom/geser
        vm.cur = null;
        vm.curBrush = null;
        _penPtr = null;
        _pinch = true;
        final pts = _gp.values.take(2).toList();
        _pf0 = (pts[0] + pts[1]) / 2;
        _pd0 = math.max(1.0, (pts[0] - pts[1]).distance);
        _rp.ping();
      }
      return;
    }
    if (busy) return;
    if (_penMode) {
      _penPtr = e.pointer;
      _penStart(e.localPosition);
      return;
    }
    if (!_refEditable) return;
    final c = vm.refCenter!, r = vm.refRadius;
    final u = 1 / _scale;
    final d = (e.localPosition - c).distance;
    final tol = 30 * u;
    _RefDrag h = _RefDrag.none;
    if (d <= r * 0.62) {
      h = _RefDrag.move;
    } else if ((d - r).abs() <= tol) {
      h = _RefDrag.resize;
    } else if (d < r) {
      h = _RefDrag.move;
    }
    if (h == _RefDrag.none) return;
    _refDrag = h;
    _grab = e.localPosition - c;
    if (!_refLock) setState(() => _refLock = true);
  }

  void _ptrMove(PointerMoveEvent e) {
    _gp[e.pointer] = e.position;
    if (_pinch && _gp.length >= 2) {
      final pts = _gp.values.take(2).toList();
      final f1 = (pts[0] + pts[1]) / 2;
      final d1 = math.max(1.0, (pts[0] - pts[1]).distance);
      _applyPinch(_pf0, f1, d1 / _pd0);
      _pf0 = f1;
      _pd0 = d1;
      return;
    }
    if (_penPtr == e.pointer) {
      _penMove(e.localPosition);
      return;
    }
    if (_refDrag == _RefDrag.none || _ptrs.length != 1 || vm.refCenter == null) return;
    final img = _img!;
    if (_refDrag == _RefDrag.move) {
      vm.refCenter = Offset((e.localPosition.dx - _grab.dx).clamp(0.0, img.width.toDouble()), (e.localPosition.dy - _grab.dy).clamp(0.0, img.height.toDouble()));
    } else {
      final maxR = math.min(img.width, img.height) * 0.5;
      vm.refRadius = (e.localPosition - vm.refCenter!).distance.clamp(5.0, maxR);
    }
    _rp.ping();
  }

  void _ptrUp(PointerEvent e) {
    _ptrs.remove(e.pointer);
    _gp.remove(e.pointer);
    if (_ptrs.length < 2) _pinch = false;
    if (_penPtr == e.pointer) {
      _penPtr = null;
      _penEnd();
    }
    if (_ptrs.isEmpty) _endRefDrag();
  }

  void _endRefDrag() {
    if (_refDrag != _RefDrag.none || _refLock) {
      _refDrag = _RefDrag.none;
      if (mounted) setState(() => _refLock = false);
    }
  }

  // ---------- Tap & koreksi ----------
  Future<void> _onTap(Offset pt) async {
    if (busy || _maskTool) return;
    if (mode == 2) {
      if (_lineTool) {
        setState(() {
          if (vm.lineStart == null) {
            vm.lineStart = pt;
          } else {
            strokes.add(Stroke([vm.lineStart!, pt]));
            vm.lineStart = null;
            _feedback();
          }
        });
        _rp.ping();
      }
      return;
    }

    if ((mode == 1 && !_scanned) || _wizActive) {
      // Ketuk di dalam lingkaran patokan = tidak apa-apa (itu area geser)
      if (vm.refCenter != null && (pt - vm.refCenter!).distance <= vm.refRadius + 30 / _scale) return;
      final first = vm.refCenter == null;
      setState(() {
        vm.refCenter = pt;
        vm.showRef = true;
        if (first) {
          final img = _img!;
          vm.refRadius = vm.refRadius.clamp(8.0, math.min(img.width, img.height) * 0.3);
        }
      });
      _rp.ping();
      _feedback();
      await _snapRef(silent: true); // langsung paskan ke bibir pipa
      return;
    }

    var hit = -1;
    var best = double.infinity;
    for (var i = 0; i < markers.length; i++) {
      final m = markers[i];
      if (vm.solo != null && m.sizeIdx != vm.solo) continue;
      final d = (Offset(m.x, m.y) - pt).distance;
      if (d <= m.r && m.r < best) {
        best = m.r;
        hit = i;
      }
    }
    setState(() {
      if (hit >= 0) {
        markers.removeAt(hit);
      } else {
        final same = markers.where((m) => m.sizeIdx == active).toList();
        final r = same.isNotEmpty ? same.map((m) => m.r).reduce((a, b) => a + b) / same.length : vm.refRadius;
        markers.add(Marker(pt.dx, pt.dy, r, active, false));
      }
    });
    _rp.ping();
    _feedback();
  }

  void _pickSize(int i) {
    setState(() {
      if (mode == 0) vm.solo = i;
      if (mode == 1 && i != active) {
        // Skala radius patokan ke ukuran baru agar tebakan awal mendekati
        vm.refRadius = (vm.refRadius * kPipeOdMm[i] / kPipeOdMm[_refSizeIdx]).clamp(6.0, math.min(_img!.width, _img!.height) * 0.45);
        _refSizeIdx = i;
        vm.refCenter = null;
        vm.showRef = false;
        _scanned = false;
      }
      active = i;
    });
    _rp.ping();
  }

  // ---------- Rak ----------
  Future<void> _rackSheet() async {
    final g = TextEditingController(text: gudang), r = TextEditingController(text: rak), l = TextEditingController(text: level);
    final gs = await Db.racks('gudang'), rs = await Db.racks('rak'), ls = await Db.racks('level');
    if (!mounted) return;
    Widget field(String label, TextEditingController c, List<Map<String, Object?>> o) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 10),
          TextField(controller: c, decoration: InputDecoration(labelText: label)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [for (final x in o) ActionChip(label: Text('${x['nilai']}'), onPressed: () => c.text = '${x['nilai']}')]),
        ]);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom, left: 16, right: 16, top: 4),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Posisi Rak', style: Theme.of(c).textTheme.titleLarge),
            field('Kode Gudang', g, gs),
            field('Nomor Rak', r, rs),
            field('Tingkat / Level', l, ls),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Simpan Posisi'))),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
    setState(() {
      gudang = g.text.trim();
      rak = r.text.trim();
      level = l.text.trim();
    });
  }

  // ---------- Render & simpan ----------
  void _watermark(Canvas c, double w, double h, double u, DateTime now) {
    final t = _totals();
    final lines = <String>[
      'Rak: ${rackLabel.isEmpty ? "-" : rackLabel}',
      DateFormat('dd/MM/yyyy HH:mm').format(now),
      for (var i = 0; i < t.length; i++)
        if (t[i] > 0) '${kPipeSizes[i]} : ${t[i]} btg',
      'TOTAL: ${t.fold<int>(0, (a, b) => a + b)} btg',
    ];
    final tps = lines.map((l) => TextPainter(text: TextSpan(text: l, style: TextStyle(color: Colors.white, fontSize: 14 * u, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout()).toList();
    final pad = 8 * u;
    final bw = tps.map((e) => e.width).reduce(math.max) + pad * 2;
    final bh = tps.fold<double>(0, (a, e) => a + e.height) + pad * 2;
    final top = h - bh - pad;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(pad, top, bw, bh), Radius.circular(pad)), Paint()..color = Colors.black.withValues(alpha: 0.65));
    var y = top + pad;
    for (final tp in tps) {
      tp.paint(c, Offset(pad * 2, y));
      y += tp.height;
    }
  }

  Future<Uint8List> _render(DateTime now) async {
    final w = _img!.width.toDouble(), h = _img!.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(_img!, Offset.zero, Paint());
    final u = math.max(w, h) / 800;
    final savedSolo = vm.solo;
    vm.solo = null; // foto simpanan selalu memuat semua ukuran
    MarkerPainter.draw(c, vm, s, _TextCache(), u, minTextScreenR: 4, showRef: false);
    vm.solo = savedSolo;
    if (s.watermark) _watermark(c, w, h, u, now);
    final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  Future<void> _save() async {
    final totals = _totals();
    final total = totals.fold<int>(0, (a, b) => a + b);
    if (total == 0) return _snack('Belum ada hasil hitungan untuk disimpan.');
    if (rackLabel.isEmpty) await _rackSheet();
    _setBusy(true, 'Menyimpan…');
    try {
      final now = DateTime.now();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(now);
      final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'camcount'))..createSync(recursive: true);
      final isPng = _bytes.length > 4 && _bytes[0] == 0x89 && _bytes[1] == 0x50;
      final orig = File(p.join(dir.path, 'asli_$ts.${isPng ? 'png' : 'jpg'}'))..writeAsBytesSync(_bytes);
      final ann = File(p.join(dir.path, 'bertanda_$ts.png'))..writeAsBytesSync(await _render(now));
      try {
        await Gal.putImage(ann.path);
      } catch (_) {}

      final details = <Map<String, Object?>>[];
      final autoCount = List<int>.filled(kPipeSizes.length, 0);
      for (final m in markers) {
        autoCount[m.sizeIdx]++;
      }
      for (var i = 0; i < autoCount.length; i++) {
        if (autoCount[i] > 0) details.add({'ukuran_pipa': kPipeSizes[i], 'jumlah_batang': autoCount[i], 'detail_rumus': null});
      }
      for (final e in manual) {
        details.add({'ukuran_pipa': kPipeSizes[e.sizeIdx], 'jumlah_batang': e.total, 'detail_rumus': e.formula});
      }
      await Db.insertSession({
        'tanggal_jam': DateFormat('yyyy-MM-dd HH:mm:ss').format(now),
        'posisi_rak': rackLabel,
        'mode_hitung': kModeNames[mode],
        'total_semua_pipa': total,
        'path_foto_asli': orig.path,
        'path_foto_bertanda': ann.path,
        'catatan': noteCtl.text.trim(),
      }, details);
      if (!mounted) return;
      _snack('Tersimpan: $total batang');
      Navigator.pop(context);
    } catch (e) {
      _snack('Gagal menyimpan: $e');
      _setBusy(false);
    }
  }

  // ============================================================
  //  UI
  // ============================================================

  Widget _canvas() {
    final img = _img!;
    final w = img.width.toDouble(), h = img.height.toDouble();
    return LayoutBuilder(builder: (ctx, box) {
      _viewSize = Size(box.maxWidth, box.maxHeight);
      if (!_fitted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _fitted) return;
          _fitView();
          _fitted = true;
          _lastScale = _scale;
          _rp.ping();
        });
      }
      final lock = _penMode || _refLock;
      return ClipRect(
        key: _canvasKey,
        child: InteractiveViewer(
          transformationController: tc,
          constrained: false,
          minScale: 0.05,
          maxScale: 30,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          panEnabled: !lock,
          scaleEnabled: !lock,
          child: SizedBox(
            width: w,
            height: h,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _ptrDown,
              onPointerMove: _ptrMove,
              onPointerUp: _ptrUp,
              onPointerCancel: _ptrUp,
              child: GestureDetector(
                onTapUp: (d) => _onTap(d.localPosition),
                child: Stack(children: [
                  RepaintBoundary(child: _enhFilter == null ? RawImage(image: img, width: w, height: h, fit: BoxFit.fill, filterQuality: FilterQuality.low) : ColorFiltered(colorFilter: _enhFilter!, child: RawImage(image: img, width: w, height: h, fit: BoxFit.fill, filterQuality: FilterQuality.low))),
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(isComplex: true, painter: MarkerPainter(vm: vm, s: s, tc: tc, cache: _cache, repaint: _rp)),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _roundBtn(IconData i, String tip, VoidCallback f, {bool active = false}) => Material(
        color: active ? const Color(0xFFE53935) : Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: IconButton(icon: Icon(i, color: Colors.white, size: 20), tooltip: tip, onPressed: f, visualDensity: VisualDensity.compact),
      );

  Widget _hint(String t) => Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(20)),
        child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  String get _hintText {
    if (_maskTool) return _maskPaint ? 'Warnai area yang TIDAK dihitung' : 'Mode geser / zoom';
    if (_wizActive) return vm.refCenter == null ? 'Langkah ${_wizStep + 1}/${_wizSizes!.length}: ketuk 1 pipa ${kPipeSizes[active]}' : 'Geser lingkaran, tarik tepinya untuk ukuran';
    if (mode == 0) return 'Pilih ukuran & contoh pipa, lalu deteksi';
    if (mode == 1) {
      if (_scanned) return 'Ketuk foto untuk tambah / hapus penanda';
      if (refCenter == null) return 'Ketuk 1 ujung pipa ${kPipeSizes[active]}';
      return 'Geser lingkaran, tarik tepinya untuk ukuran';
    }
    if (_lineTool) return vm.lineStart == null ? 'Tap titik AWAL garis  •  2 jari = zoom/geser' : 'Tap titik AKHIR garis';
    return 'Coret pipa satu per satu  •  2 jari = zoom/geser';
  }

  Widget _sizeBar() {
    final t = _totals();
    final cs = Theme.of(context).colorScheme;
    final total = t.fold<int>(0, (a, b) => a + b);
    final off = mode == 0 ? 1 : 0; // Auto-All: chip "Semua" di depan
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kPipeSizes.length + off,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, k) {
          if (off == 1 && k == 0) {
            return ChoiceChip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.layers_rounded, size: 16),
              label: Text('Semua  •  $total'),
              labelStyle: TextStyle(fontWeight: FontWeight.w800, color: vm.solo == null ? cs.onSecondaryContainer : cs.onSurface),
              selected: vm.solo == null,
              onSelected: (_) {
                setState(() => vm.solo = null);
                _rp.ping();
              },
            );
          }
          final i = k - off;
          return ChoiceChip(
            visualDensity: VisualDensity.compact,
            avatar: CircleAvatar(backgroundColor: s.colorOf(i), radius: 7),
            label: Text(t[i] > 0 ? '${kPipeSizes[i]}  •  ${t[i]}' : kPipeSizes[i]),
            labelStyle: TextStyle(fontWeight: FontWeight.w800, color: (mode == 0 ? vm.solo == i : active == i) ? cs.onSecondaryContainer : cs.onSurface),
            selected: mode == 0 ? vm.solo == i : active == i,
            onSelected: (_) => _pickSize(i),
          );
        },
      ),
    );
  }

  Widget _maskPanel() {
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(Icons.brush, color: cs.error, size: 20),
        const SizedBox(width: 8),
        const Expanded(child: Text('Kuas masker: warnai pipa yang TIDAK dihitung', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5))),
        FilledButton(onPressed: () => setState(() => _maskTool = false), style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 16)), child: const Text('Selesai')),
      ]),
      Row(children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _maskPaint ? 'Kuas aktif (ketuk untuk geser/zoom)' : 'Geser/zoom aktif (ketuk untuk kuas)',
          onPressed: () => setState(() => _maskPaint = !_maskPaint),
          icon: Icon(_maskPaint ? Icons.brush : Icons.pan_tool),
        ),
        IconButton(visualDensity: VisualDensity.compact, tooltip: 'Urungkan kuas', onPressed: vm.brush.isEmpty ? null : _maskUndo, icon: const Icon(Icons.undo)),
        const Icon(Icons.circle, size: 10),
        Expanded(child: Slider(value: _brushPx, min: 12, max: 120, onChanged: (v) => setState(() => _brushPx = v))),
        const Icon(Icons.circle, size: 22),
        SizedBox(width: 34, child: Text('${_brushPx.round()}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
        IconButton(visualDensity: VisualDensity.compact, tooltip: 'Hapus semua masker', onPressed: vm.brush.isEmpty ? null : _maskClear, icon: const Icon(Icons.delete_sweep_outlined)),
      ]),
    ]);
  }

  Widget _refSliderRow() {
    final maxR = _img != null ? math.min(_img!.width, _img!.height) * 0.3 : 250.0;
    return ListenableBuilder(
      listenable: _rp,
      builder: (_, __) => Row(children: [
        IconButton(visualDensity: VisualDensity.compact, onPressed: () { vm.refRadius = math.max(5, vm.refRadius - 1); _rp.ping(); }, icon: const Icon(Icons.remove_circle_outline)),
        Expanded(
          child: Slider(
            value: vm.refRadius.clamp(5.0, maxR),
            min: 5,
            max: maxR,
            onChanged: (v) {
              vm.refRadius = v;
              _rp.ping();
            },
          ),
        ),
        IconButton(visualDensity: VisualDensity.compact, onPressed: () { vm.refRadius = math.min(maxR, vm.refRadius + 1); _rp.ping(); }, icon: const Icon(Icons.add_circle_outline)),
        SizedBox(width: 58, child: Text('Ø ${(vm.refRadius * 2).round()}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ]),
    );
  }

  Widget _wizPanel() {
    final sizes = _wizSizes!;
    final last = _wizStep >= sizes.length - 1;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        CircleAvatar(radius: 8, backgroundColor: s.colorOf(active)),
        const SizedBox(width: 8),
        Expanded(child: Text('Langkah ${_wizStep + 1}/${sizes.length}: ketuk 1 pipa ukuran ${kPipeSizes[active]}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
        TextButton(onPressed: _wizCancel, child: const Text('Batal')),
      ]),
      if (refCenter == null)
        const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(bottom: 4), child: Text('Lingkaran otomatis dipaskan ke bibir pipa. Geser atau tarik tepinya bila kurang pas.', style: TextStyle(fontSize: 12))))
      else ...[
        _refSliderRow(),
        Row(children: [
          if (_wizStep > 0) ...[OutlinedButton(onPressed: busy ? null : _wizBack, child: const Icon(Icons.arrow_back, size: 18)), const SizedBox(width: 8)],
          OutlinedButton.icon(onPressed: busy ? null : () => _snapRef(), icon: const Icon(Icons.gps_fixed, size: 18), label: const Text('Pas-kan')),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.icon(onPressed: busy ? null : _wizNext, icon: Icon(last ? Icons.search : Icons.arrow_forward, size: 18), label: Text(last ? 'Mulai deteksi' : 'Berikutnya'))),
        ]),
      ],
    ]);
  }

  Widget _modePanel() {
    if (_maskTool) return _maskPanel();
    if (_wizActive) return _wizPanel();
    if (mode == 0) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _startWizard,
            icon: const Icon(Icons.checklist_rounded, size: 20),
            label: Text(_lastRefs.isEmpty ? 'Pilih ukuran & contoh pipa' : 'Ulangi: pilih ukuran & contoh pipa'),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
          const Text('Otomatis penuh, terbesar:', style: TextStyle(fontSize: 12)),
          DropdownButton<int>(
            value: refIdx,
            isDense: true,
            items: [for (var i = 0; i < kPipeSizes.length; i++) DropdownMenuItem(value: i, child: Text(kPipeSizes[i]))],
            onChanged: (v) => setState(() => refIdx = v!),
          ),
          FilterChip(visualDensity: VisualDensity.compact, label: const Text('Bersarang'), selected: nestedOn, onSelected: (v) => setState(() => nestedOn = v)),
          OutlinedButton(onPressed: busy ? null : _runAuto, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 14)), child: const Text('Deteksi')),
        ]),
      ]);
    }
    if (mode == 1) {
      if (_scanned) {
        return Row(children: [
          Expanded(child: ListenableBuilder(listenable: _rp, builder: (_, __) => Text('Patokan Ø ${(vm.refRadius * 2).round()} px  (±${s.tolerance.round()}%)', style: const TextStyle(fontSize: 12)))),
          TextButton.icon(
            onPressed: () => setState(() {
              _scanned = false;
              vm.showRef = vm.refCenter != null;
            }),
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Atur ulang patokan'),
          ),
        ]);
      }
      final maxR = _img != null ? math.min(_img!.width, _img!.height) * 0.3 : 250.0;
      if (refCenter == null) {
        return Row(children: [
          Icon(Icons.touch_app, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text('Ketuk 1 ujung pipa ${kPipeSizes[active]} di foto. Lingkaran akan otomatis dipaskan ke bibir pipa.', style: const TextStyle(fontSize: 12))),
        ]);
      }
      return Column(mainAxisSize: MainAxisSize.min, children: [
        ListenableBuilder(
          listenable: _rp,
          builder: (_, __) => Row(children: [
            IconButton(visualDensity: VisualDensity.compact, onPressed: () { vm.refRadius = math.max(5, vm.refRadius - 1); _rp.ping(); }, icon: const Icon(Icons.remove_circle_outline)),
            Expanded(
              child: Slider(
                value: vm.refRadius.clamp(5.0, maxR),
                min: 5,
                max: maxR,
                onChanged: (v) {
                  vm.refRadius = v;
                  _rp.ping();
                },
              ),
            ),
            IconButton(visualDensity: VisualDensity.compact, onPressed: () { vm.refRadius = math.min(maxR, vm.refRadius + 1); _rp.ping(); }, icon: const Icon(Icons.add_circle_outline)),
            SizedBox(width: 58, child: Text('Ø ${(vm.refRadius * 2).round()}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          ]),
        ),
        Row(children: [
          OutlinedButton.icon(onPressed: busy ? null : () => _snapRef(), icon: const Icon(Icons.gps_fixed, size: 18), label: const Text('Pas-kan')),
          const SizedBox(width: 10),
          Expanded(child: FilledButton.icon(onPressed: busy ? null : _scanByReference, icon: const Icon(Icons.search, size: 18), label: Text('Scan ukuran ${kPipeSizes[active]}'))),
        ]),
      ]);
    }
    final total = (int.tryParse(perCtl.text) ?? 0) * strokes.length;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.gesture, size: 16), label: Text('Bebas')),
              ButtonSegment(value: 1, icon: Icon(Icons.touch_app, size: 16), label: Text('Tap-Tap')),
            ],
            selected: {_lineTool ? 1 : 0},
            onSelectionChanged: (v) => setState(() {
              _lineTool = v.first == 1;
              drawing = !_lineTool;
              vm.lineStart = null;
              vm.cur = null;
            }),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Urungkan',
          onPressed: (strokes.isEmpty && vm.lineStart == null)
              ? null
              : () {
                  setState(() {
                    if (vm.lineStart != null) {
                      vm.lineStart = null;
                    } else {
                      strokes.removeLast();
                    }
                  });
                  _rp.ping();
                },
          icon: const Icon(Icons.undo),
        ),
      ]),
      Row(children: [
        Text('${strokes.length} x'),
        const SizedBox(width: 4),
        SizedBox(width: 50, child: TextField(controller: perCtl, keyboardType: TextInputType.number, textAlign: TextAlign.center, onChanged: (_) => setState(() {}), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)))),
        Text(' = $total'),
        const Spacer(),
        FilledButton(
          onPressed: total > 0
              ? () {
                  setState(() {
                    manual.add(ManualEntry(active, strokes.length, int.parse(perCtl.text)));
                    strokes.clear();
                    vm.lineStart = null;
                  });
                  _rp.ping();
                }
              : null,
          child: Text('Simpan ${kPipeSizes[active]}'),
        ),
      ]),
    ]);
  }

  Widget _actionBtn(IconData i, String label, VoidCallback? f, {Color? color, bool primary = false}) {
    final cs = Theme.of(context).colorScheme;
    final c = f == null ? cs.outlineVariant : (color ?? (primary ? cs.primary : cs.onSurfaceVariant));
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: f,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 44,
              height: 38,
              decoration: primary && f != null ? BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(14)) : null,
              child: Icon(i, size: 25, color: primary && f != null ? Colors.white : c),
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: c)),
          ]),
        ),
      ),
    );
  }

  Widget _rackRow() {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _rackSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.edit_note_rounded, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rackLabel.isEmpty ? 'Tambah posisi rak (mis. Gudang A / Rak 10)' : rackLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: rackLabel.isEmpty ? FontWeight.w500 : FontWeight.w800, color: rackLabel.isEmpty ? cs.outline : cs.onSurface),
            ),
          ),
          Icon(Icons.chevron_right, size: 20, color: cs.outline),
        ]),
      ),
    );
  }

  Future<void> _retake() async {
    if (markers.isNotEmpty || manual.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Ambil foto ulang?'),
          content: const Text('Hasil hitungan pada foto ini belum disimpan dan akan hilang.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ambil Ulang'))],
        ),
      );
      if (ok != true) return;
    }
    if (mounted) Navigator.pop(context, 'retake');
  }

  /// Ulangi deteksi sesuai mode aktif.
  void _redo() {
    if (mode == 0) {
      if (_wizActive) {
        _wizNext();
      } else if (_lastRefs.isNotEmpty) {
        _runMulti(refs: _lastRefs);
      } else {
        _startWizard();
      }
    } else if (mode == 1) {
      if (refCenter != null) {
        _scanByReference();
      } else {
        _snack('Ketuk 1 ujung pipa dulu untuk patokan.');
      }
    } else {
      _snack('Mode Coret tidak memakai deteksi otomatis.');
    }
  }

  void _detail() {
    final t = _totals();
    final total = t.fold<int>(0, (a, b) => a + b);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rincian hitungan'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (var i = 0; i < t.length; i++)
              if (t[i] > 0)
                ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: CircleAvatar(backgroundColor: s.colorOf(i), radius: 8), title: Text(kPipeSizes[i]), trailing: Text('${t[i]} btg', style: const TextStyle(fontWeight: FontWeight.w800))),
            if (manual.isNotEmpty) const Divider(),
            for (final e in manual) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('Coret ${kPipeSizes[e.sizeIdx]}'), trailing: Text(e.formula, style: const TextStyle(fontSize: 12))),
            const Divider(),
            ListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.w900)), trailing: Text('$total btg', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Tutup'))],
      ),
    );
  }

  Widget _panel() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _rackRow(),
            const SizedBox(height: 8),
            if (!_wizActive && !_maskTool) ...[_sizeBar(), const SizedBox(height: 6)],
            _modePanel(),
            if (manual.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 6, children: [
                  for (var i = 0; i < manual.length; i++)
                    InputChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${kPipeSizes[manual[i].sizeIdx]}: ${manual[i].formula}', style: const TextStyle(fontSize: 11)),
                      onDeleted: () => setState(() => manual.removeAt(i)),
                    ),
                ]),
              ),
            const Divider(height: 14),
            Row(children: [
              _actionBtn(Icons.replay_rounded, 'Ulang', busy ? null : _retake),
              _actionBtn(Icons.layers_clear_outlined, 'Clear', busy ? null : _clear, color: cs.error),
              _actionBtn(Icons.palette_outlined, 'Gaya', () => showMarkerStyleSheet(context)),
              _actionBtn(Icons.list_alt_rounded, 'Detail', _detail),
              _actionBtn(Icons.save_alt_rounded, 'Simpan', busy ? null : _save, primary: true),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: _rp,
          builder: (_, __) {
            final total = _totals().fold<int>(0, (a, b) => a + b);
            final cs = Theme.of(context).colorScheme;
            return Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text('Total ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.outline)),
              Text('$total', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, height: 1.0)),
            ]);
          },
        ),
        actions: [
          IconButton(tooltip: 'Deteksi ulang', onPressed: busy ? null : _redo, icon: const Icon(Icons.refresh_rounded)),
          IconButton(tooltip: 'Perbaiki foto (crop, luruskan, kontras)', onPressed: busy || _img == null ? null : _editSheet, icon: Badge(isLabelVisible: _enh > 0 || _history.isNotEmpty, smallSize: 8, child: const Icon(Icons.auto_fix_high_rounded))),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'all') _clearAll();
              if (v == 'fit') _fitView();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'fit', child: Text('Pas-kan tampilan foto')),
              PopupMenuItem(value: 'all', child: Text('Hapus semua hasil')),
            ],
          ),
        ],
      ),
      body: _img == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 0, icon: Icon(Icons.auto_awesome, size: 16), label: Text('Auto-All')),
                      ButtonSegment(value: 1, icon: Icon(Icons.ads_click, size: 16), label: Text('Tap-Match')),
                      ButtonSegment(value: 2, icon: Icon(Icons.draw, size: 16), label: Text('Coret')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) => setState(() {
                      mode = v.first;
                      vm.solo = null;
                      vm.lineStart = null;
                      _scanned = false;
                      vm.showRef = mode == 1 && vm.refCenter != null;
                      _rp.ping();
                    }),
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                  child: Container(
                    color: const Color(0xFF0A0D10),
                    child: Stack(children: [
                      Positioned.fill(child: _canvas()),
                      Positioned(top: 0, left: 0, right: 60, child: Align(alignment: Alignment.topLeft, child: _hint(_hintText))),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Column(children: [
                          _roundBtn(Icons.add, 'Zoom in', () => _zoomBy(1.5)),
                          const SizedBox(height: 8),
                          _roundBtn(Icons.remove, 'Zoom out', () => _zoomBy(1 / 1.5)),
                          const SizedBox(height: 8),
                          _roundBtn(Icons.center_focus_strong, 'Pas-kan tampilan', _fitView),
                          const SizedBox(height: 8),
                          _roundBtn(Icons.brush, 'Kuas masker (area yang tidak dihitung)', () => setState(() {
                            _maskTool = !_maskTool;
                            _maskPaint = true;
                          }), active: _maskTool),
                        ]),
                      ),
                      if (busy)
                        Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black45,
                            child: Center(
                              child: Surface(
                                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
                                  const SizedBox(width: 14),
                                  Text(busyMsg.isEmpty ? 'Memproses…' : busyMsg, style: const TextStyle(fontWeight: FontWeight.w600)),
                                ]),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
              _panel(),
            ]),
    );
  }
}


// ============================================================
//  Lembar pemilihan ukuran untuk Auto-All
// ============================================================

class _SizePickSheet extends StatefulWidget {
  final List<int> initial;
  final AppSettings st;
  const _SizePickSheet({required this.initial, required this.st});
  @override
  State<_SizePickSheet> createState() => _SizePickSheetState();
}

class _SizePickSheetState extends State<_SizePickSheet> {
  late final Set<int> sel = widget.initial.toSet();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ukuran pipa apa saja di foto ini?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Pilih semua ukuran yang ada. Setelah itu, untuk tiap ukuran Anda cukup mengetuk 1 pipa sebagai contoh.', style: TextStyle(fontSize: 12.5, color: cs.outline)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < kPipeSizes.length; i++)
              FilterChip(
                avatar: CircleAvatar(backgroundColor: widget.st.colorOf(i), radius: 7),
                label: Text(kPipeSizes[i]),
                selected: sel.contains(i),
                onSelected: (v) => setState(() => v ? sel.add(i) : sel.remove(i)),
              ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: sel.isEmpty ? null : () => Navigator.pop(context, sel.toList()),
              icon: const Icon(Icons.arrow_forward),
              label: Text(sel.isEmpty ? 'Pilih minimal 1 ukuran' : 'Lanjut  •  ${sel.length} ukuran'),
            ),
          ),
        ]),
      ),
    );
  }
}
