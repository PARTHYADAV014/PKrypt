import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/services/auto_backup_service.dart';
import '../../data/services/vault_controller.dart';
import '../../data/services/vault_providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _wiping = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  bool _biometricLoading = true;
  bool _hasRecoveryKey = false;
  bool _hasDecoyPassword = false;
  bool _autoBackupToggling = false;

  @override
  void initState() {
    super.initState();
    _loadSecurityStatus();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _loadSecurityStatus() async {
    try {
      final controller = ref.read(vaultControllerProvider);
      if (controller.isDecoyMode) {
        if (!mounted) return;
        setState(() {
          _biometricAvailable = false;
          _biometricEnabled = false;
          _hasRecoveryKey = false;
          _hasDecoyPassword = false;
          _biometricLoading = false;
        });
        return;
      }

      final available = await controller.isBiometricAvailable();
      final enabled = await controller.isBiometricEnabled();
      final hasRecovery = await controller.hasRecoveryKey();
      final hasDecoy = await controller.hasDecoyPassword();
      if (!mounted) return;
      setState(() {
        _biometricAvailable = available;
        _biometricEnabled = enabled;
        _hasRecoveryKey = hasRecovery;
        _hasDecoyPassword = hasDecoy;
        _biometricLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _biometricLoading = false;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    setState(() => _biometricLoading = true);
    try {
      await controller.setBiometricEnabled(value);
      if (!mounted) return;
      setState(() {
        _biometricEnabled = value;
        _biometricLoading = false;
      });
      _showSnack(
        value ? 'Biometric unlock enabled.' : 'Biometric unlock disabled.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _biometricLoading = false);
      _showSnack('Biometric error: $e');
    }
  }

  Future<void> _toggleAutoBackup(bool value) async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    final auto = controller.autoBackupService;
    if (auto == null) return;

    setState(() => _autoBackupToggling = true);
    try {
      final ok = await auto.setEnabled(value);
      if (!mounted) return;
      if (value && !ok) {
        _showSnack(auto.statusMessage);
      } else {
        _showSnack(
          value
              ? 'Zero-Knowledge Background Auto-Backup enabled!'
              : 'Auto-Backup turned off.',
        );
      }
    } finally {
      if (mounted) setState(() => _autoBackupToggling = false);
    }
  }

  Future<void> _selectAutoBackupFolders() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    final auto = controller.autoBackupService;
    if (auto == null) return;

    final albums = await auto.getAvailableDeviceAlbums();
    if (!mounted) return;

    if (albums.isEmpty) {
      _showSnack(
        'No device folders accessible. Grant gallery permission first.',
      );
      return;
    }

    final initialSelected = auto.selectedAlbumIds.toSet();
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => _FolderSelectDialog(
        albums: albums,
        initialSelected: initialSelected,
      ),
    );

    if (picked == null || !mounted) return;
    await auto.setSelectedAlbumIds(picked.toList());
    _showSnack(
      picked.isEmpty
          ? 'Backup folder reset to default (Camera).'
          : '${picked.length} folder(s) selected for Auto-Backup.',
    );
  }

  Future<void> _runAutoBackupNow() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    final auto = controller.autoBackupService;
    if (auto == null) return;
    final count = await auto.triggerSyncNow();
    if (!mounted) return;
    _showSnack(
      count > 0
          ? 'Auto-Backup uploaded $count new item(s)!'
          : auto.statusMessage,
    );
  }

  Future<void> _backupCloudIndex() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    try {
      final result = await controller.backupCloudIndex();
      _showSnack(
        'Encrypted index backed up & pinned (${result.mediaCount} items).',
      );
    } catch (e) {
      _showSnack('Cloud index backup failed: $e');
    }
  }

  Future<void> _syncKeyBundle() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    try {
      await controller.backupCloudKeyBundle();
      _showSnack(
        'Zero-knowledge Key Bundle (VAULT_KEY_BUNDLE_V1) synced to Telegram!',
      );
    } catch (e) {
      _showSnack('Key Bundle sync failed: $e');
    }
  }

  Future<void> _restoreCloudIndex() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141522),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        title: const Text(
          'Restore Cloud Index?',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          'This downloads the latest pinned encrypted database snapshot from your Telegram Vault Channel and restores all albums and media records.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.72),
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final result = await controller.restoreCloudIndex();
      _showSnack(
        'Restored ${result.mediaCount} items and ${result.channelCount} channels from cloud index.',
      );
    } catch (e) {
      _showSnack('Cloud index restore failed: $e');
    }
  }

  String _formatSyncTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} $h:$m';
  }

  Future<void> _showChangePasswordDialog() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) {
      _showSnack('Connect cloud sync to update vault password.');
      return;
    }
    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ChangePasswordDialog(controller: controller),
    );

    if (updated == true) {
      _showSnack('Master password updated successfully.');
    }
  }

  Future<void> _showDecoyPinDialog() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _DecoyPinDialog(
        controller: controller,
        hasExisting: _hasDecoyPassword,
      ),
    );

    if (!mounted || result == null) return;
    final hasNow = await controller.hasDecoyPassword();
    if (!mounted) return;
    setState(() => _hasDecoyPassword = hasNow);

    if (result == 'saved') {
      _showSnack(
        'Decoy PIN active! Enter it on the lock screen to open your isolated decoy vault.',
      );
    } else if (result == 'removed') {
      _showSnack('Decoy PIN and decoy vault data removed.');
    }
  }

  Future<void> _generateNewRecoveryKey() async {
    final controller = ref.read(vaultControllerProvider);
    if (controller.isDecoyMode) return;
    try {
      final newKey = await controller.regenerateRecoveryKey();
      if (!mounted) return;
      setState(() => _hasRecoveryKey = true);

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF141522),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          title: const Text(
            'New 24-Char Recovery Key',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Write this key down in a safe place. Your previous recovery key will no longer work.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.cyanAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: SelectableText(
                  newKey,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 15,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: newKey));
                _showSnack('Recovery key copied.');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                controller.clearPendingRecoverySecrets();
                Navigator.of(ctx).pop();
              },
              child: const Text('Saved'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnack('Recovery key error: $e');
    }
  }

  Future<void> _panicWipe() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161F),
        title: const Text(
          'Panic Wipe Vault?',
          style: TextStyle(color: Colors.redAccent),
        ),
        content: const Text(
          'This will permanently erase all local keys, password hashes, auto-backup state, and the local encrypted database.\n\nYour encrypted files on Telegram will remain safe.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'WIPE NOW',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _wiping = true);

    try {
      final controller = ref.read(vaultControllerProvider);

      // In Decoy Mode: wipe ONLY the isolated decoy data; real master vault stays 100% untouched.
      if (controller.isDecoyMode) {
        await controller.wipeOnlyDecoySession();
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/unlock', (route) => false);
        return;
      }

      await controller.autoBackupService?.wipeAllData();
      await controller.lockVault();
      await controller.telegramService.clearApiCredentials();
      await controller.localDbService.close();
      await Hive.deleteFromDisk();
      await const FlutterSecureStorage().deleteAll();

      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/setup', (route) => false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _wiping = false);
      _showSnack('Wipe error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final isDecoy = controller.isDecoyMode;
    final auto = isDecoy ? null : controller.autoBackupService;
    final lastBackupText = controller.lastIndexBackupAt != null
        ? 'Last synced: ${_formatSyncTime(controller.lastIndexBackupAt!)}'
        : 'Auto-syncs pinned encrypted snapshot to Telegram';

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Vault Settings'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _GlassTileBox(
              child: SwitchListTile(
                secondary: const Icon(
                  Icons.fingerprint,
                  color: Colors.cyanAccent,
                ),
                title: const Text(
                  'Biometric Unlock',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  isDecoy
                      ? 'Off - Toggle on to enable biometric unlock'
                      : (_biometricAvailable
                          ? (_biometricEnabled
                              ? 'On - Prompts for biometrics on launch'
                              : 'Off - Toggle on to enable biometric unlock')
                          : 'Biometrics not available on this device'),
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                activeThumbColor: Colors.cyanAccent,
                value: isDecoy ? false : _biometricEnabled,
                onChanged: (isDecoy || !_biometricAvailable || _biometricLoading)
                    ? null
                    : _toggleBiometric,
              ),
            ),
            const SizedBox(height: 10),
            _SectionTile(
              icon: Icons.password_rounded,
              iconColor: Colors.cyanAccent,
              title: 'Change Master Password',
              subtitle: 'DEK/KEK instant re-wrap (zero photo re-upload)',
              onTap: _showChangePasswordDialog,
            ),
            if (!isDecoy) ...[
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.theater_comedy_rounded,
                iconColor:
                    _hasDecoyPassword ? Colors.greenAccent : Colors.purpleAccent,
                title: 'Decoy Vault PIN',
                subtitle: _hasDecoyPassword
                    ? 'Active - Opens an isolated local gallery on lock screen'
                    : 'Off - Set a secondary PIN for plausible deniability',
                onTap: _showDecoyPinDialog,
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.vpn_key_outlined,
                iconColor: _hasRecoveryKey ? Colors.greenAccent : Colors.amber,
                title: 'Master Recovery Key',
                subtitle: _hasRecoveryKey
                    ? 'Active - Tap to generate a fresh 24-char backup key'
                    : 'Not set yet - Tap to generate a 24-char backup key',
                onTap: _generateNewRecoveryKey,
              ),
            ],
            const SizedBox(height: 10),
            const _SectionTile(
              icon: Icons.security_rounded,
              iconColor: Colors.cyanAccent,
              title: 'Auto-Lock & Screenshot Block',
              subtitle: 'Active (Auto-locks on minimize + FLAG_SECURE enabled)',
            ),
            if (auto != null) ...[
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'ZERO-KNOWLEDGE AUTO-BACKUP',
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              _GlassTileBox(
                child: SwitchListTile(
                  secondary: const Icon(
                    Icons.cloud_sync_rounded,
                    color: Colors.cyanAccent,
                  ),
                  title: const Text(
                    'Background Auto-Upload',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    auto.isEnabled
                        ? auto.statusMessage
                        : 'Auto-encrypts new photos even when vault is locked (X25519)',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  activeThumbColor: Colors.cyanAccent,
                  value: auto.isEnabled,
                  onChanged: _autoBackupToggling ? null : _toggleAutoBackup,
                ),
              ),
              const SizedBox(height: 10),
              _GlassTileBox(
                child: SwitchListTile(
                  secondary: const Icon(
                    Icons.wifi_rounded,
                    color: Colors.greenAccent,
                  ),
                  title: const Text(
                    'Wi-Fi Only Auto-Backup',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    auto.wifiOnly
                        ? 'On - Pauses auto-upload on mobile data'
                        : 'Off - Uploads on both Wi-Fi and mobile data',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  activeThumbColor: Colors.greenAccent,
                  value: auto.wifiOnly,
                  onChanged: (val) => auto.setWifiOnly(val),
                ),
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.folder_copy_outlined,
                iconColor: Colors.purpleAccent,
                title: 'Auto-Backup Folders',
                subtitle: auto.selectedAlbumIds.isEmpty
                    ? 'Default: Camera (tap to pick folders)'
                    : '${auto.selectedAlbumIds.length} folder(s) selected',
                onTap: _selectAutoBackupFolders,
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.sync_rounded,
                iconColor: Colors.cyanAccent,
                title: 'Scan & Backup New Media Now',
                subtitle: auto.isSyncing
                    ? auto.statusMessage
                    : (auto.lastSyncAt != null
                        ? 'Last scan: ${_formatSyncTime(auto.lastSyncAt!)}'
                        : 'Check selected folders and upload new items'),
                trailing: auto.isSyncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.cyanAccent,
                        ),
                      )
                    : null,
                onTap: auto.isSyncing ? null : _runAutoBackupNow,
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.battery_saver_rounded,
                iconColor: Colors.amberAccent,
                title: 'Allow Uninterrupted Background Sync',
                subtitle: 'Set Pkrypt to Unrestricted in battery settings',
                onTap: () => auto.openBatteryOptimizationSettings(),
              ),
            ],
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'TELEGRAM CLOUD & RECOVERY',
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            _SectionTile(
              icon: Icons.send_rounded,
              iconColor: (!isDecoy && controller.isTelegramReady)
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
              title: 'Telegram Cloud Connection',
              subtitle: (!isDecoy && controller.isTelegramReady)
                  ? 'Connected'
                  : 'Not connected - local vault mode',
              onTap: () {
                if (isDecoy) {
                  _showSnack('Cloud sync is offline. Local vault mode active.');
                  return;
                }
                Navigator.of(context).pushNamed('/telegram');
              },
            ),
            if (!isDecoy) ...[
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.cloud_outlined,
                iconColor: Colors.cyanAccent,
                title: 'Vault Channels',
                subtitle:
                    'Primary: ${controller.primaryChannel?.title ?? "Not set"}',
                onTap: () => Navigator.of(context).pushNamed('/channel_select'),
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.key_rounded,
                iconColor: Colors.amberAccent,
                title: 'Sync Cloud Key Bundle',
                subtitle: controller.isSyncingKeyBundle
                    ? 'Uploading VAULT_KEY_BUNDLE_V1...'
                    : (controller.lastKeyBundleSyncAt != null
                        ? 'Last synced: ${_formatSyncTime(controller.lastKeyBundleSyncAt!)}'
                        : 'Theft-proof 1 TB new-phone recovery bundle'),
                trailing: controller.isSyncingKeyBundle
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.amberAccent,
                        ),
                      )
                    : null,
                onTap: controller.isSyncingKeyBundle ? null : _syncKeyBundle,
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.cloud_upload_outlined,
                iconColor: Colors.cyanAccent,
                title: 'Backup Cloud Index Now',
                subtitle: controller.isSyncingIndex
                    ? 'Encrypting and pinning database snapshot...'
                    : lastBackupText,
                trailing: controller.isSyncingIndex
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.cyanAccent,
                        ),
                      )
                    : null,
                onTap: controller.isSyncingIndex ? null : _backupCloudIndex,
              ),
              const SizedBox(height: 10),
              _SectionTile(
                icon: Icons.cloud_download_outlined,
                iconColor: Colors.purpleAccent,
                title: 'Restore Cloud Index',
                subtitle:
                    'Recover albums & metadata from pinned Telegram backup',
                onTap: controller.isSyncingIndex ? null : _restoreCloudIndex,
              ),
            ],
            const SizedBox(height: 10),
            _SectionTile(
              icon: Icons.lock_outline_rounded,
              iconColor: Colors.white,
              title: 'Lock Vault Now',
              subtitle: 'Immediately clear encryption keys from memory',
              onTap: () async {
                await controller.lockVault();
                if (!context.mounted) return;
                Navigator.of(context)
                    .pushNamedAndRemoveUntil('/unlock', (route) => false);
              },
            ),
            const SizedBox(height: 28),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _wiping ? null : _panicWipe,
                icon: _wiping
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.delete_forever_rounded),
                label: const Text(
                  'PANIC WIPE LOCAL VAULT',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.85),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecoyPinDialog extends StatefulWidget {
  final VaultController controller;
  final bool hasExisting;

  const _DecoyPinDialog({
    required this.controller,
    required this.hasExisting,
  });

  @override
  State<_DecoyPinDialog> createState() => _DecoyPinDialogState();
}

class _DecoyPinDialogState extends State<_DecoyPinDialog> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pinCtrl.text;
    if (pin.length < 4) {
      setState(() => _error = 'Decoy PIN/password must be at least 4 characters.');
      return;
    }
    if (pin != _confirmCtrl.text) {
      setState(() => _error = 'Decoy PIN entries do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.controller.setupDecoyPassword(pin);
      if (!mounted) return;
      Navigator.of(context).pop('saved');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Invalid argument(s): ', '');
      });
    }
  }

  Future<void> _remove() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.controller.removeDecoyPassword();
      if (!mounted) return;
      Navigator.of(context).pop('removed');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF141522),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      title: Text(
        widget.hasExisting ? 'Update Decoy Vault PIN' : 'Set Decoy Vault PIN',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Entering this PIN on the unlock screen silently opens a separate local encrypted gallery with zero trace of your real vault or Telegram channels.\n\nTip: Unlock with your Decoy PIN once and add 2-3 normal photos so it looks completely natural.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.68),
                fontSize: 12,
              ),
            ),
            if (widget.hasExisting) ...[
              const SizedBox(height: 8),
              Text(
                'Note: Setting a new Decoy PIN resets existing decoy gallery items.',
                style: TextStyle(
                  color: Colors.amberAccent.withValues(alpha: 0.85),
                  fontSize: 11,
                ),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _pinCtrl,
              obscureText: true,
              enabled: !_saving,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Decoy PIN / Password (min 4 chars)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmCtrl,
              obscureText: true,
              enabled: !_saving,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Confirm Decoy PIN / Password',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.hasExisting)
          TextButton(
            onPressed: _saving ? null : _remove,
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyanAccent,
            foregroundColor: Colors.black,
          ),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : Text(widget.hasExisting ? 'Update' : 'Enable'),
        ),
      ],
    );
  }
}

class _FolderSelectDialog extends StatefulWidget {
  final List<DeviceAlbumInfo> albums;
  final Set<String> initialSelected;

  const _FolderSelectDialog({
    required this.albums,
    required this.initialSelected,
  });

  @override
  State<_FolderSelectDialog> createState() => _FolderSelectDialogState();
}

class _FolderSelectDialogState extends State<_FolderSelectDialog> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF141522),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      title: const Text(
        'Select Auto-Backup Folders',
        style: TextStyle(color: Colors.white, fontSize: 17),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: ListView.builder(
          itemCount: widget.albums.length,
          itemBuilder: (context, index) {
            final album = widget.albums[index];
            final checked = _selected.contains(album.id);
            return CheckboxListTile(
              value: checked,
              activeColor: Colors.cyanAccent,
              checkColor: Colors.black,
              title: Text(
                album.name,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: Text(
                '${album.assetCount} items',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              onChanged: (val) {
                setState(() {
                  if (val == true) {
                    _selected.add(album.id);
                  } else {
                    _selected.remove(album.id);
                  }
                });
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyanAccent,
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  final VaultController controller;

  const _ChangePasswordDialog({required this.controller});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _dialogError;
  bool _saving = false;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_newCtrl.text.length < 8) {
      setState(
        () => _dialogError = 'New password must be at least 8 characters.',
      );
      return;
    }
    if (_newCtrl.text != _confirmCtrl.text) {
      setState(() => _dialogError = 'New passwords do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _dialogError = null;
    });

    final ok = await widget.controller.changeMasterPassword(
      currentPassword: _oldCtrl.text,
      newPassword: _newCtrl.text,
    );

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _dialogError =
            widget.controller.lastError ?? 'Current password is incorrect.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF141522),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      title: const Text(
        'Change Master Password',
        style: TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Updates your master password instantly using key wrapping without re-uploading any media.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _oldCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Current Password',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _newCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'New Password (min 8 chars)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Confirm New Password',
              ),
            ),
            if (_dialogError != null) ...[
              const SizedBox(height: 10),
              Text(
                _dialogError!,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyanAccent,
            foregroundColor: Colors.black,
          ),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : const Text('Update'),
        ),
      ],
    );
  }
}

class _GlassTileBox extends StatelessWidget {
  final Widget child;

  const _GlassTileBox({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.11),
            Colors.white.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: child,
    );
  }
}

class _SectionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SectionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassTileBox(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        trailing: trailing ??
            (onTap != null
                ? const Icon(Icons.chevron_right, color: Colors.white38)
                : null),
        onTap: onTap,
      ),
    );
  }
}