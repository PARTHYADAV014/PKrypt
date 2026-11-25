import 'package:flutter/material.dart';
import 'glass_card.dart';
import 'magnetic_wrapper.dart';
import 'ripple_tap.dart';

/// GlassPillButton — a pill-shaped glass button with centred text label.
/// Has a purple tint by default and supports disabled state.
class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.label,
    this.onTap,
    this.disabled = false,
    this.tintColor,
  });

  final String label;
  final VoidCallback? onTap;
  final bool disabled;

  /// Custom tint colour. Defaults to purple (#7C3AED).
  final Color? tintColor;

  @override
  Widget build(BuildContext context) {
    final effectiveTint = tintColor ?? const Color(0xFF7C3AED);

    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: MagneticWrapper(
        child: RippleTap(
          onTap: disabled ? null : onTap,
          child: GlassCard(
            borderRadius: 999,
            height: 56,
            tintColor: effectiveTint,
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
