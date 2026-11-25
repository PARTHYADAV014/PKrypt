import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../core/widgets/magnetic_wrapper.dart';
import '../../core/widgets/ripple_tap.dart';
import '../../data/services/vault_providers.dart';
import 'telegram_login_screen.dart';

class SetupPasswordScreen extends ConsumerStatefulWidget {
  const SetupPasswordScreen({super.key});

  @override
  ConsumerState<SetupPasswordScreen> createState() =>
      _SetupPasswordScreenState();
}

class _SetupPasswordScreenState extends ConsumerState<SetupPasswordScreen> {
  final _passController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  String? _errorText;

  @override
  void dispose() {
    _passController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pass = _passController.text;
    final confirm = _confirmController.text;

    if (pass.length < 8) {
      setState(() =>
          _errorText = 'Password must be at least 8 characters long.');
      return;
    }
    if (pass != confirm) {
      setState(() => _errorText = 'Passwords do not match.');
      return;
    }

    setState(() => _errorText = null);

    try {
      final controller = ref.read(vaultControllerProvider);
      await controller.setupMasterPassword(pass);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/recovery');
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Setup failed: $e');
    }
  }

  void _openCloudRestore() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const TelegramLoginScreen(isCloudRestoreMode: true),
      ),
    );
  }

  InputDecoration _glassInputDecoration({
    required String label,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.cyanAccent),
      ),
      suffixIcon: IconButton(
        icon: Icon(
          obscure ? Icons.visibility_off : Icons.visibility,
          color: Colors.white70,
        ),
        onPressed: onToggle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlowBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 28,
                ),
                borderRadius: 26,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 54,
                      color: Colors.cyanAccent,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Create Master Password',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This password protects your vault key with Argon2id and AES-256. You will receive a 24-character recovery key next.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _passController,
                      obscureText: _obscure1,
                      style: const TextStyle(color: Colors.white),
                      decoration: _glassInputDecoration(
                        label: 'Master Password (min 8 chars)',
                        obscure: _obscure1,
                        onToggle: () =>
                            setState(() => _obscure1 = !_obscure1),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmController,
                      obscureText: _obscure2,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => controller.isBusy ? null : _submit(),
                      decoration: _glassInputDecoration(
                        label: 'Confirm Password',
                        obscure: _obscure2,
                        onToggle: () =>
                            setState(() => _obscure2 = !_obscure2),
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _errorText!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 26),
                    if (controller.isBusy)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: CircularProgressIndicator(
                            color: Colors.cyanAccent,
                          ),
                        ),
                      )
                    else ...[
                      MagneticWrapper(
                        child: RippleTap(
                          onTap: _submit,
                          child: GlassPillButton(
                            label: 'Create Vault',
                            disabled: false,
                            onTap: _submit,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextButton.icon(
                        onPressed: _openCloudRestore,
                        icon: const Icon(
                          Icons.cloud_download_outlined,
                          size: 18,
                          color: Colors.cyanAccent,
                        ),
                        label: const Text(
                          'Restore Existing Cloud Vault',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}