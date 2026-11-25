import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/floating_widget.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/services/vault_providers.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final controller = ref.read(vaultControllerProvider);
    bool isSetup = false;

    try {
      final results = await Future.wait<dynamic>([
        controller.isVaultSetup().timeout(
              const Duration(seconds: 6),
              onTimeout: () => false,
            ),
        Future<void>.delayed(const Duration(milliseconds: 1200)),
      ]);
      isSetup = results[0] == true;
    } catch (_) {
      isSetup = false;
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(isSetup ? '/unlock' : '/setup');
  }

  @override
  Widget build(BuildContext context) {
    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              // Center Liquid-Glass Vault Emblem
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const FloatingWidget(
                      amplitude: 8,
                      durationMs: 2600,
                      child: GlassCard(
                        borderRadius: 32,
                        tintColor: Color(0xFF06B6D4),
                        padding: EdgeInsets.all(24),
                        child: Icon(
                          Icons.shield_outlined,
                          size: 64,
                          color: Colors.cyanAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Pkrypt',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Zero-Knowledge Encrypted Cloud',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 13,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),

              // Bottom Floating Glass Badge: Powered by Parthh
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: FloatingWidget(
                    amplitude: 6,
                    durationMs: 2400,
                    child: GlassCard(
                      borderRadius: 999,
                      tintColor: const Color(0xFF7C3AED),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                            color: Colors.cyanAccent,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Powered by Parthh',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.92),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}