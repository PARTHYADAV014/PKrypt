import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../core/widgets/magnetic_wrapper.dart';
import '../../core/widgets/ripple_tap.dart';
import '../../data/services/vault_providers.dart';

ImageFilter _blurFilter(double sigma) =>
    ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal);

class RecoveryPhraseScreen extends ConsumerStatefulWidget {
  const RecoveryPhraseScreen({
    super.key,
    this.phrase,
    this.wipeCode,
  });

  final String? phrase;
  final String? wipeCode;

  @override
  ConsumerState<RecoveryPhraseScreen> createState() =>
      _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends ConsumerState<RecoveryPhraseScreen> {
  bool _confirmed = false;
  bool _copied = false;

  String _activeRecoveryKey(String? liveKey) {
    if (liveKey != null && liveKey.trim().isNotEmpty) return liveKey.trim();
    if (widget.phrase != null && widget.phrase!.trim().isNotEmpty) {
      return widget.phrase!.trim();
    }
    return 'KEY-NOT-GENERATED';
  }

  String _activeWipeCode(String? liveWipe) {
    if (liveWipe != null && liveWipe.trim().isNotEmpty) return liveWipe.trim();
    if (widget.wipeCode != null && widget.wipeCode!.trim().isNotEmpty) {
      return widget.wipeCode!.trim();
    }
    return 'WIPE-VAULT';
  }

  List<String> _splitParts(String value) {
    if (value.contains('-')) {
      return value.split('-').where((e) => e.isNotEmpty).toList();
    }
    return value.split(' ').where((e) => e.isNotEmpty).toList();
  }

  Future<void> _copyKey(String keyText) async {
    await Clipboard.setData(ClipboardData(text: keyText));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recovery key copied. Write it down safely and clear your clipboard.'),
      ),
    );
  }

  void _onContinue() {
    if (!_confirmed) return;
    ref.read(vaultControllerProvider).clearPendingRecoverySecrets();
    Navigator.of(context).pushReplacementNamed('/telegram');
  }

  Widget _progressPill() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: _blurFilter(20),
        child: Container(
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: const LinearProgressIndicator(
              value: 0.66,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF7C3AED)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _warningBanner() {
    return GlassCard(
      tintColor: Colors.amber,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.amber, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Never share this 24-character master recovery key. It is the only way to recover your vault if you forget your password.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.90),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyGrid(String recoveryKey) {
    final parts = _splitParts(recoveryKey);
    final crossAxisCount = parts.length <= 6 ? 2 : 3;

    return Column(
      children: [
        GridView.count(
          crossAxisCount: crossAxisCount,
          childAspectRatio: crossAxisCount == 2 ? 3.2 : 2.5,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(parts.length, (i) {
            return GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              borderRadius: 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${i + 1}. ',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    parts[i],
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 16,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () => _copyKey(recoveryKey),
          icon: Icon(
            _copied ? Icons.check_circle_outline : Icons.copy_rounded,
            size: 18,
            color: Colors.cyanAccent,
          ),
          label: Text(
            _copied ? 'Copied to Clipboard' : 'Copy Recovery Key',
            style: const TextStyle(color: Colors.cyanAccent),
          ),
        ),
      ],
    );
  }

  Widget _wipeCodeCard(String wipeCode) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      tintColor: const Color(0xFF06B6D4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Remote Wipe Code',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            wipeCode,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'If your phone is lost or stolen, send this code to Telegram Saved Messages to wipe the vault.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _acknowledgement(Color textColor) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: CheckboxListTile(
        dense: true,
        value: _confirmed,
        onChanged: (v) => setState(() => _confirmed = v ?? false),
        title: Text(
          'I have securely written down my 24-character recovery key',
          style: TextStyle(
            color: textColor.withValues(alpha: 0.85),
            fontSize: 13,
            height: 1.4,
          ),
        ),
        activeColor: const Color(0xFF7C3AED),
        checkColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final recoveryKey = _activeRecoveryKey(controller.pendingRecoveryKey);
    final wipeCode = _activeWipeCode(controller.pendingWipeCode);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A2E);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GlowBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _progressPill(),
                const SizedBox(height: 28),
                Text(
                  'Save Your Recovery Key',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 24,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This 24-character key unlocks your vault key and restores access if you forget your password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.65),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                _warningBanner(),
                const SizedBox(height: 22),
                _keyGrid(recoveryKey),
                const SizedBox(height: 18),
                _wipeCodeCard(wipeCode),
                const SizedBox(height: 20),
                _acknowledgement(textColor),
                const SizedBox(height: 22),
                MagneticWrapper(
                  child: RippleTap(
                    onTap: _confirmed ? _onContinue : null,
                    child: GlassPillButton(
                      label: 'Continue',
                      disabled: !_confirmed,
                      onTap: _confirmed ? _onContinue : null,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}