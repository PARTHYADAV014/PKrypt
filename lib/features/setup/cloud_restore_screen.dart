import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/models/vault_channel.dart';
import '../../data/services/vault_providers.dart';

class CloudRestoreScreen extends ConsumerStatefulWidget {
  const CloudRestoreScreen({super.key});

  @override
  ConsumerState<CloudRestoreScreen> createState() => _CloudRestoreScreenState();
}

class _CloudRestoreScreenState extends ConsumerState<CloudRestoreScreen> {
  final _passwordController = TextEditingController();
  final _recoveryKeyController = TextEditingController();

  List<VaultChannel> _channels = const [];
  VaultChannel? _selectedChannel;
  bool _loadingChannels = true;
  bool _useRecoveryKey = false;
  bool _obscurePassword = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _loadTelegramChannels();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _recoveryKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadTelegramChannels() async {
    setState(() {
      _loadingChannels = true;
      _errorText = null;
    });

    try {
      final controller = ref.read(vaultControllerProvider);
      final channels =
          await controller.channelService.fetchTelegramChannelsWithoutDb();
      if (!mounted) return;
      setState(() {
        _channels = channels;
        if (_selectedChannel != null) {
          final stillExists = channels
              .where((c) => c.chatId == _selectedChannel!.chatId)
              .toList();
          _selectedChannel = stillExists.isNotEmpty ? stillExists.first : null;
        }
        if (_selectedChannel == null && channels.length == 1) {
          _selectedChannel = channels.first;
        }
        _loadingChannels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingChannels = false;
        _errorText = 'Could not load Telegram channels: $e';
      });
    }
  }

  Future<void> _restoreVault() async {
    final channel = _selectedChannel;
    if (channel == null) {
      setState(() => _errorText = 'Please select your Primary Vault Channel.');
      return;
    }

    final password = _passwordController.text;
    final recoveryKey = _recoveryKeyController.text.trim();

    if (_useRecoveryKey) {
      if (recoveryKey.isEmpty) {
        setState(() => _errorText = 'Please enter your 24-char recovery key.');
        return;
      }
      if (password.length < 8) {
        setState(
          () => _errorText = 'New password must be at least 8 characters.',
        );
        return;
      }
    } else if (password.isEmpty) {
      setState(() => _errorText = 'Please enter your master password.');
      return;
    }

    setState(() => _errorText = null);

    final controller = ref.read(vaultControllerProvider);
    final result = await controller.restoreCloudVaultFromTelegram(
      channel: channel,
      password: password,
      recoveryKey: _useRecoveryKey ? recoveryKey : null,
    );

    if (!mounted) return;

    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cloud Vault restored (${result.mediaCount} items)!',
          ),
        ),
      );
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/gallery', (route) => false);
    } else {
      setState(() {
        _errorText =
            controller.lastError ?? 'Failed to restore vault from Telegram.';
      });
    }
  }

  InputDecoration _glassInput({
    required String label,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.08),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.cyanAccent, width: 1.4),
      ),
      suffixIcon: suffixIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Restore Cloud Vault'),
          actions: [
            IconButton(
              tooltip: 'Refresh Channels',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: (_loadingChannels || controller.isBusy)
                  ? null
                  : _loadTelegramChannels,
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassCard(
                  borderRadius: 20,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.cloud_download_rounded,
                            color: Colors.cyanAccent,
                            size: 22,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Step 1: Select Vault Channel',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Pick the Telegram channel containing your VAULT_KEY_BUNDLE_V1 and VAULT_INDEX_V1 backups.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_loadingChannels)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.cyanAccent,
                            ),
                          ),
                        )
                      else if (_channels.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            'No private Telegram channels found yet. Tap the refresh icon above after Telegram finishes syncing chats.',
                            style: TextStyle(
                              color: Colors.orangeAccent.withValues(alpha: 0.9),
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: _channels.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final ch = _channels[index];
                              final selected =
                                  _selectedChannel?.chatId == ch.chatId;
                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: controller.isBusy
                                    ? null
                                    : () =>
                                        setState(() => _selectedChannel = ch),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    color: selected
                                        ? Colors.cyanAccent
                                            .withValues(alpha: 0.16)
                                        : Colors.white.withValues(alpha: 0.05),
                                    border: Border.all(
                                      color: selected
                                          ? Colors.cyanAccent
                                          : Colors.white
                                              .withValues(alpha: 0.12),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        selected
                                            ? Icons.check_circle_rounded
                                            : Icons.campaign_outlined,
                                        color: selected
                                            ? Colors.cyanAccent
                                            : Colors.white60,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              ch.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            Text(
                                              'ID: ${ch.chatId}',
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  borderRadius: 20,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.lock_open_rounded,
                            color: Colors.amberAccent,
                            size: 22,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Step 2: Decrypt Your Vault',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_useRecoveryKey) ...[
                        TextField(
                          controller: _recoveryKeyController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                          decoration: _glassInput(
                            label: '24-Char Recovery Key',
                            hint: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: const TextStyle(color: Colors.white),
                        onSubmitted: (_) =>
                            controller.isBusy ? null : _restoreVault(),
                        decoration: _glassInput(
                          label: _useRecoveryKey
                              ? 'New Master Password (min 8 chars)'
                              : 'Master Password',
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: Colors.white70,
                            ),
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: controller.isBusy
                              ? null
                              : () => setState(() {
                                    _useRecoveryKey = !_useRecoveryKey;
                                    _errorText = null;
                                  }),
                          child: Text(
                            _useRecoveryKey
                                ? 'Use Master Password instead'
                                : 'Forgot password? Use 24-Char Recovery Key',
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      if (_errorText != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (controller.isBusy)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: CircularProgressIndicator(
                              color: Colors.cyanAccent,
                            ),
                          ),
                        )
                      else
                        GlassPillButton(
                          label: 'Decrypt & Restore Vault',
                          tintColor: const Color(0xFF06B6D4),
                          disabled: _selectedChannel == null,
                          onTap: _restoreVault,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}