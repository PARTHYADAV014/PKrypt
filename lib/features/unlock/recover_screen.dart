import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../core/widgets/magnetic_wrapper.dart';
import '../../core/widgets/ripple_tap.dart';
import '../../data/services/vault_providers.dart';

class RecoverScreen extends ConsumerStatefulWidget {
  const RecoverScreen({super.key});

  @override
  ConsumerState<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends ConsumerState<RecoverScreen> {
  final _keyController = TextEditingController();
  final _newPassController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  String? _errorText;

  @override
  void dispose() {
    _keyController.dispose();
    _newPassController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final key = _keyController.text.trim();
    final newPass = _newPassController.text;
    final confirm = _confirmController.text;

    if (key.replaceAll('-', '').length < 16) {
      setState(() => _errorText = 'Please enter a valid 24-character recovery key.');
      return;
    }
    if (newPass.length < 8) {
      setState(() =>
          _errorText = 'New password must be at least 8 characters long.');
      return;
    }
    if (newPass != confirm) {
      setState(() => _errorText = 'New passwords do not match.');
      return;
    }

    setState(() => _errorText = null);
    final controller = ref.read(vaultControllerProvider);
    final ok = await controller.recoverVaultWithKey(
      recoveryKey: key,
      newPassword: newPass,
    );

    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vault recovered and new password set.'),
        ),
      );
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/telegram', (route) => false);
    } else {
      setState(() => _errorText =
          controller.lastError ?? 'Invalid recovery key. Please check and try again.');
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
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
      suffixIcon: suffixIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Recover Vault'),
      ),
      body: GlowBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 26,
                ),
                borderRadius: 26,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.vpn_key_rounded,
                      size: 46,
                      color: Colors.cyanAccent,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Master Key Recovery',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Enter your 24-character recovery key and set a new master password. Your data will remain safe.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _keyController,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontFamily: 'monospace',
                        letterSpacing: 1.2,
                      ),
                      decoration: _inputDecoration(
                        label: '24-Character Recovery Key',
                        hint: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _newPassController,
                      obscureText: _obscure1,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration(
                        label: 'New Master Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure1 ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white70,
                          ),
                          onPressed: () =>
                              setState(() => _obscure1 = !_obscure1),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmController,
                      obscureText: _obscure2,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => controller.isBusy ? null : _recover(),
                      decoration: _inputDecoration(
                        label: 'Confirm New Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure2 ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white70,
                          ),
                          onPressed: () =>
                              setState(() => _obscure2 = !_obscure2),
                        ),
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
                    const SizedBox(height: 24),
                    if (controller.isBusy)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: CircularProgressIndicator(
                            color: Colors.cyanAccent,
                          ),
                        ),
                      )
                    else
                      MagneticWrapper(
                        child: RippleTap(
                          onTap: _recover,
                          child: GlassPillButton(
                            label: 'Recover & Reset Password',
                            disabled: false,
                            onTap: _recover,
                          ),
                        ),
                      ),
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