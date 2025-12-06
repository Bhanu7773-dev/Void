import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tele_gallery/core/providers/telegram_provider.dart';
import 'package:tele_gallery/core/services/upload_queue_service.dart';
import 'package:tele_gallery/features/auth/providers/auth_provider.dart';
import 'package:tele_gallery/features/auth/screens/login_screen.dart';
import 'package:tele_gallery/features/upload/providers/upload_provider.dart';
import 'package:tele_gallery/shared/models/cloud_media_item.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    // Initialize storage channel when home screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(storageChannelProvider.notifier).initialize();
      
      // Listen for auth state changes
      ref.listenManual(authStateProvider, (previous, next) {
        next.whenData((state) {
          // If we're back to waiting for phone, user logged out
          if (state == 'waitPhoneNumber' || state == 'closed') {
            _navigateToLogin();
          }
        });
      });
    });
  }
  
  void _navigateToLogin() {
    if (!mounted) return;
    // Reset storage channel state
    ref.read(storageChannelProvider.notifier).reset();
    // Navigate to login
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _pickAndUploadFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'mov', 'avi', 'mkv', 'pdf', 'doc', 'docx', 'zip'],
      );

      if (result == null || result.files.isEmpty) return;

      final uploadService = await ref.read(uploadQueueServiceProvider.future);
      if (uploadService == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload service not ready. Please wait...')),
          );
        }
        return;
      }

      setState(() => _isUploading = true);

      // Add files to queue
      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();

      await uploadService.addMultipleToQueue(paths);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${paths.length} file(s) to upload queue'),
            action: SnackBarAction(
              label: 'View Queue',
              onPressed: () => _showUploadQueue(uploadService),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  void _showUploadQueue(UploadQueueService uploadService) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text(
                    'Upload Queue',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (uploadService.isProcessing)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<List<UploadTask>>(
                stream: uploadService.uploadStateStream,
                initialData: uploadService.queue,
                builder: (context, snapshot) {
                  final tasks = snapshot.data ?? [];
                  if (tasks.isEmpty) {
                    return const Center(child: Text('No uploads in queue'));
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return ListTile(
                        leading: _getStatusIcon(task.status),
                        title: Text(
                          task.filePath.split('/').last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: task.status == TaskStatus.encrypting ||
                                task.status == TaskStatus.uploading
                            ? LinearProgressIndicator(value: task.progress)
                            : Text(_getStatusText(task.status)),
                        trailing: task.status == TaskStatus.failed
                            ? IconButton(
                                icon: const Icon(Icons.refresh),
                                onPressed: () => uploadService.retryFailed(),
                              )
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _getStatusIcon(TaskStatus status) {
    switch (status) {
      case TaskStatus.pending:
        return const Icon(Icons.hourglass_empty, color: Colors.grey);
      case TaskStatus.encrypting:
        return const Icon(Icons.lock, color: Colors.orange);
      case TaskStatus.uploading:
        return const Icon(Icons.cloud_upload, color: Colors.blue);
      case TaskStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case TaskStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
    }
  }

  String _getStatusText(TaskStatus status) {
    switch (status) {
      case TaskStatus.pending:
        return 'Waiting...';
      case TaskStatus.encrypting:
        return 'Encrypting...';
      case TaskStatus.uploading:
        return 'Uploading...';
      case TaskStatus.completed:
        return 'Completed';
      case TaskStatus.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final storageState = ref.watch(storageChannelProvider);
    final mediaItems = ref.watch(completedUploadsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Void'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_queue),
            onPressed: () async {
              final uploadService = await ref.read(uploadQueueServiceProvider.future);
              if (uploadService != null && mounted) {
                _showUploadQueue(uploadService);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // TODO: Settings screen
            },
          ),
        ],
      ),
      body: _buildBody(storageState, mediaItems),
      floatingActionButton: storageState.isReady
          ? FloatingActionButton.extended(
              onPressed: _isUploading ? null : _pickAndUploadFiles,
              icon: _isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_photo_alternate),
              label: Text(_isUploading ? 'Adding...' : 'Upload'),
            )
          : null,
    );
  }

  Widget _buildBody(StorageChannelState state, List<CloudMediaItem> mediaItems) {
    if (state.isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Setting up your vault...'),
            SizedBox(height: 8),
            Text(
              'Finding or creating storage channel',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (state.error != null) {
      // Check if error is auth-related
      final isAuthError = state.error!.toLowerCase().contains('unauthorized') ||
          state.error!.toLowerCase().contains('auth') ||
          state.error!.toLowerCase().contains('not authenticated') ||
          state.error!.toLowerCase().contains('login') ||
          state.error!.toLowerCase().contains('401');
      
      if (isAuthError) {
        // Auto-redirect to login for auth errors
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigateToLogin();
        });
      }
      
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isAuthError ? Icons.logout : Icons.error_outline, 
                size: 64, 
                color: isAuthError ? Colors.orange : Colors.red,
              ),
              const SizedBox(height: 16),
              Text(
                isAuthError ? 'Session Expired' : 'Failed to set up vault',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                isAuthError ? 'Please log in again to continue.' : state.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              if (isAuthError)
                ElevatedButton.icon(
                  onPressed: _navigateToLogin,
                  icon: const Icon(Icons.login),
                  label: const Text('Go to Login'),
                )
              else
                ElevatedButton.icon(
                  onPressed: () {
                    ref.read(storageChannelProvider.notifier).initialize();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
            ],
          ),
        ),
      );
    }

    if (state.isReady) {
      // Show gallery if we have items, otherwise show placeholder
      if (mediaItems.isNotEmpty) {
        return _buildGallery(mediaItems);
      }
      return _buildGalleryPlaceholder(state.channelId!);
    }

    return const Center(child: Text('Initializing...'));
  }

  Widget _buildGallery(List<CloudMediaItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildMediaTile(item);
      },
    );
  }

  Widget _buildMediaTile(CloudMediaItem item) {
    return GestureDetector(
      onTap: () => _showMediaDetails(item),
      onLongPress: () => _showDeleteDialog(item),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail or placeholder
            if (item.localThumbnailPath != null)
              Image.file(
                File(item.localThumbnailPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildPlaceholder(item),
              )
            else
              _buildPlaceholder(item),
            // Media type indicator
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.extension.toUpperCase(),
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ),
            // Encrypted indicator
            const Positioned(
              bottom: 4,
              right: 4,
              child: Icon(
                Icons.lock,
                size: 16,
                color: Colors.green,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildPlaceholder(CloudMediaItem item) {
    return Center(
      child: Icon(
        _getMediaIcon(item.mediaType),
        size: 32,
        color: Colors.grey[400],
      ),
    );
  }
  
  void _showMediaDetails(CloudMediaItem item) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.originalFileName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Size: ${_formatFileSize(item.fileSize)}'),
            Text('Type: ${item.mediaType.name}'),
            Text('Uploaded: ${item.uploadedAt?.toString().split('.').first ?? 'N/A'}'),
            if (item.telegramMessageId != null)
              Text('Message ID: ${item.telegramMessageId}'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    // TODO: Implement download & decrypt
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Download coming soon!')),
                    );
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _showDeleteDialog(item);
                  },
                  icon: const Icon(Icons.delete, color: Colors.red),
                  label: const Text('Delete', style: TextStyle(color: Colors.red)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withOpacity(0.1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  
  Future<void> _showDeleteDialog(CloudMediaItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${item.originalFileName}" from your vault?\n\nThis will remove the file from Telegram and local storage.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _deleteItem(item);
    }
  }
  
  Future<void> _deleteItem(CloudMediaItem item) async {
    try {
      // Delete from Telegram
      if (item.telegramMessageId != null) {
        final authService = ref.read(telegramAuthServiceProvider);
        final channelId = await authService.getStoredChannelId();
        if (channelId != null) {
          await authService.deleteMessage(channelId, item.telegramMessageId!);
        }
      }
      
      // Delete thumbnail
      if (item.localThumbnailPath != null) {
        final thumbFile = File(item.localThumbnailPath!);
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }
      
      // Delete from Hive
      final box = ref.read(mediaBoxProvider);
      await box.delete(item.id);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${item.originalFileName}"')),
        );
        setState(() {}); // Refresh UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  IconData _getMediaIcon(MediaType type) {
    switch (type) {
      case MediaType.image:
        return Icons.image;
      case MediaType.video:
        return Icons.videocam;
      case MediaType.document:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildGalleryPlaceholder(int channelId) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_done,
                size: 64,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Vault Connected!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Channel ID: $channelId',
              style: const TextStyle(color: Colors.grey, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                children: [
                  Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
                  SizedBox(height: 12),
                  Text(
                    'No media yet',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Tap + to upload your first file',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
