import 'package:flutter/material.dart';

/// Tema industri: biru petrol + aksen jingga, sudut membulat, kontras tinggi.
class AppTheme {
  static const Color seed = Color(0xFF0B6E99);
  static const Color accent = Color(0xFFFF8F00);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: b, secondary: accent);
    final light = b == Brightness.light;
    final bg = light ? const Color(0xFFF2F5F8) : const Color(0xFF0D1217);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: bg,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: cs.onSurface, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 0.2),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape, minimumSize: const Size(48, 46), textStyle: const TextStyle(fontWeight: FontWeight.w700))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape, minimumSize: const Size(48, 46), textStyle: const TextStyle(fontWeight: FontWeight.w600))),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: cs.outlineVariant),
        labelStyle: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface),
        secondaryLabelStyle: TextStyle(fontWeight: FontWeight.w800, color: cs.onSecondaryContainer),
        selectedColor: cs.secondaryContainer,
        checkmarkColor: cs.onSecondaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: light ? Colors.white : const Color(0xFF18202A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
      ),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ),
      sliderTheme: const SliderThemeData(trackHeight: 4, showValueIndicator: ShowValueIndicator.onlyForDiscrete),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }
}

/// Kartu permukaan seragam (tanpa bergantung pada CardTheme agar kompatibel lintas versi Flutter).
class Surface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  const Surface({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: color ?? (light ? Colors.white : const Color(0xFF16202A)),
      borderRadius: BorderRadius.circular(18),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),
      child: InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}
