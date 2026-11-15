import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../settings.dart';
import '../widgets/app_logo.dart';

/// Kamera: pinch-to-zoom, preset zoom, tap-untuk-fokus, kompensasi eksposur,
/// flash (mati/otomatis/torch), garis bantu, dan tombol rana besar.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  static List<CameraDescription>? _cams;

  /// Ambil daftar kamera lebih awal (mis. saat beranda dibuka) agar kamera terbuka lebih cepat.
  static Future<void> prefetch() async {
    try {
      _cams ??= await availableCameras();
    } catch (_) {}
  }

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _c;
  String? _err;
  double _minZ = 1, _maxZ = 1, _zoom = 1, _baseZoom = 1;
  double _minE = 0, _maxE = 0, _exp = 0;
  FlashMode _flash = FlashMode.off;
  late bool _grid = appSettings.showGrid;
  bool _capturing = false;
  Offset? _focusPt;
  Timer? _focusTimer;
  bool _showExp = false;
  bool _initializing = false;
  bool _flashOverlay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _init();
  }

  ResolutionPreset get _preset => switch (appSettings.camQuality) {
        1 => ResolutionPreset.ultraHigh,
        2 => ResolutionPreset.high,
        _ => ResolutionPreset.veryHigh,
      };

  Future<void> _init({int attempt = 0}) async {
    if (_initializing || _c != null) return;
    _initializing = true;
    try {
      CameraScreen._cams ??= await availableCameras();
      final cams = CameraScreen._cams!;
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, _preset, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _zoom = 1;
      setState(() {
        _c = c;
        _err = null;
      }); // preview langsung tampil; pengaturan tambahan menyusul di latar
      unawaited(_setup(c));
    } catch (e) {
      if (!mounted) return;
      if (attempt < 1) {
        _initializing = false;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (mounted) await _init(attempt: attempt + 1);
        return;
      }
      setState(() => _err = 'Kamera tidak dapat dibuka.\n$e');
    } finally {
      _initializing = false;
    }
  }

  /// Zoom, eksposur, fokus, flash: semuanya berjalan paralel setelah preview tampil.
  Future<void> _setup(CameraController c) async {
    try {
      final z = await Future.wait([c.getMinZoomLevel(), c.getMaxZoomLevel()]);
      _minZ = z[0];
      _maxZ = z[1];
      _zoom = _minZ;
    } catch (_) {}
    try {
      final e = await Future.wait([c.getMinExposureOffset(), c.getMaxExposureOffset()]);
      _minE = e[0];
      _maxE = e[1];
    } catch (_) {}
    try {
      await Future.wait([c.setFocusMode(FocusMode.auto), c.setExposureMode(ExposureMode.auto)]);
    } catch (_) {}
    try {
      if (appSettings.autoTorch) {
        await c.setFlashMode(FlashMode.torch);
        _flash = FlashMode.torch;
      } else {
        await c.setFlashMode(FlashMode.off);
      }
    } catch (_) {}
    if (mounted && _c == c) setState(() {});
  }

  /// Lepas kamera hanya saat aplikasi benar-benar ke latar belakang (bukan sekadar bayangan notifikasi).
  Future<void> _release() async {
    final c = _c;
    if (c == null) return;
    _c = null;
    if (mounted) setState(() {});
    try {
      await c.dispose();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _release();
    } else if (state == AppLifecycleState.resumed && _c == null) {
      if (mounted) setState(() => _err = null);
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _setZoom(double z) async {
    final c = _c;
    if (c == null) return;
    z = z.clamp(_minZ, _maxZ);
    if ((z - _zoom).abs() < 0.005) return;
    setState(() => _zoom = z);
    try {
      await c.setZoomLevel(z);
    } catch (_) {}
  }

  Future<void> _focusAt(Offset local, Size box) async {
    final c = _c;
    if (c == null) return;
    final p = Offset((local.dx / box.width).clamp(0.0, 1.0), (local.dy / box.height).clamp(0.0, 1.0));
    setState(() => _focusPt = local);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _focusPt = null);
    });
    HapticFeedback.selectionClick();
    try {
      await c.setFocusPoint(p);
      await c.setExposurePoint(p);
    } catch (_) {}
  }

  Future<void> _cycleFlash() async {
    final c = _c;
    if (c == null) return;
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    try {
      await c.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {}
  }

  Future<void> _setExposure(double v) async {
    setState(() => _exp = v);
    try {
      await _c?.setExposureOffset(v);
    } catch (_) {}
  }

  Future<void> _shoot() async {
    final c = _c;
    if (c == null || _capturing || c.value.isTakingPicture) return;
    setState(() => _capturing = true);
    HapticFeedback.mediumImpact();
    setState(() => _flashOverlay = true);
    Future<void>.delayed(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _flashOverlay = false);
    });
    try {
      final f = await c.takePicture();
      final Uint8List b = await f.readAsBytes();
      if (mounted) Navigator.pop(context, b);
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengambil foto: $e')));
      }
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        _ => Icons.flashlight_on_rounded,
      };
  String get _flashLabel => switch (_flash) {
        FlashMode.off => 'Mati',
        FlashMode.auto => 'Auto',
        _ => 'Torch',
      };

  Widget _glass({required Widget child, EdgeInsets pad = const EdgeInsets.symmetric(horizontal: 12, vertical: 8)}) => Container(
        padding: pad,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(22)),
        child: child,
      );

  Widget _topBtn(IconData i, String tip, VoidCallback f, {bool active = false}) => Material(
        color: active ? Colors.amber.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: IconButton(icon: Icon(i, color: active ? Colors.black : Colors.white), tooltip: tip, onPressed: f),
      );

  Widget _presetChips() {
    final presets = <double>{_minZ, 2, 3, 5, 8}.where((z) => z >= _minZ && z <= _maxZ).toList()..sort();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final z in presets)
        GestureDetector(
          onTap: () => _setZoom(z),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: (_zoom - z).abs() < 0.15 ? Colors.amber : Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              '${z == z.roundToDouble() ? z.toInt() : z.toStringAsFixed(1)}x',
              style: TextStyle(color: (_zoom - z).abs() < 0.15 ? Colors.black : Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
        ),
    ]);
  }

  Widget _shutter() => GestureDetector(
        onTap: _shoot,
        child: AnimatedScale(
          scale: _capturing ? 0.88 : 1,
          duration: const Duration(milliseconds: 120),
          child: Container(
            width: 82,
            height: 82,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: _capturing ? Colors.white70 : Colors.white),
              child: _capturing ? const Padding(padding: EdgeInsets.all(22), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black54)) : null,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _err != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_err!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))))
          : c == null || !c.value.isInitialized
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const AppLogo(size: 72),
                    const SizedBox(height: 18),
                    const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white70)),
                    const SizedBox(height: 12),
                    const Text('Menyiapkan kamera…', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ]),
                )
              : Stack(fit: StackFit.expand, children: [
                  // ---- Preview + gestur ----
                  Center(
                    child: AspectRatio(
                      aspectRatio: 1 / c.value.aspectRatio,
                      child: LayoutBuilder(builder: (ctx, box) {
                        final size = Size(box.maxWidth, box.maxHeight);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (_) => _baseZoom = _zoom,
                          onScaleUpdate: (d) {
                            if (d.pointerCount >= 2) _setZoom(_baseZoom * d.scale);
                          },
                          onTapUp: (d) => _focusAt(d.localPosition, size),
                          child: Stack(fit: StackFit.expand, children: [
                            CameraPreview(c),
                            if (_grid) CustomPaint(painter: _GridPainter()),
                            if (_focusPt != null)
                              Positioned(
                                left: _focusPt!.dx - 34,
                                top: _focusPt!.dy - 34,
                                child: TweenAnimationBuilder<double>(
                                  key: ValueKey(_focusPt),
                                  tween: Tween(begin: 1.4, end: 1.0),
                                  duration: const Duration(milliseconds: 220),
                                  builder: (_, v, __) => Transform.scale(
                                    scale: v,
                                    child: Container(width: 68, height: 68, decoration: BoxDecoration(border: Border.all(color: Colors.amber, width: 2), borderRadius: BorderRadius.circular(10))),
                                  ),
                                ),
                              ),
                          ]),
                        );
                      }),
                    ),
                  ),
                  if (_flashOverlay) Positioned.fill(child: IgnorePointer(child: Container(color: Colors.white.withValues(alpha: 0.55)))),
                  // ---- Bar atas ----
                  Positioned(
                    top: top + 8,
                    left: 12,
                    right: 12,
                    child: Row(children: [
                      _topBtn(Icons.close_rounded, 'Tutup', () => Navigator.pop(context)),
                      const Spacer(),
                      _glass(
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_flashIcon, size: 18, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(_flashLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      _topBtn(_flashIcon, 'Flash', _cycleFlash, active: _flash != FlashMode.off),
                      const SizedBox(width: 8),
                      _topBtn(Icons.grid_on_rounded, 'Garis bantu', () => setState(() => _grid = !_grid), active: _grid),
                      if (_maxE > _minE) ...[
                        const SizedBox(width: 8),
                        _topBtn(Icons.wb_sunny_rounded, 'Kecerahan', () => setState(() => _showExp = !_showExp), active: _showExp),
                      ],
                    ]),
                  ),
                  // ---- Slider eksposur (kanan) ----
                  if (_showExp && _maxE > _minE)
                    Positioned(
                      right: 8,
                      top: top + 80,
                      bottom: bottom + 220,
                      child: _glass(
                        pad: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(children: [
                          const Icon(Icons.wb_sunny, color: Colors.amber, size: 18),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(activeTrackColor: Colors.amber, thumbColor: Colors.amber, inactiveTrackColor: Colors.white24),
                                child: Slider(value: _exp.clamp(_minE, _maxE), min: _minE, max: _maxE, onChanged: _setExposure),
                              ),
                            ),
                          ),
                          Text(_exp.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ]),
                      ),
                    ),
                  // ---- Kontrol bawah ----
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(16, 14, 16, bottom + 16),
                      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_maxZ > _minZ + 0.01) ...[
                          _glass(
                            pad: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                            child: Row(children: [
                              const Icon(Icons.zoom_out, color: Colors.white70, size: 18),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(activeTrackColor: Colors.amber, thumbColor: Colors.amber, inactiveTrackColor: Colors.white24),
                                  child: Slider(value: _zoom.clamp(_minZ, _maxZ), min: _minZ, max: _maxZ, onChanged: _setZoom),
                                ),
                              ),
                              const Icon(Icons.zoom_in, color: Colors.white70, size: 18),
                              const SizedBox(width: 6),
                              SizedBox(width: 40, child: Text('${_zoom.toStringAsFixed(1)}x', textAlign: TextAlign.right, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12))),
                              const SizedBox(width: 6),
                            ]),
                          ),
                          const SizedBox(height: 10),
                          _presetChips(),
                          const SizedBox(height: 14),
                        ],
                        const Text('Arahkan tegak lurus ke ujung pipa  •  ketuk layar untuk fokus', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        const SizedBox(height: 12),
                        _shutter(),
                      ]),
                    ),
                  ),
                ]),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), p);
      canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), p);
    }
    final c = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;
    final m = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(m - const Offset(10, 0), m + const Offset(10, 0), c);
    canvas.drawLine(m - const Offset(0, 10), m + const Offset(0, 10), c);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
