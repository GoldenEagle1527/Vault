import 'package:flutter/material.dart';

/// MD3 seed colors matching `docs/ui-references`.
enum VaultAccent {
  /// Stream Workflow primary (`#0061a4`).
  blue(Color(0xFF0061A4), '溪流蓝'),
  purple(Color(0xFF65558F), '柔和紫'),
  teal(Color(0xFF006B5E), '安心绿'),
  orange(Color(0xFF8C4F00), '活力橙');

  const VaultAccent(this.seed, this.label);
  final Color seed;
  final String label;
}

abstract final class AppTheme {
  static ThemeData light(VaultAccent accent) =>
      _build(accent, Brightness.light);

  static ThemeData dark(VaultAccent accent) => _build(accent, Brightness.dark);

  static ThemeData _build(VaultAccent accent, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    // Align canvas with stream_workflow `--md-background` so glass reads clearly.
    final canvas = dark ? const Color(0xFF1A1C1E) : const Color(0xFFFDFBFF);
    final tuned = scheme.copyWith(
      surface: canvas,
      surfaceContainerLowest: dark
          ? const Color(0xFF0F1113)
          : const Color(0xFFFFFFFF),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: tuned,
      scaffoldBackgroundColor: Colors.transparent,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: tuned.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: tuned.secondaryContainer.withValues(alpha: 0.85),
        selectedIconTheme: IconThemeData(color: tuned.onSecondaryContainer),
        selectedLabelTextStyle: TextStyle(
          color: tuned.onSecondaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedIconTheme: IconThemeData(color: tuned.onSurfaceVariant),
        unselectedLabelTextStyle: TextStyle(
          color: tuned.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: tuned.secondaryContainer.withValues(alpha: 0.9),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? tuned.onSecondaryContainer
                : tuned.onSurfaceVariant,
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tuned.surface.withValues(alpha: dark ? 0.86 : 0.92),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const StadiumBorder(),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const StadiumBorder(),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tuned.surfaceContainer.withValues(alpha: dark ? 0.55 : 0.72),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tuned.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tuned.primary, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(
          color: Colors.white.withValues(alpha: dark ? 0.10 : 0.45),
        ),
        backgroundColor: Colors.white.withValues(alpha: dark ? 0.08 : 0.35),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
