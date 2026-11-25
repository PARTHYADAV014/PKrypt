import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'vault_providers.dart';

/// App background mein jaate hi vault ko automatically lock karta hai
/// aur user ko /unlock screen par bhej deta hai.
class VaultLifecycleGuard extends ConsumerStatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const VaultLifecycleGuard({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  ConsumerState<VaultLifecycleGuard> createState() =>
      _VaultLifecycleGuardState();
}

class _VaultLifecycleGuardState extends ConsumerState<VaultLifecycleGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sirf 'paused' par lock karo taaki Biometric popup ('inactive') par lock na ho
    if (state == AppLifecycleState.paused) {
      _lockIfUnlocked();
    }
  }

  Future<void> _lockIfUnlocked() async {
    final controller = ref.read(vaultControllerProvider);
    if (!controller.isUnlocked) return;

    await controller.lockVault();
    widget.navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/unlock',
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}