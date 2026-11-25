import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_pill_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/models/vault_channel.dart';
import '../../data/services/vault_providers.dart';

class ChannelSelectScreen extends ConsumerStatefulWidget {
  final int step;

  const ChannelSelectScreen({super.key, this.step = 0});

  @override
  ConsumerState<ChannelSelectScreen> createState() =>
      _ChannelSelectScreenState();
}

class _ChannelSelectScreenState extends ConsumerState<ChannelSelectScreen> {
  bool _loading = false;
  String? _errorText;
  List<VaultChannel> _channels = const [];

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _syncFromTelegram();
  }

  void _loadLocal() {
    final controller = ref.read(vaultControllerProvider);
    if (controller.localDbService.isOpen) {
      setState(() {
        _channels = controller.channelService.getSavedChannels();
      });
    }
  }

  Future<void> _syncFromTelegram() async {
    final controller = ref.read(vaultControllerProvider);
    if (!controller.isTelegramReady) return;

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final synced = await controller.channelService.syncChannels();
      controller.refreshVaultData();
      if (!mounted) return;
      setState(() {
        _channels = synced;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Failed to sync channels: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createNewChannel() async {
    final nameController = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161F),
        title: const Text('New Private Vault Channel'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. My Vault Primary',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(nameController.text.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: Colors.cyanAccent),
            ),
          ),
        ],
      ),
    );
    nameController.dispose();

    if (title == null || title.isEmpty || !mounted) return;

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final controller = ref.read(vaultControllerProvider);
      await controller.channelService.createPrivateChannel(title: title);
      controller.refreshVaultData();
      _loadLocal();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Failed to create channel: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setPrimary(VaultChannel channel) async {
    final controller = ref.read(vaultControllerProvider);
    await controller.channelService.setPrimaryChannel(channel);
    controller.refreshVaultData();
    _loadLocal();
  }

  Future<void> _setBackup(VaultChannel channel) async {
    final controller = ref.read(vaultControllerProvider);
    await controller.channelService.setBackupChannel(channel);
    controller.refreshVaultData();
    _loadLocal();
  }

  Future<void> _clearBackup() async {
    final controller = ref.read(vaultControllerProvider);
    await controller.channelService.clearBackupChannel();
    controller.refreshVaultData();
    _loadLocal();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final primary = controller.primaryChannel;
    final backup = controller.backupChannel;

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Select Vault Channels'),
          actions: [
            IconButton(
              tooltip: 'Sync Channels',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loading ? null : _syncFromTelegram,
            ),
            IconButton(
              tooltip: 'Create Private Channel',
              icon: const Icon(Icons.add_rounded, color: Colors.cyanAccent),
              onPressed: _loading ? null : _createNewChannel,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading)
              const LinearProgressIndicator(
                color: Colors.cyanAccent,
                backgroundColor: Colors.white12,
              ),
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: GlassCard(
                borderRadius: 18,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Primary: ${primary?.title ?? "Not set"}\nBackup: ${backup?.title ?? "None (Optional)"}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (backup != null)
                      TextButton(
                        onPressed: _clearBackup,
                        child: const Text(
                          'Clear Backup',
                          style: TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _channels.isEmpty
                  ? Center(
                      child: Text(
                        'No Telegram channels found.\nTap the + button above to create a new Private Channel.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: _channels.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final ch = _channels[index];
                        final isPrimary = primary?.chatId == ch.chatId;
                        final isBackup = backup?.chatId == ch.chatId;

                        return GlassCard(
                          borderRadius: 18,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          tintColor: isPrimary
                              ? const Color(0xFF06B6D4)
                              : isBackup
                                  ? Colors.greenAccent
                                  : null,
                          child: ListTile(
                            leading: Icon(
                              isPrimary
                                  ? Icons.cloud_done
                                  : isBackup
                                      ? Icons.backup_outlined
                                      : Icons.campaign_outlined,
                              color: isPrimary
                                  ? Colors.cyanAccent
                                  : isBackup
                                      ? Colors.greenAccent
                                      : Colors.white70,
                            ),
                            title: Text(
                              ch.title,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              isPrimary
                                  ? 'Primary Vault'
                                  : isBackup
                                      ? 'Backup Vault'
                                      : 'ID: ${ch.chatId}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Wrap(
                              spacing: 6,
                              children: [
                                OutlinedButton(
                                  onPressed:
                                      isPrimary ? null : () => _setPrimary(ch),
                                  child: const Text('Primary'),
                                ),
                                OutlinedButton(
                                  onPressed: (isPrimary || isBackup)
                                      ? null
                                      : () => _setBackup(ch),
                                  child: const Text('Backup'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: GlassPillButton(
                  label: 'Continue to Pkrypt',
                  disabled: primary == null,
                  tintColor: const Color(0xFF06B6D4),
                  onTap: () => Navigator.of(context)
                      .pushNamedAndRemoveUntil('/gallery', (route) => false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}