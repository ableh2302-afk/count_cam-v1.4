import 'dart:math' as math;

/// Matriks 3x3 row-major disimpan sebagai List<double>(9).
List<double> mul3(List<double> a, List<double> b) {
  final r = List<double>.filled(9, 0);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      var s = 0.0;
      for (var k = 0; k < 3; k++) {
        s += a[i * 3 + k] * b[k * 3 + j];
      }
      r[i * 3 + j] = s;
    }
  }
  return r;
}

List<double>? invert3(List<double> m) {
  final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-12) return null;
  final id = 1 / det;
  return [
    (e * i - f * h) * id, (c * h - b * i) * id, (b * f - c * e) * id,
    (f * g - d * i) * id, (a * i - c * g) * id, (c * d - a * f) * id,
    (d * h - e * g) * id, (b * g - a * h) * id, (a * e - b * d) * id,
  ];
}

/// Terapkan homografi; null jika titik berada di belakang kamera / di horizon.
List<double>? applyH(List<double> h, double x, double y) {
  final w = h[6] * x + h[7] * y + h[8];
  if (w <= 1e-9) return null;
  return [(h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w];
}

/// Koreksi perspektif dengan memutar kamera virtual: H = K * R^T * K^-1.
/// alpha = pitch (atas-bawah), beta = yaw (kiri-kanan), gamma = roll (putar), dalam derajat.
/// fs = panjang fokus relatif terhadap sisi terpanjang gambar (tipikal HP ~0.75-0.9).
List<double> rotationCorrection(int w, int h, double alpha, double beta, double gamma, double fs) {
  final a = alpha * math.pi / 180, b = beta * math.pi / 180, g = gamma * math.pi / 180;
  final rx = <double>[1, 0, 0, 0, math.cos(a), -math.sin(a), 0, math.sin(a), math.cos(a)];
  final ry = <double>[math.cos(b), 0, math.sin(b), 0, 1, 0, -math.sin(b), 0, math.cos(b)];
  final rz = <double>[math.cos(g), -math.sin(g), 0, math.sin(g), math.cos(g), 0, 0, 0, 1];
  final r = mul3(mul3(rz, rx), ry);
  final rt = <double>[r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]; // transpos = invers
  final f = fs * math.max(w, h);
  final cx = w / 2, cy = h / 2;
  final k = <double>[f, 0, cx, 0, f, cy, 0, 0, 1];
  final ki = <double>[1 / f, 0, -cx / f, 0, 1 / f, -cy / f, 0, 0, 1];
  return mul3(mul3(k, rt), ki);
}

class Rectified {
  final List<double> h; // homografi sumber -> ruang terluruskan
  final double x0, y0, w, hgt; // persegi terbesar di dalam hasil (ruang terluruskan)
  Rectified(this.h, this.x0, this.y0, this.w, this.hgt);
}

/// Hitung hasil pelurusan + persegi terbesar yang seluruhnya berisi gambar (tanpa tepi hitam).
Rectified? rectify(int w, int h, double alpha, double beta, double gamma, double fs) {
  final hm = rotationCorrection(w, h, alpha, beta, gamma, fs);
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
  var ymin = 1e18, ymax = -1e18, xmin = 1e18, xmax = -1e18;
  for (final p in corners) {
    ymin = math.min(ymin, p[1]);
    ymax = math.max(ymax, p[1]);
    xmin = math.min(xmin, p[0]);
    xmax = math.max(xmax, p[0]);
  }
  final bw = xmax - xmin, bh = ymax - ymin;
  if (!bw.isFinite || !bh.isFinite || bw < 8 || bh < 8 || bw > 40 * w || bh > 40 * h) return null;

  List<double>? span(double y) {
    final xs = <double>[];
    for (var i = 0; i < 4; i++) {
      final p = corners[i], q = corners[(i + 1) % 4];
      final y0 = p[1], y1 = q[1];
      if ((y0 <= y && y <= y1) || (y1 <= y && y <= y0)) {
        if ((y1 - y0).abs() < 1e-9) {
          xs.add(p[0]);
          xs.add(q[0]);
        } else {
          xs.add(p[0] + (q[0] - p[0]) * (y - y0) / (y1 - y0));
        }
      }
    }
    if (xs.length < 2) return null;
    return [xs.reduce(math.min), xs.reduce(math.max)];
  }

  const n = 28;
  final ys = [for (var i = 0; i < n; i++) ymin + bh * (0.002 + 0.996 * i / (n - 1))];
  final lefts = <double>[], rights = <double>[];
  for (final y in ys) {
    final s = span(y);
    lefts.add(s == null ? 1e18 : s[0]);
    rights.add(s == null ? -1e18 : s[1]);
  }
  var best = 0.0;
  double bx0 = xmin, by0 = ymin, bw2 = bw, bh2 = bh;
  for (var i = 0; i < n; i++) {
    var xl = -1e18, xr = 1e18;
    for (var j = i; j < n; j++) {
      xl = math.max(xl, lefts[j]);
      xr = math.min(xr, rights[j]);
      if (xr <= xl) break;
      final area = (xr - xl) * (ys[j] - ys[i]);
      if (area > best) {
        best = area;
        bx0 = xl;
        by0 = ys[i];
        bw2 = xr - xl;
        bh2 = ys[j] - ys[i];
      }
    }
  }
  if (best <= 0 || bw2 < 8 || bh2 < 8) return null;
  return Rectified(hm, bx0, by0, bw2, bh2);
}

/// Homografi sumber -> kanvas hasil: translasi ke (x0,y0), lalu skala s.
List<double> toCanvas(Rectified r, double s) => mul3(<double>[s, 0, -s * r.x0, 0, s, -s * r.y0, 0, 0, 1], r.h);
