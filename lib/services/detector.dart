import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'geometry.dart';

// ============================================================
//  Pra-proses gambar (dijalankan lewat compute())
// ============================================================

/// Membaca tag orientasi EXIF dari JPEG (1 = normal / tidak ada).
int _exifOrientation(Uint8List b) {
  if (b.length < 12 || b[0] != 0xFF || b[1] != 0xD8) return 1;
  var i = 2;
  while (i + 4 < b.length) {
    if (b[i] != 0xFF) return 1;
    final marker = b[i + 1];
    final len = (b[i + 2] << 8) | b[i + 3];
    if (marker == 0xE1 && i + 10 < b.length && b[i + 4] == 0x45 && b[i + 5] == 0x78 && b[i + 6] == 0x69 && b[i + 7] == 0x66) {
      final t = i + 10; // awal header TIFF
      if (t + 8 > b.length) return 1;
      final le = b[t] == 0x49;
      int u16(int o) => le ? (b[t + o] | (b[t + o + 1] << 8)) : ((b[t + o] << 8) | b[t + o + 1]);
      int u32(int o) => le ? (b[t + o] | (b[t + o + 1] << 8) | (b[t + o + 2] << 16) | (b[t + o + 3] << 24)) : ((b[t + o] << 24) | (b[t + o + 1] << 16) | (b[t + o + 2] << 8) | b[t + o + 3]);
      final ifd = u32(4);
      if (t + ifd + 2 > b.length) return 1;
      final n = u16(ifd);
      for (var k = 0; k < n; k++) {
        final e = ifd + 2 + k * 12;
        if (t + e + 12 > b.length) break;
        if (u16(e) == 0x0112) return u16(e + 8);
      }
      return 1;
    }
    if (marker == 0xDA) break;
    i += 2 + len;
  }
  return 1;
}

/// Normalisasi orientasi EXIF + batasi sisi terpanjang 4000 px.
/// Jalur cepat: bila orientasi sudah normal dan ukuran file wajar, byte dikembalikan apa adanya (tanpa decode/encode ulang).
Uint8List normalizeImage(Uint8List raw) {
  if (_exifOrientation(raw) == 1 && raw.length <= 9 * 1024 * 1024) return raw;
  var im = img.decodeImage(raw)!;
  im = img.bakeOrientation(im);
  final m = math.max(im.width, im.height);
  if (m > 4000) {
    im = im.width >= im.height ? img.copyResize(im, width: 4000) : img.copyResize(im, height: 4000);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

/// Crop gambar. args: bytes, l, t, w, h (pecahan 0..1 dari ukuran gambar), maxSide.
/// Hasil dibatasi maxSide px sisi terpanjang agar deteksi tetap cepat.
Uint8List cropImage(Map<String, dynamic> a) {
  final src = img.decodeImage(a['bytes'] as Uint8List)!;
  final l = (a['l'] as double).clamp(0.0, 0.98);
  final t = (a['t'] as double).clamp(0.0, 0.98);
  final w = (a['w'] as double).clamp(0.02, 1.0 - l);
  final h = (a['h'] as double).clamp(0.02, 1.0 - t);
  final x = (l * src.width).round(), y = (t * src.height).round();
  final cw = math.max(16, (w * src.width).round()), ch = math.max(16, (h * src.height).round());
  var out = img.copyCrop(src, x: x, y: y, width: math.min(cw, src.width - x), height: math.min(ch, src.height - y));
  final maxSide = (a['maxSide'] as int?) ?? 2400;
  final m = math.max(out.width, out.height);
  if (m > maxSide) {
    out = out.width >= out.height ? img.copyResize(out, width: maxSide) : img.copyResize(out, height: maxSide);
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: 93));
}

/// Putar 90 derajat searah jarum jam.
Uint8List rotateImage(Uint8List bytes) {
  final src = img.decodeImage(bytes)!;
  return Uint8List.fromList(img.encodeJpg(img.copyRotate(src, angle: 90), quality: 93));
}

// ============================================================
//  Inti deteksi v3: voting simetri radial + validasi cincin ketat
//  (Tidak memakai Hough bawaan OpenCV; OpenCV hanya untuk decode/resize/blur.)
// ============================================================

class _Img {
  final cv.Mat? mat; // hanya untuk dispose; piramida memakai g (Float32)
  final Float32List g, gx, gy;
  final int w, h;
  final double scale; // working / full
  _Img(this.mat, this.g, this.gx, this.gy, this.w, this.h, this.scale);
  void dispose() => mat?.dispose();
}

class _Lvl {
  final Float32List gx, gy;
  final int w, h;
  _Lvl(this.gx, this.gy, this.w, this.h);
}

void _sobel(Float32List g, int w, int h, Float32List gx, Float32List gy) {
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final a = g[i - w - 1], b = g[i - w], c = g[i - w + 1];
      final d = g[i - 1], f = g[i + 1];
      final gg = g[i + w - 1], hh = g[i + w], ii = g[i + w + 1];
      gx[i] = ((c + 2 * f + ii) - (a + 2 * d + gg)) / 8;
      gy[i] = ((gg + 2 * hh + ii) - (a + 2 * b + c)) / 8;
    }
  }
}

Float32List _toF32(Uint8List px) {
  final f = Float32List(px.length);
  for (var i = 0; i < px.length; i++) {
    f[i] = px[i].toDouble();
  }
  return f;
}

/// Grayscale -> (skala turun) -> [enh] kontras: 0 mati, 1 sedang (CLAHE+tajam), 2 kuat -> blur ringan -> gradien.
_Img _prepare(Uint8List bytes, {int maxDim = 1600, int enh = 0}) {
  final src = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
  final fw = src.cols, fh = src.rows;
  final s = math.min(1.0, maxDim / math.max(fw, fh));
  cv.Mat g = src;
  if (s < 1.0) {
    g = cv.resize(src, ((fw * s).round(), (fh * s).round()), interpolation: cv.INTER_AREA);
    src.dispose();
  }
  cv.Mat base = g;
  if (enh > 0) {
    final clahe = cv.createCLAHE(clipLimit: enh == 1 ? 2.0 : 3.5, tileGridSize: (8, 8));
    base = clahe.apply(g);
    clahe.dispose();
    g.dispose();
  }
  final b = cv.gaussianBlur(base, (5, 5), 1.0);
  final w = b.cols, h = b.rows;
  final f = _toF32(Uint8List.fromList(b.data));
  if (enh > 0) {
    // unsharp mask: tepi bibir pipa lebih tajam
    final b2 = cv.gaussianBlur(base, (9, 9), 3.0);
    final f2 = _toF32(Uint8List.fromList(b2.data));
    b2.dispose();
    final k = enh == 1 ? 0.7 : 1.3;
    for (var i = 0; i < f.length; i++) {
      final v = f[i] + k * (f[i] - f2[i]);
      f[i] = v < 0 ? 0.0 : (v > 255 ? 255.0 : v);
    }
  }
  base.dispose();
  final gx = Float32List(w * h), gy = Float32List(w * h);
  _sobel(f, w, h, gx, gy);
  return _Img(b, f, gx, gy, w, h, s);
}

/// Perkecil dengan rata-rata area (tanpa OpenCV).
Float32List _downscale(Float32List g, int w, int h, int nw, int nh) {
  final out = Float32List(nw * nh);
  final sx = w / nw, sy = h / nh;
  for (var y = 0; y < nh; y++) {
    final y0 = (y * sy).floor();
    final y1 = math.min(h, math.max(y0 + 1, ((y + 1) * sy).floor()));
    for (var x = 0; x < nw; x++) {
      final x0 = (x * sx).floor();
      final x1 = math.min(w, math.max(x0 + 1, ((x + 1) * sx).floor()));
      var sum = 0.0;
      for (var yy = y0; yy < y1; yy++) {
        final o = yy * w;
        for (var xx = x0; xx < x1; xx++) {
          sum += g[o + xx];
        }
      }
      out[y * nw + x] = sum / ((y1 - y0) * (x1 - x0));
    }
  }
  return out;
}

_Lvl _pyramid(_Img im, double s) {
  final nw = math.max(8, (im.w * s).round()), nh = math.max(8, (im.h * s).round());
  final f = _downscale(im.g, im.w, im.h, nw, nh);
  final gx = Float32List(nw * nh), gy = Float32List(nw * nh);
  _sobel(f, nw, nh, gx, gy);
  return _Lvl(gx, gy, nw, nh);
}

class _Fit {
  double x, y, r, score;
  int bins;
  _Fit(this.x, this.y, this.r, this.score, this.bins);
}

const int _nr = 64; // jumlah sinar radial
final Float64List _cs = Float64List.fromList([for (var k = 0; k < _nr; k++) math.cos(2 * math.pi * k / _nr)]);
final Float64List _sn = Float64List.fromList([for (var k = 0; k < _nr; k++) math.sin(2 * math.pi * k / _nr)]);

double _dist(double x1, double y1, double x2, double y2) => math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));

/// Bilinear; null jika di luar gambar.
double? _samp(Float32List a, int w, int h, double x, double y) {
  if (x < 0 || y < 0 || x >= w - 1 || y >= h - 1) return null;
  final x0 = x.floor(), y0 = y.floor();
  final fx = x - x0, fy = y - y0;
  final i = y0 * w + x0;
  return a[i] * (1 - fx) * (1 - fy) + a[i + 1] * fx * (1 - fy) + a[i + w] * (1 - fx) * fy + a[i + w + 1] * fx * fy;
}

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// Fit lingkaran Kasa; koordinat relatif terhadap (ox, oy).
List<double>? _kasa(List<double> px, List<double> py, List<bool> use, double ox, double oy) {
  double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0, sz = 0, sxz = 0, syz = 0, n = 0;
  for (var i = 0; i < px.length; i++) {
    if (!use[i]) continue;
    final x = px[i] - ox, y = py[i] - oy, z = x * x + y * y;
    n++;
    sx += x;
    sy += y;
    sxx += x * x;
    syy += y * y;
    sxy += x * y;
    sz += z;
    sxz += x * z;
    syz += y * z;
  }
  if (n < 3) return null;
  double det3(double a, double b, double c, double d, double e, double f, double g, double h, double i) => a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final d = det3(sxx, sxy, sx, sxy, syy, sy, sx, sy, n);
  if (d.abs() < 1e-9) return null;
  final a = det3(sxz, sxy, sx, syz, syy, sy, sz, sy, n) / d;
  final b = det3(sxx, sxz, sx, sxy, syz, sy, sx, sz, n) / d;
  final c = det3(sxx, sxy, sxz, sxy, syy, syz, sx, sy, sz) / d;
  final cx = a / 2, cy = b / 2;
  final r2 = c + cx * cx + cy * cy;
  if (r2 <= 0) return null;
  return [cx + ox, cy + oy, math.sqrt(r2)];
}

/// Validasi + penyempurnaan cincin. Tepi dipilih konsisten polaritasnya (tepi luar bibir pipa),
/// arah gradien harus radial, ambang tepi adaptif. Mengembalikan null jika bukan cincin yang sahih.
_Fit? _refine(_Img im, double x0, double y0, double r0,
    {double win = 0.12, double bias = 0.3, double minEdge = 6.0, double minScore = 0.45, int minBins = 6, int minInl = 20, int iters = 2, double align = 0.7}) {
  var x = x0, y = y0, r = r0;
  final w = im.w, h = im.h;
  var px = List<double>.filled(_nr, 0), py = List<double>.filled(_nr, 0);
  var sel = List<bool>.filled(_nr, false);
  var rayOkN = 0;

  for (var it = 0; it < iters; it++) {
    final steps = math.min(48, math.max(12, (2 * win * r / 0.7).floor()));
    final rayOk = List<bool>.filled(_nr, false);
    final prof = List<Float64List>.generate(_nr, (_) => Float64List(steps + 1));
    rayOkN = 0;
    for (var k = 0; k < _nr; k++) {
      var ok = true;
      for (var j = 0; j <= steps; j++) {
        final t = -win + 2 * win * j / steps;
        final rr = r * (1 + t);
        final v = _samp(im.g, w, h, x + _cs[k] * rr, y + _sn[k] * rr);
        if (v == null) {
          ok = false;
          break;
        }
        prof[k][j] = v;
      }
      rayOk[k] = ok;
      if (ok) rayOkN++;
    }
    if (rayOkN < _nr * 0.3) return null;

    // polaritas dominan dari tepi terkuat tiap sinar
    final firstD = <double>[];
    for (var k = 0; k < _nr; k++) {
      if (!rayOk[k]) continue;
      var bw = -1.0;
      var bd = 0.0;
      for (var j = 0; j < steps - 1; j++) {
        final d = prof[k][j + 2] - prof[k][j];
        final t = -win + 2 * win * (j + 1) / steps;
        final wgt = d.abs() * (1 - bias * t.abs() / win);
        if (wgt > bw) {
          bw = wgt;
          bd = d;
        }
      }
      firstD.add(bd);
    }
    final pm = _median(firstD);
    final pol = pm < 0 ? -1.0 : 1.0;

    final best = List<double>.filled(_nr, 0);
    final selCand = List<bool>.filled(_nr, false);
    for (var k = 0; k < _nr; k++) {
      if (!rayOk[k]) continue;
      var be = -1.0;
      var bj = -1;
      var bv = 0.0;
      for (var j = 0; j < steps - 1; j++) {
        final d = math.max(0.0, pol * (prof[k][j + 2] - prof[k][j]));
        final t = -win + 2 * win * (j + 1) / steps;
        final e = d * (1 - bias * t.abs() / win);
        if (e > be) {
          be = e;
          bj = j + 1;
          bv = d;
        }
      }
      if (bj < 0) continue;
      final t = -win + 2 * win * bj / steps;
      final rr = r * (1 + t);
      px[k] = x + _cs[k] * rr;
      py[k] = y + _sn[k] * rr;
      best[k] = bv;
      selCand[k] = bv >= minEdge;
    }
    final validBest = <double>[];
    for (var k = 0; k < _nr; k++) {
      if (selCand[k]) validBest.add(best[k]);
    }
    final med = _median(validBest);
    var n = 0;
    sel = List<bool>.filled(_nr, false);
    for (var k = 0; k < _nr; k++) {
      if (!selCand[k] || best[k] < 0.35 * med) continue;
      final gxv = _samp(im.gx, w, h, px[k], py[k]), gyv = _samp(im.gy, w, h, px[k], py[k]);
      if (gxv == null || gyv == null) continue;
      final mag = math.sqrt(gxv * gxv + gyv * gyv) + 1e-6;
      final cosv = (gxv * _cs[k] + gyv * _sn[k]).abs() / mag;
      if (cosv >= align) {
        sel[k] = true;
        n++;
      }
    }
    if (n < math.max(minInl.toDouble(), _nr * 0.3)) return null;

    var f = _kasa(px, py, sel, x, y);
    if (f == null) return null;
    for (var q = 0; q < 3; q++) {
      final thr = math.max(1.5, 0.04 * f![2]);
      final inl = List<bool>.filled(_nr, false);
      var cnt = 0;
      for (var k = 0; k < _nr; k++) {
        if (!sel[k]) continue;
        if ((_dist(px[k], py[k], f[0], f[1]) - f[2]).abs() < thr) {
          inl[k] = true;
          cnt++;
        }
      }
      if (cnt < minInl) return null;
      final f2 = _kasa(px, py, inl, x, y);
      if (f2 == null) break;
      f = f2;
    }
    final cx = f![0], cy = f[1], cr = f[2];
    if (_dist(cx, cy, x, y) > 0.3 * r || (cr - r).abs() > win * 1.05 * r) return null;
    x = cx;
    y = cy;
    r = cr;
  }

  final thr = math.max(1.5, 0.04 * r);
  var inlN = 0;
  final bins = <int>{};
  for (var k = 0; k < _nr; k++) {
    if (!sel[k]) continue;
    if ((_dist(px[k], py[k], x, y) - r).abs() < thr) {
      inlN++;
      bins.add(k * 8 ~/ _nr);
    }
  }
  final score = inlN / math.max(1, rayOkN);
  if (score < minScore || bins.length < minBins) return null;
  return _Fit(x, y, r, score, bins.length);
}

// ---------- Voting simetri radial ----------

int _ci(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

void _boxBlur(Float32List a, int w, int h, int rad) {
  if (rad < 1) return;
  final tmp = Float32List(w * h);
  final win = 2 * rad + 1;
  // horizontal
  for (var y = 0; y < h; y++) {
    final o = y * w;
    var sum = 0.0;
    for (var x = -rad; x <= rad; x++) {
      sum += a[o + _ci(x, 0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[o + x] = sum / win;
      final add = _ci(x + rad + 1, 0, w - 1), sub = _ci(x - rad, 0, w - 1);
      sum += a[o + add] - a[o + sub];
    }
  }
  // vertikal
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var y = -rad; y <= rad; y++) {
      sum += tmp[_ci(y, 0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      a[y * w + x] = sum / win;
      final add = _ci(y + rad + 1, 0, h - 1), sub = _ci(y - rad, 0, h - 1);
      sum += tmp[add * w + x] - tmp[sub * w + x];
    }
  }
}

Float32List _vote(Float32List gx, Float32List gy, int w, int h, Float64List radii, double sigma, {double thr = 6.0}) {
  final acc = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final ax = gx[i], ay = gy[i];
      final m = math.sqrt(ax * ax + ay * ay);
      if (m <= thr) continue;
      final wgt = m > 40 ? 40.0 : m;
      final dx = ax / m, dy = ay / m;
      for (var q = 0; q < radii.length; q++) {
        final r = radii[q];
        var xx = (x + dx * r).round(), yy = (y + dy * r).round();
        if (xx >= 0 && xx < w && yy >= 0 && yy < h) acc[yy * w + xx] += wgt;
        xx = (x - dx * r).round();
        yy = (y - dy * r).round();
        if (xx >= 0 && xx < w && yy >= 0 && yy < h) acc[yy * w + xx] += wgt;
      }
    }
  }
  // 3x box blur ~ Gaussian(sigma)
  final bw = math.sqrt(12 * sigma * sigma / 3 + 1);
  final rad = math.max(1, ((bw - 1) / 2).round());
  for (var k = 0; k < 3; k++) {
    _boxBlur(acc, w, h, rad);
  }
  return acc;
}

class _Pk {
  final double x, y, v;
  _Pk(this.x, this.y, this.v);
}

List<_Pk> _peaks(Float32List acc, int w, int h, double mind, double rel, int cap) {
  var mx = 0.0;
  for (var i = 0; i < acc.length; i++) {
    if (acc[i] > mx) mx = acc[i];
  }
  if (mx <= 0) return const [];
  final thr = rel * mx;
  final cand = <_Pk>[];
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final v = acc[i];
      if (v < thr) continue;
      if (acc[i - 1] > v || acc[i + 1] > v || acc[i - w] > v || acc[i + w] > v || acc[i - w - 1] > v || acc[i - w + 1] > v || acc[i + w - 1] > v || acc[i + w + 1] > v) continue;
      cand.add(_Pk(x.toDouble(), y.toDouble(), v));
    }
  }
  cand.sort((a, b) => b.v.compareTo(a.v));
  final out = <_Pk>[];
  final m2 = mind * mind;
  for (final c in cand) {
    var ok = true;
    for (final k in out) {
      final dx = c.x - k.x, dy = c.y - k.y;
      if (dx * dx + dy * dy < m2) {
        ok = false;
        break;
      }
    }
    if (ok) {
      out.add(c);
      if (out.length >= cap) break;
    }
  }
  return out;
}

/// Kandidat pusat untuk lingkaran berjari-jari ~R (px working). Memakai piramida agar R efektif ~30 px.
List<List<double>> _bandCands(_Img im, double R, {double spread = 0.09, double rel = 0.12, double mind = 1.5}) {
  final s = math.min(1.0, 30.0 / R);
  Float32List gx = im.gx, gy = im.gy;
  var w = im.w, h = im.h;
  if (s < 1.0) {
    final l = _pyramid(im, s);
    gx = l.gx;
    gy = l.gy;
    w = l.w;
    h = l.h;
  }
  final rs = R * s;
  final rl = <double>[];
  final step = math.max(0.7, rs * 0.02);
  for (var r = rs * (1 - spread); r <= rs * (1 + spread) + 0.01; r += step) {
    rl.add(r);
  }
  final mean = rl.reduce((a, b) => a + b) / rl.length;
  final acc = _vote(gx, gy, w, h, Float64List.fromList(rl), math.max(1.5, 0.08 * mean));
  final pk = _peaks(acc, w, h, math.max(3.0, mind * rs), rel, 800);
  return [for (final p in pk) [p.x / s, p.y / s, R, p.v]];
}

// ---------- Pasca-proses ----------

List<_Fit> _nms2(List<_Fit> cs, {double ratio = 0.9}) {
  final s = [...cs]..sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Fit>[];
  for (final c in s) {
    var dup = false;
    for (var n = 0; n < keep.length; n++) {
      final k = keep[n];
      final d = _dist(k.x, k.y, c.x, c.y);
      final big = math.max(k.r, c.r);
      final ra = math.min(k.r, c.r) / big;
      if (ra > ratio && d < 0.7 * big) {
        // bibir luar lebih disukai daripada tepi dalam dinding
        if (c.r > k.r * 1.03 && c.score >= 0.85 * k.score && d < 0.25 * big) keep[n] = c;
        dup = true;
        break;
      }
    }
    if (!dup) keep.add(c);
  }
  return keep;
}

bool _smallOk(_Fit f) => !(f.r < 16 && (f.score < 0.6 || f.bins < 7));

List<_Fit> _withPeers(List<_Fit> fits, {double tol = 0.08}) {
  final out = <_Fit>[];
  for (final f in fits) {
    var n = 0;
    for (final g in fits) {
      if (identical(g, f)) continue;
      if ((g.r - f.r).abs() <= tol * f.r && _dist(g.x, g.y, f.x, f.y) <= 2.7 * math.max(f.r, g.r)) {
        n++;
        break;
      }
    }
    if (n >= 1) out.add(f);
  }
  return out;
}

List<List<_Fit>> _clusterRadii(List<_Fit> fits, {double tol = 0.08}) {
  final s = [...fits]..sort((a, b) => a.r.compareTo(b.r));
  final cl = <List<_Fit>>[];
  for (final f in s) {
    if (cl.isNotEmpty && f.r <= cl.last.first.r * (1 + 2 * tol)) {
      cl.last.add(f);
    } else {
      cl.add([f]);
    }
  }
  return cl;
}

/// Buang "lingkaran super" yang melingkupi >=2 pipa lain yang tidak konsentris.
List<_Fit> _superFilter(List<_Fit> fits) {
  final out = <_Fit>[];
  for (final c in fits) {
    var n = 0;
    for (final g in fits) {
      if (identical(g, c) || g.r > 0.8 * c.r) continue;
      final d = _dist(g.x, g.y, c.x, c.y);
      if (d + g.r <= c.r * 1.03 && d > 0.35 * c.r) n++;
    }
    if (n < 2) out.add(c);
  }
  return out;
}

/// Pipa terluar dulu: kelompok radius terbesar didahulukan; pipa yang berada di dalam pipa lain dilewati.
List<_Fit> _outerPass(List<_Fit> all) {
  final fits = _withPeers(all);
  final cl = _clusterRadii(fits);
  cl.sort((a, b) => b[b.length ~/ 2].r.compareTo(a[a.length ~/ 2].r));
  final acc = <_Fit>[];
  for (final c in cl) {
    final order = [...c]..sort((a, b) => b.score.compareTo(a.score));
    for (final f in order) {
      var ok = true;
      for (final a in acc) {
        final d = _dist(f.x, f.y, a.x, a.y);
        if (d < 0.9 * a.r || d < 0.85 * (f.r + a.r)) {
          ok = false;
          break;
        }
      }
      if (ok) acc.add(f);
    }
  }
  return acc;
}

/// Buang lingkaran kecil palsu di celah antara pipa yang saling bersinggungan.
List<_Fit> _gapFilter(List<_Fit> cs) {
  final out = <_Fit>[];
  for (final c in cs) {
    var n = 0;
    for (final o in cs) {
      if (identical(o, c) || o.r < c.r * 2.5) continue;
      if ((_dist(o.x, o.y, c.x, c.y) - (o.r + c.r)).abs() < 0.12 * o.r) n++;
    }
    if (n < 2) out.add(c);
  }
  return out;
}

double _domRadius(List<_Fit> outer) {
  if (outer.isEmpty) return 0;
  final cl = _clusterRadii(outer);
  cl.sort((a, b) => b.length.compareTo(a.length));
  return _median(cl.first.map((e) => e.r).toList());
}

/// Pipa yang hanya terdeteksi cincin dalamnya: cari bibir luar (radius dominan) di pusat yang sama.
List<_Fit> _promote(_Img im, List<_Fit> outer) {
  if (outer.isEmpty) return outer;
  final dom = _domRadius(outer);
  final res = <_Fit>[];
  for (final c in outer) {
    if (c.r >= 0.5 * dom && c.r < 0.9 * dom) {
      _Fit? best;
      for (final m in const [1.0, 0.96, 1.04]) {
        final f = _refine(im, c.x, c.y, dom * m, win: 0.08, minScore: 0.4, minBins: 6);
        if (f != null && _dist(f.x, f.y, c.x, c.y) < 0.3 * dom && (f.r - dom).abs() < 0.1 * dom && (best == null || f.score > best.score)) best = f;
      }
      if (best != null) {
        res.add(best);
        continue;
      }
    }
    res.add(c);
  }
  return _nms2(res);
}

List<_Fit> _dropTiny(List<_Fit> outer) {
  if (outer.isEmpty) return outer;
  final dom = _domRadius(outer);
  final keep = <_Fit>[];
  for (final c in outer) {
    if (c.r < 0.5 * dom) {
      var peers = 0;
      for (final g in outer) {
        if (!identical(g, c) && (g.r - c.r).abs() <= 0.1 * c.r) peers++;
      }
      if (peers < 4) continue;
    }
    keep.add(c);
  }
  return keep;
}

/// Cincin pipa bersarang di dalam tiap pipa luar.
List<_Fit> _nestedPass(_Img im, List<_Fit> outer) {
  final res = <_Fit>[];
  for (final o in outer) {
    var last = o.r;
    var r = o.r * 0.93;
    final minR = math.max(8.0, o.r * 0.35);
    while (r >= minR) {
      final f = _refine(im, o.x, o.y, r, win: 0.04, bias: 0.0, minScore: 0.5, minBins: 6);
      if (f != null && _dist(f.x, f.y, o.x, o.y) < 0.22 * o.r && f.r < last * 0.9) {
        res.add(f);
        last = f.r;
        r = f.r * 0.93;
      } else {
        r *= 0.965;
      }
    }
  }
  return res;
}

List<_Fit> _scanAll(_Img im, double minScore, double minEdge, double rel, Stopwatch sw) {
  final rmin = math.max(8.0, math.min(im.w, im.h) * 0.007);
  final rmax = math.min(im.w, im.h) * 0.45;
  final fits = <_Fit>[];
  for (var r = rmax; r >= rmin; r /= 1.17) {
    if (sw.elapsed.inSeconds > 22) break; // pengaman waktu
    for (final c in _bandCands(im, r, rel: rel)) {
      final f = _refine(im, c[0], c[1], c[2], win: 0.14, minScore: minScore, minEdge: minEdge);
      if (f != null && _smallOk(f)) fits.add(f);
    }
  }
  return _nms2(fits);
}

List<List<double>> _pack(List<_Fit> cs, double s, {double nestedFlag = 0}) => cs.map((c) => [c.x / s, c.y / s, c.r / s, c.score, nestedFlag]).toList();

/// Peta pengaturan pengguna -> parameter. p2 (10..80, kecil = sensitif); p1 (30..300) = ambang tepi.
double _unit(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
double _relOf(double p2) => 0.06 + _unit((p2 - 10) / 70) * 0.2;
double _scoreOf(double p2) => 0.40 + _unit((p2 - 10) / 70) * 0.2;
double _edgeOf(double p1) => math.min(12.0, math.max(3.0, p1 / 100 * 6.0));

/// MODE Auto-All. args: bytes, p1, p2, nested(bool). Hasil [x, y, r, skor, bersarang(0/1)] dalam piksel gambar asli.
List<List<double>> autoDetect(Map<String, dynamic> a) {
  final sw = Stopwatch()..start();
  final im = _prepare(a['bytes'] as Uint8List, enh: (a['enh'] as int?) ?? 0);
  try {
    final p2 = (a['p2'] as double);
    final fits = _scanAll(im, _scoreOf(p2), _edgeOf(a['p1'] as double), _relOf(p2), sw);
    var out = _gapFilter(_outerPass(_superFilter(fits)));
    out = _dropTiny(_promote(im, out));
    final res = _pack(out, im.scale);
    if (a['nested'] == true && sw.elapsed.inSeconds < 24) {
      res.addAll(_pack(_nestedPass(im, out), im.scale, nestedFlag: 1));
    }
    return res;
  } finally {
    im.dispose();
  }
}

// ---------- Tap-Match ----------

List<_Fit> _runRef(_Img im, double r, double spread, double radTol, double win, double minScore, double minEdge, double rel) {
  final fits = <_Fit>[];
  for (final c in _bandCands(im, r, spread: spread, rel: rel)) {
    final f = _refine(im, c[0], c[1], c[2], win: win, minScore: minScore, minEdge: minEdge);
    if (f != null && (f.r - r).abs() <= radTol * r) fits.add(f);
  }
  return _nms2(fits);
}

/// Pass 1 lebar (+-20%) -> radius dominan -> pass 2 sempit sesuai toleransi.
List<_Fit> _detectRef(_Img im, double rRef, double tol, double minScore, double minEdge, double rel) {
  final p1 = _runRef(im, rRef, 0.2, 0.22, 0.2, minScore, minEdge, rel);
  var r2 = rRef;
  if (p1.length >= 3) {
    final cl = _clusterRadii(p1, tol: 0.06);
    cl.sort((a, b) => b.length.compareTo(a.length));
    r2 = _median(cl.first.map((e) => e.r).toList());
  }
  final t = math.max(tol, 0.05);
  return _runRef(im, r2, math.max(0.09, t), math.max(t, 0.06) * 1.25, math.max(0.12, t * 1.2), minScore, minEdge, rel);
}

/// Paskan lingkaran buatan pengguna ke bibir (tepi luar) pipa.
_Fit? _snap(_Img im, double x, double y, double r, double minEdge) {
  final x0 = math.max(0, (x - 2.4 * r).floor()), x1 = math.min(im.w, (x + 2.4 * r).ceil());
  final y0 = math.max(0, (y - 2.4 * r).floor()), y1 = math.min(im.h, (y + 2.4 * r).ceil());
  final w = x1 - x0, h = y1 - y0;
  if (w < 8 || h < 8) return null;
  final gx = Float32List(w * h), gy = Float32List(w * h);
  for (var yy = 0; yy < h; yy++) {
    for (var xx = 0; xx < w; xx++) {
      gx[yy * w + xx] = im.gx[(yy + y0) * im.w + xx + x0];
      gy[yy * w + xx] = im.gy[(yy + y0) * im.w + xx + x0];
    }
  }
  final rl = <double>[];
  for (var q = 0.75 * r; q < 1.3 * r; q += math.max(1.0, 0.03 * r)) {
    rl.add(q);
  }
  final acc = _vote(gx, gy, w, h, Float64List.fromList(rl), math.max(2.0, 0.07 * r));
  final pk = _peaks(acc, w, h, math.max(3.0, 0.5 * r), 0.3, 12);
  final cs = <List<double>>[
    [x, y],
    for (final p in pk)
      if (_dist(p.x + x0, p.y + y0, x, y) <= 0.9 * r) [p.x + x0, p.y + y0],
  ];
  final cands = <_Fit>[];
  for (final c in cs.take(5)) {
    for (var m = 0.74; m < 1.2; m += 0.03) {
      final f = _refine(im, c[0], c[1], r * m, win: 0.05, bias: 0.0, minScore: 0.5, minEdge: minEdge);
      if (f != null && _dist(f.x, f.y, c[0], c[1]) < 0.3 * r * m) cands.add(f);
    }
  }
  if (cands.isEmpty) return null;
  _Fit top = cands.first;
  var topKey = -1e9;
  for (final f in cands) {
    final k = f.score - 0.4 * (math.log(f.r / r)).abs();
    if (k > topKey) {
      topKey = k;
      top = f;
    }
  }
  _Fit best = top;
  var bestR = -1.0;
  for (final f in cands) {
    if (_dist(f.x, f.y, top.x, top.y) < 0.12 * top.r && f.score >= 0.7 * top.score && f.r <= 1.18 * r && f.r > bestR) {
      bestR = f.r;
      best = f;
    }
  }
  return _refine(im, best.x, best.y, best.r, win: 0.08, bias: 0.0, minScore: 0.45, minEdge: minEdge) ?? best;
}

/// Buang lingkaran yang terlalu berdekatan (skor tertinggi didahulukan) agar tidak saling tumpang tindih.
List<_Fit> _spacing(List<_Fit> fits, double minDist) {
  final s = [...fits]..sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Fit>[];
  for (final f in s) {
    var ok = true;
    for (final k in keep) {
      if (_dist(f.x, f.y, k.x, k.y) < minDist) {
        ok = false;
        break;
      }
    }
    if (ok) keep.add(f);
  }
  return keep;
}

/// Inti Tap-Match: cari pipa seukuran lingkaran patokan pengguna (x, y, r dalam px working).
/// Jika [uniform], semua lingkaran hasil memakai radius patokan persis (pusat tetap dari deteksi),
/// dan lingkaran patokan pengguna dipertahankan apa adanya.
List<_Fit> _scanRefCore(_Img im, double x, double y, double r, double tol, double minScore, double minEdge, double rel, bool uniform) {
  var found = _detectRef(im, r, tol, minScore, minEdge, rel);
  if (uniform) found = [for (final f in found) _Fit(f.x, f.y, r, f.score, f.bins)];
  found = found.where((f) => _dist(f.x, f.y, x, y) >= 0.7 * r).toList();
  found.add(_Fit(x, y, r, 1.0, 8)); // lingkaran yang di-TAP pengguna
  return _spacing(found, 1.45 * r);
}

/// Tap-Match lengkap. args: bytes, x, y, r (px gambar asli), tol, p1, p2, uniform (default true), snap (default false).
/// Hasil: {'ref': [x,y,r,skor] atau [], 'found': [[x,y,r,skor,0],...]}
Map<String, dynamic> scanFromReference(Map<String, dynamic> a) {
  final im = _prepare(a['bytes'] as Uint8List, enh: (a['enh'] as int?) ?? 0);
  try {
    final s = im.scale;
    final p2 = a['p2'] as double;
    final minEdge = _edgeOf(a['p1'] as double);
    var x = (a['x'] as double) * s, y = (a['y'] as double) * s, r = (a['r'] as double) * s;
    var ref = <double>[];
    if (a['snap'] == true) {
      final sn = _snap(im, x, y, r, minEdge);
      if (sn != null && _dist(sn.x, sn.y, x, y) < 0.8 * r) {
        x = sn.x;
        y = sn.y;
        r = sn.r;
        ref = [x / s, y / s, r / s, sn.score];
      }
    }
    final found = _scanRefCore(im, x, y, r, a['tol'] as double, _scoreOf(p2), minEdge, _relOf(p2), a['uniform'] != false);
    return {'ref': ref, 'found': _pack(found, s)};
  } finally {
    im.dispose();
  }
}

/// Deteksi banyak ukuran sekaligus. Tiap ukuran punya satu pipa contoh dari pengguna.
/// args: bytes, refs: List<List<double>> [sizeIdx, x, y, r] (px gambar asli), tol, p1, p2, uniform, snap.
/// Hasil: {'refs': [[size,x,y,r,skor],...], 'found': [[x,y,r,skor,size],...]}
Map<String, dynamic> scanMulti(Map<String, dynamic> a) {
  final sw = Stopwatch()..start();
  final im = _prepare(a['bytes'] as Uint8List, enh: (a['enh'] as int?) ?? 0);
  try {
    final s = im.scale;
    final p2 = a['p2'] as double;
    final minEdge = _edgeOf(a['p1'] as double);
    final score = _scoreOf(p2), rel = _relOf(p2);
    final tol = a['tol'] as double;
    final uniform = a['uniform'] != false;
    final refs = (a['refs'] as List).map((e) => (e as List).cast<double>()).toList()..sort((p, q) => q[3].compareTo(p[3])); // radius terbesar dulu
    final accepted = <_Fit>[];
    final tags = <int>[];
    final outRefs = <List<double>>[];
    for (final rf in refs) {
      final size = rf[0].round();
      var x = rf[1] * s, y = rf[2] * s, r = rf[3] * s;
      double sc = 0;
      if (a['snap'] == true) {
        final sn = _snap(im, x, y, r, minEdge);
        if (sn != null && _dist(sn.x, sn.y, x, y) < 0.8 * r) {
          x = sn.x;
          y = sn.y;
          r = sn.r;
          sc = sn.score;
        }
      }
      outRefs.add([size.toDouble(), x / s, y / s, r / s, sc]);
      if (sw.elapsed.inSeconds > 40) {
        accepted.add(_Fit(x, y, r, 1.0, 8)); // waktu habis: minimal pipa contoh ikut terhitung
        tags.add(size);
        continue;
      }
      for (final f in _scanRefCore(im, x, y, r, tol, score, minEdge, rel, uniform)) {
        var ok = true;
        for (final k in accepted) {
          final d = _dist(k.x, k.y, f.x, f.y);
          final big = math.max(k.r, f.r), small = math.min(k.r, f.r);
          if (small / big > 0.9) {
            if (d < 1.45 * big) {
              ok = false;
              break;
            }
          } else {
            final nested = d + small <= big * 1.05; // pipa kecil di dalam pipa besar
            if (!nested && d < 0.85 * (k.r + f.r)) {
              ok = false;
              break;
            }
          }
        }
        if (ok) {
          accepted.add(f);
          tags.add(size);
        }
      }
    }
    return {
      'refs': outRefs,
      'found': [for (var i = 0; i < accepted.length; i++) [accepted[i].x / s, accepted[i].y / s, accepted[i].r / s, accepted[i].score, tags[i].toDouble()]],
    };
  } finally {
    im.dispose();
  }
}

/// "Paskan" saja. args: bytes, x, y, r (px gambar asli), p1. Hasil [x, y, r, skor] atau [].
List<double> snapCircle(Map<String, dynamic> a) {
  final im = _prepare(a['bytes'] as Uint8List, enh: (a['enh'] as int?) ?? 0);
  try {
    final s = im.scale;
    final f = _snap(im, (a['x'] as double) * s, (a['y'] as double) * s, (a['r'] as double) * s, _edgeOf((a['p1'] as double?) ?? 100));
    if (f == null) return const [];
    return [f.x / s, f.y / s, f.r / s, f.score];
  } finally {
    im.dispose();
  }
}


// ============================================================
//  Estimasi kemiringan otomatis (pelurusan perspektif)
//  Memutar kamera virtual pada berbagai sudut, lalu memilih sudut yang
//  menghasilkan paling banyak bibir pipa yang benar-benar BULAT.
// ============================================================

class _WarpOut {
  final Float32List px;
  final int w, h;
  _WarpOut(this.px, this.w, this.h);
}

_WarpOut? _warpGray(Float32List g, int w, int h, List<double> hm, int maxDim) {
  final corners = <List<double>>[];
  for (final c in [
    [0.0, 0.0],
    [w.toDouble(), 0.0],
    [w.toDouble(), h.toDouble()],
    [0.0, h.toDouble()],
  ]) {
    final p = applyH(hm, c[0], c[1]);
    if (p == null) return null;
    corners.add(p);
  }
  var x0 = 1e18, x1 = -1e18, y0 = 1e18, y1 = -1e18;
  for (final p in corners) {
    x0 = math.min(x0, p[0]);
    x1 = math.max(x1, p[0]);
    y0 = math.min(y0, p[1]);
    y1 = math.max(y1, p[1]);
  }
  final bw = x1 - x0, bh = y1 - y0;
  if (!bw.isFinite || !bh.isFinite || bw < 8 || bh < 8 || bw > 12 * bh || bh > 12 * bw) return null;
  final s = maxDim / math.max(bw, bh);
  final nw = math.max(8, (bw * s).round()), nh = math.max(8, (bh * s).round());
  final inv = invert3(hm);
  if (inv == null) return null;
  final out = Float32List(nw * nh);
  for (var v = 0; v < nh; v++) {
    final yy = v / s + y0;
    for (var u = 0; u < nw; u++) {
      final xx = u / s + x0;
      final pw = inv[6] * xx + inv[7] * yy + inv[8];
      if (pw.abs() < 1e-9) continue;
      final sx = (inv[0] * xx + inv[1] * yy + inv[2]) / pw;
      final sy = (inv[3] * xx + inv[4] * yy + inv[5]) / pw;
      final val = _samp(g, w, h, sx, sy);
      out[v * nw + u] = val ?? 0.0;
    }
  }
  return _WarpOut(out, nw, nh);
}

_Img _imgFromGray(Float32List g, int w, int h) {
  final gx = Float32List(w * h), gy = Float32List(w * h);
  _sobel(g, w, h, gx, gy);
  return _Img(null, g, gx, gy, w, h, 1.0);
}

/// Skor kebulatan = jumlah pipa terluar yang lolos validasi cincin pada gambar hasil putaran.
double _roundnessScore(_WarpOut wp, Stopwatch sw) {
  _boxBlur(wp.px, wp.w, wp.h, 1);
  _boxBlur(wp.px, wp.w, wp.h, 1);
  final im = _imgFromGray(wp.px, wp.w, wp.h);
  final fits = _scanAll(im, 0.46, 6.0, 0.117, sw);
  final out = _gapFilter(_outerPass(_superFilter(fits)));
  return out.length.toDouble();
}

bool _insideOther(_Fit c, List<_Fit> all) {
  for (final o in all) {
    if (identical(o, c) || o.r <= c.r * 1.15) continue;
    if (_dist(o.x, o.y, c.x, c.y) + c.r <= o.r * 1.05) return true;
  }
  return false;
}

/// Kemiringan garis regresi Theil-Sen (median kemiringan antar-pasangan) dan intersepnya.
List<double>? _theilSen(List<double> x, List<double> y) {
  final n = x.length;
  if (n < 8) return null;
  final slopes = <double>[];
  var seed = 12345;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed;
  }

  final pairs = n <= 90 ? n * (n - 1) ~/ 2 : 3500;
  if (n <= 90) {
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if ((x[i] - x[j]).abs() > 5) slopes.add((y[i] - y[j]) / (x[i] - x[j]));
      }
    }
  } else {
    for (var k = 0; k < pairs; k++) {
      final i = next() % n, j = next() % n;
      if (i != j && (x[i] - x[j]).abs() > 5) slopes.add((y[i] - y[j]) / (x[i] - x[j]));
    }
  }
  if (slopes.length < 10) return null;
  final sl = _median(slopes);
  final res = [for (var i = 0; i < n; i++) y[i] - sl * x[i]];
  return [sl, _median(res)];
}

/// Perkiraan kemiringan dari perubahan ukuran bibir pipa terluar terhadap posisi (makin jauh makin kecil).
/// Bidang miring: skala horizontal berubah linear, g = tan(sudut) / f.
List<double>? _scaleGradientTilt(_Img im, double fs, Stopwatch sw) {
  final fits = _superFilter(_scanAll(im, 0.46, 6.0, 0.117, sw));
  final outer = fits.where((c) => !_insideOther(c, fits)).toList();
  if (outer.length < 12) return null;
  final ys = outer.map((c) => c.y).toList(), xs = outer.map((c) => c.x).toList(), rs = outer.map((c) => c.r).toList();
  final f = fs * math.max(im.w, im.h);
  final ty = _theilSen(ys, rs), tx = _theilSen(xs, rs);
  if (ty == null || tx == null) return null;
  final rcy = ty[1] + ty[0] * im.h / 2, rcx = tx[1] + tx[0] * im.w / 2;
  if (rcy <= 1 || rcx <= 1) return null;
  final pitch = math.atan(ty[0] / rcy * f) * 180 / math.pi;
  final yaw = math.atan(tx[0] / rcx * f) * 180 / math.pi;
  double lim(double v, double m) => v < -m ? -m : (v > m ? m : v);
  return [lim(pitch, 60), lim(yaw, 45)];
}

/// Perkirakan pitch/yaw otomatis. args: bytes, fs (default 0.8), enh.
/// Hasil: {pitch, yaw, base, score, ok}. ok=false bila tidak ada koreksi yang meyakinkan.
Map<String, dynamic> estimateTilt(Map<String, dynamic> a) {
  final sw = Stopwatch()..start();
  final im = _prepare(a['bytes'] as Uint8List, maxDim: 800, enh: (a['enh'] as int?) ?? 0);
  try {
    final fs = (a['fs'] as double?) ?? 0.8;
    final g = _scaleGradientTilt(im, fs, Stopwatch()..start());
    if (g == null) return {'pitch': 0.0, 'yaw': 0.0, 'base': 0.0, 'score': 0.0, 'ok': false, 'why': 'sedikit'};
    final small = _prepare(a['bytes'] as Uint8List, maxDim: 560, enh: (a['enh'] as int?) ?? 0);
    try {
      double ev(double al, double be) {
        if (sw.elapsed.inSeconds > 24) return -1.0;
        final wp = _warpGray(small.g, small.w, small.h, rotationCorrection(small.w, small.h, al, be, 0, fs), 520);
        if (wp == null) return -1.0;
        return _roundnessScore(wp, Stopwatch()..start());
      }

      final base = ev(0, 0);
      var bestP = g[0], bestY = 0.0;
      var bestS = ev(g[0], 0);
      // tanda yaw ditentukan oleh skor (kedua arah dicoba)
      for (final y in [g[1], -g[1]]) {
        if (y.abs() < 2) continue;
        final v = ev(g[0], y);
        if (v > bestS) {
          bestS = v;
          bestY = y;
        }
      }
      // penyempurnaan pitch
      for (final d in const [-5.0, 5.0]) {
        final v = ev(bestP + d, bestY);
        if (v > bestS) {
          bestS = v;
          bestP = bestP + d;
        }
      }
      final ok = bestS >= base * 0.85 && (bestP.abs() >= 2 || bestY.abs() >= 2);
      return {'pitch': ok ? bestP : 0.0, 'yaw': ok ? bestY : 0.0, 'base': base, 'score': bestS, 'ok': ok, 'gp': g[0], 'gy': g[1]};
    } finally {
      small.dispose();
    }
  } finally {
    im.dispose();
  }
}

/// Kelompokkan radius lalu petakan ke ukuran standar. Hasil: indeks ukuran per lingkaran.
/// refIdx = ukuran pipa terbesar yang jadi patokan, odMm = diameter luar standar (mm).
List<int> classifyRadii(List<double> radii, int refIdx, List<double> odMm) {
  if (radii.isEmpty) return const [];
  final sorted = [...radii]..sort((a, b) => b.compareTo(a));
  final clusters = <List<double>>[];
  for (final r in sorted) {
    if (clusters.isNotEmpty && (clusters.last.first - r) / clusters.last.first < 0.09) {
      clusters.last.add(r);
    } else {
      clusters.add([r]);
    }
  }
  final top = clusters.firstWhere((c) => c.length >= 2, orElse: () => clusters.first);
  final mid = top[top.length ~/ 2];
  final mmPerPx = odMm[refIdx] / (2 * mid);
  return radii.map((r) {
    final od = 2 * r * mmPerPx;
    var bi = 0;
    var bd = 1e9;
    for (var i = 0; i < odMm.length; i++) {
      final d = (math.log(od / odMm[i])).abs();
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    return bi;
  }).toList();
}
