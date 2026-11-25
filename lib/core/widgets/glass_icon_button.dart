import 'package:flutter/material.dart';
import 'glass_card.dart';
import 'magnetic_wrapper.dart';
import 'ripple_tap.dart';

/// GlassIconButton — a circular 56dp glass button with a centred icon.
/// Supports magnetic hover tilt and tap ripple.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
  });

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MagneticWrapper(
      child: RippleTap(
        onTap: onTap,
        child: GlassCard(
          borderRadius: 999,
          width: 56,
          height: 56,
          padding: EdgeInsets.zero,
          child: Center(
            child: Icon(
              icon,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
