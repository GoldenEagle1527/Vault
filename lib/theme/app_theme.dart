import 'package:flutter/cupertino.dart';
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
  /// Bundled Noto Sans SC (variable `wght`). File default instance is Thin (100).
  static const fontFamily = 'NotoSansSC';

  /// UI default is Regular — file default is Thin.
  static const defaultWeight = FontWeight.w400;

  static const fontFamilyFallback = <String>[
    'Segoe UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Color Emoji',
  ];

  static List<FontVariation> weightAxis([FontWeight? weight]) => [
    FontVariation.weight((weight ?? defaultWeight).value.toDouble()),
  ];

  static ThemeData light(VaultAccent accent) =>
      _build(accent, Brightness.light);

  static ThemeData dark(VaultAccent accent) => _build(accent, Brightness.dark);

  static TextStyle _uiStyle({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    final weight = fontWeight ?? defaultWeight;
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: weight,
      fontVariations: weightAxis(weight),
    );
  }

  static TextTheme _applyFont(TextTheme theme) {
    TextStyle pin(TextStyle? style) {
      final weight = style?.fontWeight ?? defaultWeight;
      return (style ?? const TextStyle()).copyWith(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontWeight: weight,
        fontVariations: weightAxis(weight),
      );
    }

    return TextTheme(
      displayLarge: pin(theme.displayLarge),
      displayMedium: pin(theme.displayMedium),
      displaySmall: pin(theme.displaySmall),
      headlineLarge: pin(theme.headlineLarge),
      headlineMedium: pin(theme.headlineMedium),
      headlineSmall: pin(theme.headlineSmall),
      titleLarge: pin(theme.titleLarge),
      titleMedium: pin(theme.titleMedium),
      titleSmall: pin(theme.titleSmall),
      bodyLarge: pin(theme.bodyLarge),
      bodyMedium: pin(theme.bodyMedium),
      bodySmall: pin(theme.bodySmall),
      labelLarge: pin(theme.labelLarge),
      labelMedium: pin(theme.labelMedium),
      labelSmall: pin(theme.labelSmall),
    );
  }

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
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: tuned,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
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
        selectedLabelTextStyle: _uiStyle(
          color: tuned.onSecondaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedIconTheme: IconThemeData(color: tuned.onSurfaceVariant),
        unselectedLabelTextStyle: _uiStyle(
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
          return _uiStyle(
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
    return theme.copyWith(
      textTheme: _applyFont(theme.textTheme),
      primaryTextTheme: _applyFont(theme.primaryTextTheme),
    );
  }
}
