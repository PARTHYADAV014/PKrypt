import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/widgets/floating_widget.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/services/telegram_service.dart';
import '../../data/services/vault_providers.dart';
import 'cloud_restore_screen.dart';

class TelegramLoginScreen extends ConsumerStatefulWidget {
  final bool isCloudRestoreMode;

  const TelegramLoginScreen({
    super.key,
    this.isCloudRestoreMode = false,
  });

  @override
  ConsumerState<TelegramLoginScreen> createState() =>
      _TelegramLoginScreenState();
}

class _TelegramLoginScreenState extends ConsumerState<TelegramLoginScreen> {
  final _apiIdController = TextEditingController();
  final _apiHashController = TextEditingController();
  final _phoneController = TextEditingController(text: '+91');
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();

  StreamSubscription<TelegramAuthStatus>? _authSub;
  TelegramAuthStatus _status = TelegramAuthStatus.uninitialized;
  bool _loading = false;
  bool _needsManualApiKeys = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final tg = ref.read(vaultControllerProvider).telegramService;
    _status = tg.authStatus;
    _authSub = tg.authStatusStream.listen((newStatus) {
      if (!mounted) return;
      setState(() {
        _status = newStatus;
        _loading = false;
      });
    });
    _autoStartTdlib();
  }

  Future<void> _autoStartTdlib() async {
    final tg = ref.read(vaultControllerProvider).telegramService;
    final creds = await tg.getSavedApiCredentials();

    if (creds == null) {
      if (!mounted) return;
      setState(() => _needsManualApiKeys = true);
      return;
    }

    _apiIdController.text = creds.apiId.toString();
    _apiHashController.text = creds.apiHash;

    if (tg.isReady) return;

    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbDir = '${docsDir.path}${Platform.pathSeparator}tdlib_db';
      final filesDir = '${docsDir.path}${Platform.pathSeparator}tdlib_files';
      await tg.start(
        databaseDirectory: dbDir,
        filesDirectory: filesDir,
        credentials: creds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = 'Telegram connect error: $e';
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _apiIdController.dispose();
    _apiHashController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connectTdlibManually() async {
    final apiId = int.tryParse(_apiIdController.text.trim());
    final apiHash = _apiHashController.text.trim();
    if (apiId == null || apiId <= 0 || apiHash.isEmpty) {
      setState(() => _errorText = 'Please enter a valid API ID and API Hash.');
      return;
    }

    setState(() {
      _loading = true;
      _errorText = null;
      _needsManualApiKeys = false;
    });

    try {
      final tg = ref.read(vaultControllerProvider).telegramService;
      await tg.saveApiCredentials(apiId, apiHash);
      final docsDir = await getApplicationDocumentsDirectory();
      final dbDir = '${docsDir.path}${Platform.pathSeparator}tdlib_db';
      final filesDir = '${docsDir.path}${Platform.pathSeparator}tdlib_files';
      await tg.start(databaseDirectory: dbDir, filesDirectory: filesDir);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = 'Telegram connect error: $e';
      });
    }
  }

  Future<void> _submitPhone() async {
    final phone = _phoneController.text.trim();
    if (phone.length < 6) {
      setState(() => _errorText =
          'Please enter your phone number with country code (e.g. +91...).');
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ref
          .read(vaultControllerProvider)
          .telegramService
          .submitPhoneNumber(phone);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = e.toString();
      });
    }
  }

  Future<void> _submitOtp() async {
    final code = _otpController.text.trim();
    if (code.isEmpty) {
      setState(() => _errorText = 'Please enter the OTP code sent to Telegram.');
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ref
          .read(vaultControllerProvider)
          .telegramService
          .submitOtpCode(code);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = e.toString();
      });
    }
  }

  Future<void> _submit2fa() async {
    final pass = _passwordController.text;
    if (pass.isEmpty) {
      setState(() => _errorText = 'Please enter your 2FA password.');
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ref
          .read(vaultControllerProvider)
          .telegramService
          .submitTwoFactorPassword(pass);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = e.toString();
      });
    }
  }

  InputDecoration _glassInput(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.08),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.cyanAccent, width: 1.4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tg = ref.read(vaultControllerProvider).telegramService;

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            widget.isCloudRestoreMode
                ? 'Telegram Cloud Restore'
                : 'Telegram Cloud',
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: FloatingWidget(
                amplitude: 6,
                durationMs: 3200,
                child: GlassCard(
                  borderRadius: 28,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF2AABEE)
                                .withValues(alpha: 0.18),
                            border: Border.all(
                              color: const Color(0xFF2AABEE)
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Icon(
                            Icons.send_rounded,
                            size: 32,
                            color: Color(0xFF2AABEE),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (_status == TelegramAuthStatus.ready) ...[
                        const Icon(
                          Icons.check_circle_outline,
                          color: Colors.greenAccent,
                          size: 56,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Telegram Connected!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.isCloudRestoreMode
                              ? 'Select your Vault Channel next to decrypt and restore your photos.'
                              : 'Your encrypted cloud transport is active.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 24),
                        GlassPillButton(
                          label: widget.isCloudRestoreMode
                              ? 'Choose Channel & Restore'
                              : 'Select Vault Channels',
                          tintColor: const Color(0xFF06B6D4),
                          onTap: () {
                            if (widget.isCloudRestoreMode) {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => const CloudRestoreScreen(),
                                ),
                              );
                            } else {
                              Navigator.of(context)
                                  .pushReplacementNamed('/channel_select');
                            }
                          },
                        ),
                      ] else if (_status ==
                          TelegramAuthStatus.waitingPhoneNumber) ...[
                        const Text(
                          'Telegram Cloud Login',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Enter your phone number with country code',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: Colors.white),
                          decoration: _glassInput(
                            'Phone Number',
                            hint: '+919876543210',
                          ),
                        ),
                        const SizedBox(height: 20),
                        GlassPillButton(
                          label: _loading ? 'Sending...' : 'Send OTP',
                          disabled: _loading,
                          onTap: _submitPhone,
                        ),
                      ] else if (_status == TelegramAuthStatus.waitingCode) ...[
                        const Text(
                          'Verify OTP',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Enter the login code sent to your Telegram app',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: _otpController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _glassInput('OTP Code', hint: '12345'),
                        ),
                        const SizedBox(height: 20),
                        GlassPillButton(
                          label: _loading ? 'Verifying...' : 'Verify OTP',
                          disabled: _loading,
                          onTap: _submitOtp,
                        ),
                      ] else if (_status ==
                          TelegramAuthStatus.waitingPassword) ...[
                        const Text(
                          '2-Step Verification',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          (tg.passwordHint != null &&
                                  tg.passwordHint!.isNotEmpty)
                              ? 'Hint: ${tg.passwordHint}'
                              : 'Enter your Telegram 2FA cloud password',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: _glassInput('2FA Cloud Password'),
                        ),
                        const SizedBox(height: 20),
                        GlassPillButton(
                          label: _loading ? 'Verifying...' : 'Complete Login',
                          disabled: _loading,
                          onTap: _submit2fa,
                        ),
                      ] else if (_needsManualApiKeys) ...[
                        const Text(
                          'Telegram API Setup',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _apiIdController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _glassInput('Telegram API ID'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _apiHashController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _glassInput('Telegram API Hash'),
                        ),
                        const SizedBox(height: 20),
                        GlassPillButton(
                          label: _loading ? 'Connecting...' : 'Connect',
                          disabled: _loading,
                          onTap: _connectTdlibManually,
                        ),
                      ] else ...[
                        const SizedBox(height: 8),
                        const Center(
                          child: CircularProgressIndicator(
                            color: Colors.cyanAccent,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Connecting to Telegram engine...',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                      if (_errorText != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
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
      ),
    );
  }
}