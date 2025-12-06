import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_gallery/core/providers/telegram_provider.dart';
import 'package:tele_gallery/core/services/crypto_helper.dart';
import 'package:tele_gallery/core/services/upload_queue_service.dart';
import 'package:tele_gallery/features/upload/providers/upload_provider.dart';
import 'package:tele_gallery/features/auth/providers/auth_provider.dart';
import 'package:tele_gallery/features/auth/screens/login_screen.dart';
import 'package:tele_gallery/shared/models/cloud_media_item.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
  with AutomaticKeepAliveClientMixin {
  bool _isUploading = false;
  bool _vaultUnlocking = false;
  bool _thumbBackfillRunning = false;
  bool _loadingLocal = false;
  String? _localError;
  List<AssetEntity> _localAssets = const [];
  Map<String, Uint8List?> _localThumbCache = const {};
  Set<String> _selectedAssetIds = {};
  bool _selectionMode = false;
  bool _batchUploading = false;
  int _currentTabIndex = 0;
  bool _decodingThumbs = false;
  int _thumbQueueIndex = 0;
  int _activeThumbDecoders = 0;
  static const int _maxThumbConcurrency = 2;
  Future<void>? _localLoadFuture;

  static const int _maxLocalFiles = 400; // cap to keep UI snappy

  @override
  void initState() {
    super.initState();
    // Initialize storage channel when home screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(storageChannelProvider.notifier).initialize();
      _localLoadFuture ??= _loadLocalImages();
      
      // Listen for auth state changes
      ref.listenManual(authStateProvider, (previous, next) {
        next.whenData((state) {
          // If we're back to waiting for phone, user logged out
          if (state == 'waitPhoneNumber' || state == 'closed') {
            _navigateToLogin();
          }
        });
      });

      // Listen for storage channel readiness to unlock vault
      ref.listenManual(storageChannelProvider, (previous, next) {
        if (next.isReady && !_vaultUnlocking) {
          _ensureVaultUnlocked(next.channelId!);
        }
      });
    });
  }

  Future<void> _loadLocalImages() async {
    if (_loadingLocal) return;
    setState(() {
      _loadingLocal = true;
      _localError = null;
    });

    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) {
        setState(() {
          _localError = 'Photos permission not granted';
        });
        return;
      }

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );

      if (paths.isEmpty) {
        setState(() {
          _localAssets = const [];
          _localThumbCache = const {};
        });
        return;
      }

      final mainPath = paths.first;
      final assets = await mainPath.getAssetListRange(
        start: 0,
        end: _maxLocalFiles,
      );

      setState(() {
        _localAssets = assets;
        _localThumbCache = {};
        _thumbQueueIndex = 0;
      });

      _pumpThumbDecodeQueue();
    } catch (e) {
      setState(() {
        _localError = e.toString();
      });
    } finally {
      setState(() {
        _loadingLocal = false;
      });
    }
  }

  void _pumpThumbDecodeQueue() {
    if (!mounted || _decodingThumbs) return;
    _decodingThumbs = true;

    void startNext() {
      if (!mounted) return;
      while (_activeThumbDecoders < _maxThumbConcurrency &&
          _thumbQueueIndex < _localAssets.length) {
        final idx = _thumbQueueIndex++;
        final asset = _localAssets[idx];
        if (_localThumbCache.containsKey(asset.id)) {
          continue;
        }

        _activeThumbDecoders++;
        asset
            .thumbnailDataWithSize(
              const ThumbnailSize(192, 192),
              quality: 75,
            )
            .then((thumb) {
          if (!mounted) return;
          if (thumb != null) {
            setState(() {
              _localThumbCache = {
                ..._localThumbCache,
                asset.id: thumb,
              };
            });
          }
        }).catchError((e, st) {
          debugPrint('Local thumb decode failed for ${asset.id}: $e');
        }).whenComplete(() {
          _activeThumbDecoders--;
          startNext();
        });
      }

      if (_activeThumbDecoders == 0) {
        _decodingThumbs = false;
      }
    }

    startNext();
  }


  Future<void> _ensureVaultUnlocked(int channelId) async {
    if (!mounted) return;
    final cryptoHelper = ref.read(cryptoHelperProvider);
    if (cryptoHelper.hasKey) {
      // Vault already unlocked in this session; still try backfill if needed
      await _backfillThumbnails(cryptoHelper);
      return;
    }

    _vaultUnlocking = true;
    try {
      final hasSalt = await cryptoHelper.hasStoredSalt();
      final isCreate = !hasSalt;
      final passphrase = await _promptPassphrase(isCreate: isCreate);
      if (passphrase == null || passphrase.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vault password is required to proceed.')),
        );
        return;
      }

      await cryptoHelper.init(passphrase: passphrase);

      // Post vault config to channel so it can be recovered on reinstall
      final saltB64 = cryptoHelper.currentSaltBase64;
      if (saltB64 != null) {
        final telegramService = ref.read(telegramAuthServiceProvider);
        await telegramService.ensureVaultConfig(
          chatId: channelId,
          saltBase64: saltB64,
          iterations: cryptoHelper.currentIterations,
        );
      }

      // Backfill thumbnails for restored items (images)
      await _backfillThumbnails(cryptoHelper);

      // Recreate upload service now that key is available
      ref.invalidate(uploadQueueServiceProvider);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isCreate ? 'Vault created.' : 'Vault unlocked.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vault unlock failed: $e')),
      );
    } finally {
      _vaultUnlocking = false;
    }
  }

  Future<void> _backfillThumbnails(CryptoHelper cryptoHelper) async {
    if (_thumbBackfillRunning) return;
    _thumbBackfillRunning = true;
    try {
      final mediaBox = Hive.box<CloudMediaItem>('cloud_media');
        final missing = mediaBox.values.where((item) =>
          item.mediaType == MediaType.image &&
          (item.localThumbnailPath == null || item.localThumbnailPath!.isEmpty) &&
          item.telegramFileId != null).length;

      if (missing == 0) {
        _thumbBackfillRunning = false;
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Generating thumbnails for $missing image(s)...'),
          duration: const Duration(seconds: 4),
        ),
      );

      final telegramService = ref.read(telegramAuthServiceProvider);
      final generated = await telegramService.backfillThumbnailsForImages(
        mediaBox: mediaBox,
        cryptoHelper: cryptoHelper,
        maxCount: null,
        maxBytes: 50 * 1024 * 1024, // skip huge files when backfilling thumbs
      );

      if (!mounted) return;
      if (generated > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generated $generated thumbnails.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No thumbnails generated.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Thumbnail backfill failed: $e')),
      );
    } finally {
      _thumbBackfillRunning = false;
    }
  }

  Future<String?> _promptPassphrase({required bool isCreate}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isCreate ? 'Set Vault Password' : 'Enter Vault Password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: isCreate ? 'New password' : 'Password',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                Navigator.of(ctx).pop(value);
              },
              child: Text(isCreate ? 'Create' : 'Unlock'),
            ),
          ],
        );
      },
    );
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
    super.build(context);
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
      floatingActionButton: storageState.isReady && _currentTabIndex == 0
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
      return DefaultTabController(
        length: 2,
        child: Builder(
          builder: (context) {
            return NotificationListener<ScrollNotification>(
              onNotification: (_) {
                // Update tab index when user swipes between tabs
                final tabController = DefaultTabController.of(context);
                if (_currentTabIndex != tabController.index && mounted) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _currentTabIndex != tabController.index) {
                      setState(() {
                        _currentTabIndex = tabController.index;
                      });
                    }
                  });
                }
                return false;
              },
              child: Column(
                children: [
                  TabBar(
                    onTap: (index) {
                      if (_currentTabIndex != index && mounted) {
                        setState(() {
                          _currentTabIndex = index;
                        });
                      }
                    },
                    tabs: const [
                      Tab(text: 'Server'),
                      Tab(text: 'Local'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        mediaItems.isNotEmpty
                            ? _buildGallery(mediaItems)
                            : _buildGalleryPlaceholder(state.channelId!),
                        _buildLocalGallery(),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    return const Center(child: Text('Initializing...'));
  }

  Widget _buildLocalGallery() {
    // While loading first time, show spinner
    if (_localAssets.isEmpty && _loadingLocal) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_localError != null) {
      return Center(child: Text('Local gallery error: $_localError'));
    }
    if (_localAssets.isEmpty) {
      return const Center(child: Text('No local photos found'));
    }

    return Stack(
      children: [
        GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: _localAssets.length,
          itemBuilder: (context, index) {
            final asset = _localAssets[index];
            final thumb = _localThumbCache[asset.id];
            final isSelected = _selectedAssetIds.contains(asset.id);
            return GestureDetector(
              onTap: () {
                if (_selectionMode) {
                  setState(() {
                    if (isSelected) {
                      _selectedAssetIds.remove(asset.id);
                      if (_selectedAssetIds.isEmpty) {
                        _selectionMode = false;
                      }
                    } else {
                      _selectedAssetIds.add(asset.id);
                    }
                  });
                }
              },
              onLongPress: () {
                if (!_selectionMode) {
                  setState(() {
                    _selectionMode = true;
                    _selectedAssetIds = {asset.id};
                  });
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: thumb != null
                        ? Image.memory(
                            thumb,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.low,
                          )
                        : const _ShimmerTile(icon: Icons.photo),
                  ),
                  if (_selectionMode)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.blue : Colors.black38,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, size: 16, color: Colors.white)
                            : null,
                      ),
                    ),
                  if (isSelected)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        // Selection toolbar
        if (_selectionMode)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text(
                      '${_selectedAssetIds.length} selected',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _selectionMode = false;
                          _selectedAssetIds = {};
                        });
                      },
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _batchUploading ? null : _uploadSelectedPhotos,
                      icon: _batchUploading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload),
                      label: Text(_batchUploading ? 'Uploading...' : 'Upload'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _uploadSelectedPhotos() async {
    if (_selectedAssetIds.isEmpty || _batchUploading) return;

    final uploadService = await ref.read(uploadQueueServiceProvider.future);
    if (uploadService == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload service not ready. Please wait...')),
        );
      }
      return;
    }

    setState(() {
      _batchUploading = true;
    });

    final selectedIds = _selectedAssetIds.toList();
    final assetsToUpload = _localAssets.where((a) => selectedIds.contains(a.id)).toList();

    int uploaded = 0;
    final total = assetsToUpload.length;

    for (final asset in assetsToUpload) {
      if (!mounted) break;

      try {
        final file = await asset.file;
        if (file == null) {
          debugPrint('Asset ${asset.id} has no file');
          continue;
        }

        await uploadService.addToQueue(file.path);
        uploaded++;

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Queued $uploaded / $total'),
              duration: const Duration(seconds: 1),
            ),
          );
        }

        // 3 second gap between each upload queue add
        if (uploaded < total) {
          await Future.delayed(const Duration(seconds: 3));
        }
      } catch (e) {
        debugPrint('Failed to queue asset ${asset.id}: $e');
      }
    }

    if (mounted) {
      setState(() {
        _batchUploading = false;
        _selectionMode = false;
        _selectedAssetIds = {};
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added $uploaded file(s) to upload queue'),
          action: SnackBarAction(
            label: 'View Queue',
            onPressed: () => _showUploadQueue(uploadService),
          ),
        ),
      );
    }
  }

  @override
  bool get wantKeepAlive => true;

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
    return _ShimmerTile(icon: _getMediaIcon(item.mediaType));
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

class _ShimmerTile extends StatefulWidget {
  final IconData icon;
  const _ShimmerTile({required this.icon});

  @override
  State<_ShimmerTile> createState() => _ShimmerTileState();
}

class _ShimmerTileState extends State<_ShimmerTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value; // 0..1
        final offset = (t * 2) - 1; // -1..1

        return Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
          ),
          child: ShaderMask(
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment(-1 - offset, -1),
                end: Alignment(1 - offset, 1),
                colors: [
                  Colors.grey.shade800,
                  Colors.grey.shade600,
                  Colors.grey.shade800,
                ],
                stops: const [0.2, 0.5, 0.8],
              ).createShader(rect);
            },
            blendMode: BlendMode.srcATop,
            child: child,
          ),
        );
      },
      child: Center(
        child: Icon(
          widget.icon,
          size: 32,
          color: Colors.white70,
        ),
      ),
    );
  }
}
