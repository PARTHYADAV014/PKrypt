import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../data/services/tdlib_service.dart';

class TelegramLoginScreen extends StatefulWidget {
  const TelegramLoginScreen({super.key});

  @override
  State<TelegramLoginScreen> createState() => _TelegramLoginScreenState();
}

class _TelegramLoginScreenState extends State<TelegramLoginScreen> {
  final _phoneController = TextEditingController(text: '+91');
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();

  TelegramAuthState _state = TelegramAuthState.initializing;
  bool _loading = false;

  StreamSubscription<TelegramAuthState>? _authSub;
  StreamSubscription<String>? _errSub;

  @override
  void initState() {
    super.initState();
    _startTdlib();
  }

  Future<void> _startTdlib() async {
    final td = TdlibService.instance;

    _authSub = td.authStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });

      if (state == TelegramAuthState.ready) {
        Navigator.pushReplacementNamed(context, '/gallery');
      }
    });

    _errSub = td.errorStream.listen((err) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.redAccent),
      );
    });

    await td.init();

    if (!mounted) return;
    setState(() => _state = td.currentState);
    if (td.currentState == TelegramAuthState.ready) {
      Navigator.pushReplacementNamed(context, '/gallery');
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _errSub?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final td = TdlibService.instance;
    setState(() => _loading = true);

    if (_state == TelegramAuthState.waitPhoneNumber) {
      td.sendPhoneNumber(_phoneController.text);
    } else if (_state == TelegramAuthState.waitCode) {
      td.sendOtpCode(_otpController.text);
    } else if (_state == TelegramAuthState.waitPassword) {
      td.send2FaPassword(_passwordController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06070B),
      body: Stack(
        children: [
          Positioned(
            top: -70,
            right: -60,
            child: _GlowOrb(
              size: 250,
              color: const Color(0xFF2AABEE).withValues(alpha: 0.25),
            ),
          ),
          Positioned(
            bottom: -90,
            left: -70,
            child: _GlowOrb(
              size: 270,
              color: Colors.cyanAccent.withValues(alpha: 0.18),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
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
                      child: _buildBody(),
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

  Widget _buildBody() {
    if (_state == TelegramAuthState.initializing) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.cyanAccent),
          SizedBox(height: 18),
          Text(
            'Connecting to Telegram engine...',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      );
    }

    String title = 'Telegram Cloud Login';
    String subtitle = 'Enter your Telegram phone number with country code';
    String hint = '+919876543210';
    String btnText = 'Send OTP';
    TextEditingController controller = _phoneController;
    TextInputType keyboard = TextInputType.phone;
    bool obscure = false;

    if (_state == TelegramAuthState.waitCode) {
      title = 'Verify OTP';
      subtitle = 'Enter the 5-digit code sent to your Telegram app';
      hint = '12345';
      btnText = 'Verify OTP';
      controller = _otpController;
      keyboard = TextInputType.number;
    } else if (_state == TelegramAuthState.waitPassword) {
      final hintText = TdlibService.instance.passwordHint;
      title = '2-Step Verification';
      subtitle = hintText.isNotEmpty
          ? 'Enter your cloud password (Hint: $hintText)'
          : 'Enter your Telegram 2FA password';
      hint = 'Cloud Password';
      btnText = 'Complete Login';
      controller = _passwordController;
      keyboard = TextInputType.visiblePassword;
      obscure = true;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 68,
          height: 68,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2AABEE).withValues(alpha: 0.16),
            border: Border.all(
              color: const Color(0xFF2AABEE).withValues(alpha: 0.45),
            ),
          ),
          child: const Icon(
            Icons.send_rounded,
            size: 32,
            color: Color(0xFF2AABEE),
          ),
        ),
        Text(
          title,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.65),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          obscureText: obscure,
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _loading ? null : _submit(),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
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
              borderSide: const BorderSide(color: Colors.cyanAccent),
            ),
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _loading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.black,
                    ),
                  )
                : Text(
                    btnText,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: 110,
            spreadRadius: 40,
          ),
        ],
      ),
    );
  }
}