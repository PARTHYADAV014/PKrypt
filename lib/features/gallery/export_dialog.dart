import 'package:flutter/material.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';

// ─── Checkbox wrapper (needs local state) ────────────────────────────────────

class _DontShowCheckbox extends StatefulWidget {
  const _DontShowCheckbox();

  @override
  State<_DontShowCheckbox> createState() => _DontShowCheckboxState();
}

class _DontShowCheckboxState extends State<_DontShowCheckbox> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _checked = !_checked),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: _checked,
              onChanged: (v) => setState(() => _checked = v ?? false),
              activeColor: const Color(0xFF7C3AED),
              checkColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.45)),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            "Don't show this again",
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Main dialog widget ──────────────────────────────────────────────────────

/// Shows an export-warning dialog with a glass card surface.
/// Returns [true] via [Navigator.pop] when "Download" is tapped,
/// [false] when "Cancel" is tapped.
class ExportWarningDialog extends StatelessWidget {
  const ExportWarningDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Transparent — the GlassCard provides all visual styling.
      backgroundColor: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      contentPadding: EdgeInsets.zero,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      content: GlassCard(
        padding: const EdgeInsets.all(24),
        borderRadius: 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1 ── Warning icon
            const Icon(
              Icons.warning_amber_rounded,
              size: 48,
              color: Colors.amber,
            ),

            const SizedBox(height: 16),

            // 3 ── Title
            const Text(
              'Download Unencrypted?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 12),

            // 5 ── Body
            Text(
              "This file will be saved to your phone's gallery unencrypted. "
              'Anyone with access to your device can view it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                fontSize: 14,
                height: 1.5,
              ),
            ),

            const SizedBox(height: 16),

            // 7 ── Checkbox
            const _DontShowCheckbox(),

            const SizedBox(height: 24),

            // 9 ── Action row
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GlassPillButton(
                    label: 'Download',
                    tintColor: const Color(0xFF7C3AED),
                    onTap: () => Navigator.pop(context, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
