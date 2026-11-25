import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/widgets/ripple_tap.dart';

/// PhotoTile — a compact grid cell for a single photo or video.
///
/// Displays [imageBytes] when available, falls back to a lightweight solid
/// placeholder (no BackdropFilter — safe inside high-frequency scroll grids).
/// Overlays a play icon + duration badge for videos, and a blue selection
/// overlay + checkmark when [isSelected] is true.
class PhotoTile extends StatelessWidget {
  const PhotoTile({
    super.key,
    this.imageBytes,
    this.isVideo = false,
    this.duration,
    this.isSelected = false,
    this.onTap,
  });

  final Uint8List? imageBytes;
  final bool isVideo;
  final Duration? duration;
  final bool isSelected;
  final VoidCallback? onTap;

  // ── Duration formatter (e.g. 83 s → "1:23") ────────────────────────────

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    Widget tile = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Base layer: image or solid lightweight placeholder ─────────────
          if (imageBytes != null)
            Image.memory(
              imageBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          else
            // Solid color placeholder — NO BackdropFilter inside scroll grids.
            // A blur here would trigger full-screen compositing on every frame.
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
            ),

          // ── Video overlay: play icon + duration badge ──────────────────────
          if (isVideo) ...[
            // Semi-transparent darkening scrim
            const ColoredBox(color: Color(0x33000000)),

            // Centred play icon
            const Center(
              child: Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
                size: 32,
                shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
              ),
            ),

            // Duration badge — bottom-right
            if (duration != null)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _formatDuration(duration!),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
          ],

          // ── Selection overlay + checkmark ──────────────────────────────────
          if (isSelected) ...[
            // Blue tint overlay
            ColoredBox(
              color: const Color(0xFF2563EB).withValues(alpha: 0.40),
            ),

            // Checkmark badge — top-right
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Color(0xFF2563EB),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    // Wrap in RippleTap only when a callback is provided.
    if (onTap != null) {
      tile = RippleTap(onTap: onTap, child: tile);
    }

    return tile;
  }
}
