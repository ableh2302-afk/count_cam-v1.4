# Cam Count

Hitung stok pipa nesting (½" – 12") dari foto, 100% offline.

## Fitur
- Kamera: pinch-zoom, preset 1x/2x/3x/5x, tap-fokus, eksposur, flash, grid
- Crop area hitung (sebelum dan sesudah foto dibuka)
- Auto-All, Tap-Match (lingkaran patokan bisa digeser / diubah ukurannya / dipaskan ke bibir pipa), Coret
- Tombol Clear (ukuran aktif / semua, dengan Urungkan)
- Deteksi: voting simetri radial + validasi cincin ketat, lingkaran dipaskan ke bibir pipa
- Auto-All: pilih ukuran apa saja, lalu ketuk 1 pipa contoh untuk tiap ukuran
- Kuas masker: warnai area (bentuk bebas) yang tidak ingin dihitung
- Gaya penanda: 6 gaya, palet warna, opasitas, kebulatan (Basic / Advanced)

Build: push ke `main`, GitHub Actions menghasilkan APK.

## Catatan versi 1.3
- Tap-Match: semua lingkaran hasil scan memakai ukuran lingkaran yang di-TAP (bisa dimatikan di Pengaturan), tanpa saling menimpa
- Coret: zoom/geser 2 jari, mode Tap-Tap (tap titik awal lalu titik akhir = satu garis)
- Kamera: preview tampil lebih cepat, aman saat aplikasi pindah/tertutup sebentar, opsi kualitas Cepat/Standar/4K
- Auto-All: chip ukuran menyaring tampilan lingkaran per ukuran

## Catatan versi 1.4
- Perbaiki foto: Luruskan (perspektif, slider atas-bawah / kiri-kanan / putar + tombol Otomatis), Crop, Kontras (Mati / Sedang / Kuat), Urungkan edit
- Kontras dipakai juga oleh analisis scan (CLAHE + penajaman tepi)
