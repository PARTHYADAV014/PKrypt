import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/models/face_cluster.dart';
import '../../data/models/vault_media.dart';
import '../../data/services/vault_controller.dart';
import '../../data/services/vault_providers.dart';

class PersonDetailScreen extends ConsumerStatefulWidget {
  final String clusterId;

  const PersonDetailScreen({super.key, required this.clusterId});

  @override
  ConsumerState<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends ConsumerState<PersonDetailScreen> {
  Future<void> _renamePerson(FaceCluster cluster) async {
    final nameCtrl = TextEditingController(text: cluster.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141522),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        title: const Text(
          'Rename Person',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter name (e.g. Mom, Rahul)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();

    if (newName == null || newName.isEmpty || !mounted) return;
    await ref
        .read(vaultControllerProvider)
        .renamePerson(cluster.id, newName);
  }

  Future<void> _mergePerson(
    FaceCluster current,
    List<FaceCluster> allClusters,
  ) async {
    final others = allClusters.where((c) => c.id != current.id).toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other people available to merge.')),
      );
      return;
    }

    final target = await showDialog<FaceCluster>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141522),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        title: Text(
          'Merge "${current.name}" into...',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 280,
          child: ListView.separated(
            itemCount: others.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white12),
            itemBuilder: (context, index) {
              final other = others[index];
              final controller = ref.read(vaultControllerProvider);
              final avatar = controller.getCachedFaceAvatar(other.id);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.white12,
                  backgroundImage: avatar != null ? MemoryImage(avatar) : null,
                  child: avatar == null
                      ? const Icon(Icons.person, color: Colors.white70)
                      : null,
                ),
                title: Text(
                  other.name,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${controller.getMediaForPerson(other.id).length} photos',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () => Navigator.of(ctx).pop(other),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (target == null || !mounted) return;
    await ref.read(vaultControllerProvider).mergePersons(
          sourceClusterId: current.id,
          targetClusterId: target.id,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Merged into "${target.name}"!')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final allClusters = controller.faceClusters;
    final matching = allClusters.where((c) => c.id == widget.clusterId).toList();
    final cluster = matching.isNotEmpty ? matching.first : null;
    final photos = cluster != null
        ? controller.getMediaForPerson(cluster.id)
        : const <VaultMedia>[];

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(cluster?.name ?? 'Person'),
          actions: [
            if (cluster != null) ...[
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined, color: Colors.cyanAccent),
                onPressed: () => _renamePerson(cluster),
              ),
              IconButton(
                tooltip: 'Merge with another person',
                icon: const Icon(
                  Icons.merge_type_rounded,
                  color: Colors.amberAccent,
                ),
                onPressed: () => _mergePerson(cluster, allClusters),
              ),
            ],
          ],
        ),
        body: cluster == null
            ? const Center(
                child: Text(
                  'Person not found.',
                  style: TextStyle(color: Colors.white70),
                ),
              )
            : photos.isEmpty
                ? const Center(
                    child: Text(
                      'No photos linked to this person.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      final media = photos[index];
                      return _PersonPhotoTile(
                        key: ValueKey(media.id),
                        media: media,
                        controller: controller,
                        onTap: () {
                          Navigator.of(context).pushNamed(
                            '/viewer',
                            arguments: {
                              'items': photos,
                              'initialIndex': index,
                            },
                          );
                        },
                      );
                    },
                  ),
      ),
    );
  }
}

class _PersonPhotoTile extends StatefulWidget {
  final VaultMedia media;
  final VaultController controller;
  final VoidCallback onTap;

  const _PersonPhotoTile({
    super.key,
    required this.media,
    required this.controller,
    required this.onTap,
  });

  @override
  State<_PersonPhotoTile> createState() => _PersonPhotoTileState();
}

class _PersonPhotoTileState extends State<_PersonPhotoTile> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _thumb = widget.controller.getCachedThumbnail(widget.media.id);
    if (_thumb == null) {
      widget.controller.loadEncryptedThumbnail(widget.media).then((bytes) {
        if (mounted && bytes != null) {
          setState(() => _thumb = bytes);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb ?? widget.controller.getCachedThumbnail(widget.media.id);
    if (thumb != null && thumb.isNotEmpty) {
      return GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );
    }

    return GlassCard(
      borderRadius: 16,
      padding: const EdgeInsets.all(8),
      onTap: widget.onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.enhanced_encryption_outlined,
              color: Colors.cyanAccent,
              size: 26,
            ),
            const SizedBox(height: 4),
            Text(
              widget.media.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}