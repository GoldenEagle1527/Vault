import 'package:flutter/material.dart';

/// Glass surface tokens (stream_workflow-inspired). Background is solid canvas.
abstract final class GlassTokens {
  /// CSS `--glass-blur: 18px`
  static const double blurSigma = 18;

  /// `--motion-base` / `--ease-out`
  static const Duration motionFast = Duration(milliseconds: 150);
  static const Duration motionBase = Duration(milliseconds: 220);
  static const Curve easeOut = Cubic(0.22, 1.0, 0.36, 1.0);

  /// Active press: `scale(0.985)`
  static const double pressScale = 0.985;

  static Color glassBg(Brightness brightness, {bool strong = false}) {
    if (brightness == Brightness.dark) {
      return Color.fromRGBO(38, 42, 45, strong ? 0.78 : 0.55);
    }
    return Color.fromRGBO(255, 255, 255, strong ? 0.78 : 0.62);
  }

  static Color glassBorder(Brightness brightness) {
    return Colors.white.withValues(
      alpha: brightness == Brightness.dark ? 0.10 : 0.55,
    );
  }

  static List<BoxShadow> glassShadow(ColorScheme scheme) {
    if (scheme.brightness == Brightness.dark) {
      return const [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.45),
          blurRadius: 30,
          offset: Offset(0, 8),
        ),
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.35),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ];
    }
    final tint = scheme.primary;
    return [
      BoxShadow(
        color: tint.withValues(alpha: 0.12),
        blurRadius: 30,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: tint.withValues(alpha: 0.06),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];
  }

  /// Solid page canvas (`--md-background`).
  static Color canvas(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF1A1C1E)
      : const Color(0xFFFDFBFF);
}
