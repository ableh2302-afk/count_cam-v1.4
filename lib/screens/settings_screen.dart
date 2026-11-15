import 'package:flutter/material.dart';
import '../models.dart';
import '../services/license.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/style_sheet.dart';
import 'admin_screen.dart';
import 'rack_master_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = appSettings;
  int _taps = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  Future<LicenseStatus> _lic = LicenseService.check();

  void _upd(VoidCallback f) {
    setState(f);
    s.save();
  }

  Future<void> _titleTap() async {
    final now = DateTime.now();
    _taps = now.difference(_last).inSeconds > 3 ? 1 : _taps + 1;
    _last = now;
    if (_taps < 7) return;
    _taps = 0;
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('PIN Master Admin'),
        content: TextField(controller: ctl, obscureText: true, keyboardType: TextInputType.number, autofocus: true),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text == kAdminPin), child: const Text('Masuk'))],
      ),
    );
    if (ok == true && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminScreen()));
  }

  // ---------- komponen tampilan ----------
  Widget _group(String title, IconData icon, List<Widget> kids) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Surface(
        padding: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(children: [
              Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 20, color: cs.onPrimaryContainer)),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
          ),
          ...kids,
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> f, {int? div, String suffix = '', String? hint}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
            child: Text('${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}$suffix', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: cs.primary)),
          ),
        ]),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(hint, style: TextStyle(fontSize: 11.5, color: cs.outline))),
        Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, onChanged: (x) => _upd(() => f(x))),
      ]),
    );
  }

  Widget _switch(String t, bool v, ValueChanged<bool> f, {String? sub}) => SwitchListTile(
        title: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12)),
        value: v,
        onChanged: (x) => _upd(() => f(x)),
      );

  static const _styleNames = ['Bulat penuh', 'Kotak penuh', 'Cincin', 'Bulat + nomor', 'Kotak + nomor', 'Cincin + nomor'];

  Future<void> _pickColor(int i) async {
    var c = s.colorOf(i);
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget ch(String n, int v, ValueChanged<int> f) => Row(children: [
              SizedBox(width: 20, child: Text(n)),
              Expanded(child: Slider(value: v.toDouble(), min: 0, max: 255, onChanged: (x) => set(() => f(x.round())))),
            ]);
        return AlertDialog(
          title: Text('Warna ${kPipeSizes[i]}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(height: 40, color: c),
            ch('R', (c.r * 255).round(), (v) => c = Color.fromARGB(255, v, (c.g * 255).round(), (c.b * 255).round())),
            ch('G', (c.g * 255).round(), (v) => c = Color.fromARGB(255, (c.r * 255).round(), v, (c.b * 255).round())),
            ch('B', (c.b * 255).round(), (v) => c = Color.fromARGB(255, (c.r * 255).round(), (c.g * 255).round(), v)),
          ]),
          actions: [
            TextButton(onPressed: () { _upd(() => s.colors[i] = kDefaultColors[i]); Navigator.pop(ctx); }, child: const Text('Reset')),
            FilledButton(onPressed: () { _upd(() => s.colors[i] = c.toARGB32()); Navigator.pop(ctx); }, child: const Text('Pakai')),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: _titleTap, behavior: HitTestBehavior.opaque, child: const Text('Cam Count • Pengaturan'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        // ---- Lisensi ----
        FutureBuilder<LicenseStatus>(
          future: _lic,
          builder: (c, f) {
            final l = f.data;
            if (l == null) return const SizedBox();
            final txt = l.type == 'P' ? 'Permanen' : (l.expiry != null ? 'Berlaku s/d ${l.expiry!.toString().substring(0, 10)}' : l.message);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Surface(
                color: cs.primaryContainer.withValues(alpha: 0.5),
                child: Row(children: [
                  Icon(Icons.verified_rounded, color: cs.primary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Lisensi', style: TextStyle(fontWeight: FontWeight.w800)), Text(txt, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant))])),
                ]),
              ),
            );
          },
        ),
        // ---- Tampilan penanda ----
        _group('Tampilan Penanda', Icons.palette_rounded, [
          ListTile(
            leading: SizedBox(width: 40, height: 40, child: CustomPaint(painter: _MiniStyle(s))),
            title: const Text('Gaya penanda', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${_styleNames[s.markStyle]}  •  label ${s.textSize.round()}  •  garis ${s.ringWidth.round()}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showMarkerStyleSheet(context);
              if (mounted) setState(() {});
            },
          ),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('Warna per ukuran pipa', style: TextStyle(fontWeight: FontWeight.w700)),
            children: [
              for (var i = 0; i < kPipeSizes.length; i++)
                ListTile(dense: true, leading: CircleAvatar(backgroundColor: s.colorOf(i), radius: 12), title: Text(kPipeSizes[i]), trailing: const Icon(Icons.edit, size: 16), onTap: () => _pickColor(i)),
            ],
          ),
          _slider('Ketebalan garis coretan (mode Coret)', s.strokeWidth, 1, 12, (v) => s.strokeWidth = v, div: 22, suffix: ' px'),
        ]),
        // ---- Deteksi ----
        _group('Deteksi & Akurasi', Icons.center_focus_strong_rounded, [
          _switch('Samakan ukuran lingkaran dengan patokan', s.uniformRadius, (v) => s.uniformRadius = v, sub: 'Semua hasil scan memakai ukuran lingkaran yang Anda TAP, sehingga tidak saling menimpa'),
          _slider('Toleransi ukuran Tap-Match (±)', s.tolerance, 2, 15, (v) => s.tolerance = v, div: 26, suffix: ' %', hint: 'Naikkan jika pipa di foto ukurannya agak beragam'),
          _slider('Sensitivitas deteksi', s.param2, 10, 80, (v) => s.param2 = v, div: 70, hint: 'Kecil = lebih sensitif (pipa samar ikut, tapi bisa ada salah deteksi)'),
          _slider('Ambang tepi', s.param1, 30, 300, (v) => s.param1 = v, div: 54, hint: 'Kecil = tepi yang kontrasnya rendah tetap dihitung'),
          ListTile(
            title: const Text('Ukuran pipa terbesar default', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            subtitle: const Text('Dipakai mode Auto-All untuk menentukan ukuran', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<int>(value: s.refSizeIdx, items: [for (var i = 0; i < kPipeSizes.length; i++) DropdownMenuItem(value: i, child: Text(kPipeSizes[i]))], onChanged: (v) => _upd(() => s.refSizeIdx = v!)),
          ),
        ]),
        // ---- Kamera ----
        _group('Kamera', Icons.photo_camera_rounded, [
          ListTile(
            title: const Text('Kualitas foto', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            subtitle: const Text('Cepat = buka & jepret paling gesit. 4K lebih akurat untuk pipa kecil tapi lebih lambat', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<int>(
              value: s.camQuality,
              items: const [DropdownMenuItem(value: 2, child: Text('Cepat')), DropdownMenuItem(value: 0, child: Text('Standar')), DropdownMenuItem(value: 1, child: Text('Tinggi (4K)'))],
              onChanged: (v) => _upd(() => s.camQuality = v!),
            ),
          ),
          _switch('Garis bantu (grid)', s.showGrid, (v) => s.showGrid = v),
          _switch('Torch menyala saat kamera dibuka', s.autoTorch, (v) => s.autoTorch = v),
        ]),
        // ---- Umum ----
        _group('Umum', Icons.tune_rounded, [
          _switch('Getar & bip saat tambah/hapus penanda', s.haptic, (v) => s.haptic = v),
          _switch('Watermark rak & tanggal pada foto tersimpan', s.watermark, (v) => s.watermark = v),
          ListTile(leading: const Icon(Icons.warehouse_rounded), title: const Text('Kelola Gudang / Rak / Level', style: TextStyle(fontWeight: FontWeight.w700)), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RackMasterScreen()))),
        ]),
      ]),
    );
  }
}

/// Ikon pratinjau kecil gaya penanda yang sedang dipakai.
class _MiniStyle extends CustomPainter {
  final AppSettings s;
  _MiniStyle(this.s);
  @override
  void paint(Canvas c, Size z) {
    final col = s.markColor(5, 0);
    final filled = s.markStyle == 0 || s.markStyle == 1 || s.markStyle == 3 || s.markStyle == 4;
    final square = s.markStyle == 1 || s.markStyle == 4;
    final ctr = Offset(z.width / 2, z.height / 2);
    final r = z.width / 2 - 3;
    final fill = Paint()..color = col.withValues(alpha: filled ? 0.9 : 0.18);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = col;
    if (square) {
      final rr = RRect.fromRectAndRadius(Rect.fromCenter(center: ctr, width: r * 1.8, height: r * 1.8), Radius.circular(r * 0.9 * s.roundness));
      c.drawRRect(rr, fill);
      if (!filled) c.drawRRect(rr, line);
    } else {
      c.drawCircle(ctr, r, fill);
      if (!filled) c.drawCircle(ctr, r, line);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniStyle old) => true;
}
