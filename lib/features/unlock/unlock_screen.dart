import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/vault_providers.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _passController = TextEditingController();
  bool _obscure = true;
  bool _biometricEnabled = false;
  bool _isUnlocking = false;
  bool _autoBiometricAttempted = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initBiometricsAndAutoPrompt());
    });
  }

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  void _navigateAfterUnlock() {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode || controller.primaryChannel != null) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/gallery', (route) => false);
    } else if (controller.isTelegramReady) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/channel_select', (route) => false);
    } else {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/telegram', (route) => false);
    }
  }

  Future<void> _initBiometricsAndAutoPrompt() async {
    if (_autoBiometricAttempted) return;
    _autoBiometricAttempted = true;

    try {
      final controller = ref.read(vaultControllerProvider);
      final enabled = await controller.isBiometricEnabled();
      if (!mounted) return;
      setState(() => _biometricEnabled = enabled);

      if (enabled) {
        // Wait briefly so Android window has full focus before showing BiometricPrompt
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted || _isUnlocking) return;
        await _unlockBiometric(isAuto: true);
      }
    } catch (_) {}
  }

  Future<void> _unlockPassword() async {
    if (_isUnlocking) return;
    final pass = _passController.text;
    if (pass.isEmpty) {
      setState(() => _errorText = 'Please enter your master password.');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isUnlocking = true;
      _errorText = null;
    });

    try {
      final controller = ref.read(vaultControllerProvider);
      final ok = await controller.unlockWithPassword(pass).timeout(
            const Duration(seconds: 30),
            onTimeout: () => false,
          );

      if (!mounted) return;
      if (ok) {
        _navigateAfterUnlock();
        return;
      }
      setState(() {
        _errorText = controller.lastError ?? 'Incorrect password.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Unlock error: $e');
    } finally {
      if (mounted) {
        setState(() => _isUnlocking = false);
      }
    }
  }

  Future<void> _unlockBiometric({bool isAuto = false}) async {
    if (_isUnlocking) return;
    setState(() {
      _isUnlocking = true;
      _errorText = null;
    });

    try {
      final controller = ref.read(vaultControllerProvider);
      final ok = await controller.unlockWithBiometrics().timeout(
            const Duration(seconds: 25),
            onTimeout: () => false,
          );

      if (!mounted) return;
      if (ok) {
        _navigateAfterUnlock();
        return;
      }
      if (!isAuto) {
        setState(
          () => _errorText = controller.lastError ?? 'Biometric unlock failed.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (!isAuto) {
        setState(() => _errorText = 'Biometric error: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isUnlocking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06070B),
      body: Stack(
        children: [
          Positioned(
            top: -80,
            left: -60,
            child: _GlowOrb(
              size: 260,
              color: Colors.cyanAccent.withValues(alpha: 0.22),
            ),
          ),
          Positioned(
            bottom: -90,
            right: -70,
            child: _GlowOrb(
              size: 280,
              color: const Color(0xFF5E5CE6).withValues(alpha: 0.25),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 30,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.12),
                            Colors.white.withValues(alpha: 0.04),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: 68,
                            height: 68,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.cyanAccent.withValues(alpha: 0.12),
                              border: Border.all(
                                color: Colors.cyanAccent.withValues(alpha: 0.35),
                              ),
                            ),
                            child: const Icon(
                              Icons.lock_outline_rounded,
                              size: 34,
                              color: Colors.cyanAccent,
                            ),
                          ),
                          const Text(
                            'Unlock Vault',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _biometricEnabled
                                ? 'Use biometrics or enter your master password.'
                                : 'Enter your master password to unlock your encrypted vault.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                          const SizedBox(height: 26),
                          TextField(
                            controller: _passController,
                            obscureText: _obscure,
                            enabled: !_isUnlocking,
                            style: const TextStyle(color: Colors.white),
                            onSubmitted: (_) => _unlockPassword(),
                            decoration: InputDecoration(
                              labelText: 'Master Password',
                              labelStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: 0.07),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.14),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(
                                  color: Colors.cyanAccent,
                                ),
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: Colors.white70,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                          ),
                          if (_errorText != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _errorText!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          SizedBox(
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _isUnlocking ? null : _unlockPassword,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.cyanAccent,
                                foregroundColor: Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: _isUnlocking
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Text(
                                      'Unlock with Password',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _isUnlocking
                                ? null
                                : () => _unlockBiometric(isAuto: false),
                            icon: const Icon(
                              Icons.fingerprint,
                              color: Colors.cyanAccent,
                            ),
                            label: const Text(
                              'Use Biometrics',
                              style: TextStyle(color: Colors.white),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.05),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: _isUnlocking
                                ? null
                                : () =>
                                    Navigator.of(context).pushNamed('/recover'),
                            child: Text(
                              'Forgot Password? Recover Vault',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
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
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: size * 1.6,
        height: size * 1.6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}