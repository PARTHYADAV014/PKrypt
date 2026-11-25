import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/widgets/pulse_widget.dart';
import '../../../core/widgets/ripple_tap.dart';

/// PersonTile — a vertical card representing a person / face cluster.
///
/// Shows a pulsing circular avatar (image or icon fallback), the person's
/// [name], and a [mediaCount] subtitle. Tapping fires [onTap].
class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.name,
    this.avatarBytes,
    required this.mediaCount,
    required this.onTap,
  });

  final String name;
  final Uint8List? avatarBytes;
  final int mediaCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return RippleTap(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Avatar ────────────────────────────────────────────────────────
          PulseWidget(
            child: CircleAvatar(
              radius: 40,
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              backgroundImage: avatarBytes != null
                  ? MemoryImage(avatarBytes!)
                  : null,
              child: avatarBytes == null
                  ? const Icon(
                      Icons.person_rounded,
                      size: 40,
                      color: Colors.white70,
                    )
                  : null,
            ),
          ),

          const SizedBox(height: 8),

          // ── Name ──────────────────────────────────────────────────────────
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),

          const SizedBox(height: 2),

          // ── Media count ───────────────────────────────────────────────────
          Text(
            '$mediaCount items',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.54),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}
