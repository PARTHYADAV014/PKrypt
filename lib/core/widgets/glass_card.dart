import 'dart:ui';
import 'package:flutter/material.dart';
import 'ripple_tap.dart';

/// GlassCard - frosted glass card with optional backdrop blur.
/// Set enableBlur: false inside scrollable grids/lists for locked 90/120fps.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.width,
    this.height,
    this.borderRadius = 24,
    this.tintColor,
    this.onTap,
    this.enableBlur = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final double? width;
  final double? height;
  final double borderRadius;
  final Color? tintColor;
  final VoidCallback? onTap;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final Color surfaceColor = tintColor != null
        ? tintColor!.withValues(alpha: enableBlur ? 0.24 : 0.20)
        : Colors.white.withValues(alpha: enableBlur ? 0.08 : 0.09);

    Widget inner = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            surfaceColor,
            Colors.black.withValues(alpha: enableBlur ? 0.22 : 0.34),
          ],
        ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.20),
          width: 1,
        ),
      ),
      child: child,
    );

    if (enableBlur) {
      inner = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: inner,
      );
    }

    Widget card = RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: inner,
      ),
    );

    if (onTap != null) {
      card = RippleTap(
        onTap: onTap,
        child: card,
      );
    }

    return margin != null ? Container(margin: margin, child: card) : card;
  }
}