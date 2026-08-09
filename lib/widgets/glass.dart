import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:vault/theme/glass_tokens.dart';

bool vaultReduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// Solid theme canvas behind the UI (no ambient effects).
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final canvas = GlassTokens.canvas(Theme.of(context).brightness);
    return ColoredBox(color: canvas, child: child);
  }
}

enum GlassTone { regular, strong, tinted }

/// Frosted glass — stream_workflow `.glass` / `.glass-strong`.
///
/// Flat rgba fill, blur 18, hairline border, primary-tinted shadow.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.padding,
    this.tone = GlassTone.regular,
    this.tint,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final GlassTone tone;
  final Color? tint;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final radius = BorderRadius.circular(borderRadius);
    final strong = tone == GlassTone.strong;
    final base = GlassTokens.glassBg(brightness, strong: strong);
    final fill = tint == null
        ? base
        : Color.alphaBlend(tint!.withValues(alpha: 0.28), base);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: GlassTokens.glassShadow(scheme),
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: GlassTokens.blurSigma,
            sigmaY: GlassTokens.blurSigma,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: Border.all(color: GlassTokens.glassBorder(brightness)),
            ),
            child: padding == null
                ? child
                : Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

/// Press feedback: scale to 0.985 (stream `active-scale`).
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final reduce = vaultReduceMotion(context);
    final scale = !widget.enabled || reduce
        ? 1.0
        : (_pressed ? GlassTokens.pressScale : 1.0);
    final lift = !widget.enabled || reduce || _pressed
        ? 0.0
        : (_hovered ? -1.0 : 0.0);

    return MouseRegion(
      onEnter: widget.enabled && !reduce
          ? (_) => setState(() => _hovered = true)
          : null,
      onExit: widget.enabled && !reduce
          ? (_) => setState(() => _hovered = false)
          : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        onTapDown: widget.enabled && !reduce
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.enabled && !reduce
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: widget.enabled && !reduce
            ? () => setState(() => _pressed = false)
            : null,
        child: AnimatedContainer(
          duration: GlassTokens.motionFast,
          curve: GlassTokens.easeOut,
          transform: Matrix4.translationValues(0, lift, 0),
          transformAlignment: Alignment.center,
          child: AnimatedScale(
            scale: scale,
            duration: GlassTokens.motionFast,
            curve: GlassTokens.easeOut,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Staggered card entrance — stream `card-in` keyframe.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (vaultReduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 220 + (index.clamp(0, 6) * 40)),
      curve: GlassTokens.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
