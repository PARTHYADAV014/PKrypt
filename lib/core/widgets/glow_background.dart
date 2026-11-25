import 'package:flutter/material.dart';

/// GlowBackground - lightweight, GPU-friendly ambient neon backdrop.
/// Uses pre-blended RadialGradients inside a static RepaintBoundary instead of
/// per-frame full-screen Gaussian blurs so 90Hz/120Hz scrolling stays locked.
class GlowBackground extends StatelessWidget {
  const GlowBackground({
    super.key,
    required this.child,
  });

  final Widget child;

  static const _darkBase = Color(0xFF0A0A1A);
  static const _lightBase = Color(0xFFF0F0FF);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? _darkBase : _lightBase;
    final purple = isDark ? const Color(0xFF7C3AED) : const Color(0xFFB794F4);
    final cyan = isDark ? const Color(0xFF06B6D4) : const Color(0xFF67E8F9);
    final pink = isDark ? const Color(0xFFEC4899) : const Color(0xFFF9A8D4);
    final peakAlpha = isDark ? 0.24 : 0.30;

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(color: baseColor),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _AmbientGlow(
                  alignment: const Alignment(-0.95, -0.90),
                  radius: 0.95,
                  color: purple.withValues(alpha: peakAlpha),
                ),
                _AmbientGlow(
                  alignment: const Alignment(0.95, -0.75),
                  radius: 0.85,
                  color: cyan.withValues(alpha: peakAlpha * 0.9),
                ),
                _AmbientGlow(
                  alignment: const Alignment(0.05, 0.95),
                  radius: 1.0,
                  color: pink.withValues(alpha: peakAlpha * 0.8),
                ),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _AmbientGlow extends StatelessWidget {
  final Alignment alignment;
  final double radius;
  final Color color;

  const _AmbientGlow({
    required this.alignment,
    required this.radius,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: alignment,
          radius: radius,
          colors: [
            color,
            color.withValues(alpha: color.a * 0.35),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
    );
  }
}