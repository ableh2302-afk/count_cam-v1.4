import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/db.dart';
import '../services/detector.dart';
import '../services/license.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';
import 'camera_screen.dart';
import 'count_screen.dart';
import 'crop_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    CameraScreen.prefetch();
  }

  late Future<LicenseStatus> _lic = LicenseService.check();
  late Future<List<Map<String, Object?>>> _last = Db.sessions();

  void _refresh() => setState(() {
        _lic = LicenseService.check();
        _last = Db.sessions();
      });

  /// Alur: foto mentah -> normalisasi (isolate) -> pilih area (crop) -> layar hitung.
  Future<void> _open(Uint8List raw) async {
    final nav = Navigator.of(context);
    final msg = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: Surface(padding: EdgeInsets.all(22), child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Menyiapkan foto…')]))),
    );
    Uint8List jpg;
    try {
      jpg = await compute(normalizeImage, raw);
    } catch (e) {
      nav.pop();
      msg.showSnackBar(SnackBar(content: Text('Gagal memuat foto: $e')));
      return;
    }
    nav.pop();
    if (!mounted) return;
    final cropped = await nav.push<Uint8List>(MaterialPageRoute(builder: (_) => CropScreen(bytes: jpg)));
    if (cropped == null || !mounted) return;
    final r = await nav.push<String>(MaterialPageRoute<String>(builder: (_) => CountScreen(bytes: cropped)));
    if (!mounted) return;
    _refresh();
    if (r == 'retake') _camera();
  }

  Future<void> _camera() async {
    final raw = await Navigator.push<Uint8List>(context, MaterialPageRoute(builder: (_) => const CameraScreen()));
    if (raw != null && mounted) _open(raw);
  }

  Future<void> _gallery() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f != null && mounted) _open(await f.readAsBytes());
  }

  Widget _tile(IconData i, String t, String sub, VoidCallback f) => Surface(
        onTap: f,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Icon(i, color: Theme.of(context).colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          // ---- Header ----
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [cs.primary, Color.lerp(cs.primary, Colors.black, 0.35)!]),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const AppLogo(size: 52),
                const SizedBox(width: 12),
                const Expanded(child: Text('Cam Count', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 0.3))),
                FutureBuilder<LicenseStatus>(
                  future: _lic,
                  builder: (c, f) {
                    final l = f.data;
                    if (l == null) return const SizedBox();
                    final txt = l.type == 'P' ? 'Permanen' : (l.expiry != null ? 's/d ${l.expiry!.toString().substring(0, 10)}' : '');
                    if (txt.isEmpty) return const SizedBox();
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.verified, size: 14, color: Colors.white), const SizedBox(width: 4), Text(txt, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700))]),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 14),
              const Text('Hitung stok pipa nesting dari foto — cepat, akurat, 100% offline.', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _camera,
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Foto & Hitung'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: cs.primary, minimumSize: const Size(48, 52)),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _gallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Galeri'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), minimumSize: const Size(48, 52)),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          // ---- Sesi terakhir ----
          FutureBuilder<List<Map<String, Object?>>>(
            future: _last,
            builder: (c, f) {
              final l = f.data;
              if (l == null || l.isEmpty) return const SizedBox();
              final r = l.first;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Surface(
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => SessionDetailScreen(session: r)));
                    _refresh();
                  },
                  child: Row(children: [
                    Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(14)),
                      child: Text('${r['total_semua_pipa']}', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: cs.onSecondaryContainer)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Hitungan terakhir', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text('${r['posisi_rak']}  •  ${r['tanggal_jam']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.outline)),
                      ]),
                    ),
                    const Icon(Icons.chevron_right),
                  ]),
                ),
              );
            },
          ),
          // ---- Menu ----
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.25,
            children: [
              _tile(Icons.history_rounded, 'Riwayat', 'Lihat & export CSV', () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
                _refresh();
              }),
              _tile(Icons.tune_rounded, 'Pengaturan', 'Deteksi, kamera, tampilan', () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                _refresh();
              }),
            ],
          ),
          const SizedBox(height: 20),
          Surface(
            color: cs.primaryContainer.withValues(alpha: 0.45),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(Icons.lightbulb_outline, size: 18, color: cs.primary), const SizedBox(width: 8), const Text('Tips hasil akurat', style: TextStyle(fontWeight: FontWeight.w800))]),
              const SizedBox(height: 8),
              const Text(
                '• Foto tegak lurus ke ujung pipa, cahaya merata.\n'
                '• Zoom / dekatkan, lalu crop hanya area yang dihitung.\n'
                '• Tap-Match: ketuk 1 pipa, tarik lingkaran pas di bibir pipa, lalu Scan.\n'
                '• Tekan Clear untuk berpindah ke ukuran pipa lain.',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
