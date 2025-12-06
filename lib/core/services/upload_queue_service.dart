import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../shared/models/cloud_media_item.dart';
import 'crypto_helper.dart';
import 'telegram_auth_service.dart';
import 'thumbnail_service.dart';

/// Task status for upload queue (separate from Hive UploadStatus)
enum TaskStatus { pending, encrypting, uploading, completed, failed }

/// Represents an item waiting to be uploaded
class UploadTask {
  final String id;
  final String filePath;
  final MediaType mediaType;
  TaskStatus status;
  String? errorMessage;
  double progress;

  UploadTask({
    required this.id,
    required this.filePath,
    required this.mediaType,
    this.status = TaskStatus.pending,
    this.errorMessage,
    this.progress = 0.0,
  });
}

/// Manages the upload queue with 10-second delays between uploads.
/// Handles encryption, upload to Telegram, and metadata storage in Hive.
class UploadQueueService {
  final TelegramAuthService _telegramService;
  final CryptoHelper _cryptoHelper;
  final Box<CloudMediaItem> _mediaBox;
  final int _storageChannelId;

  static const Duration _uploadDelay = Duration(seconds: 10);
  static const _uuid = Uuid();

  final List<UploadTask> _queue = [];
  bool _isProcessing = false;
  Timer? _delayTimer;

  // Stream controller for upload state updates
  final _stateController = StreamController<List<UploadTask>>.broadcast();
  Stream<List<UploadTask>> get uploadStateStream => _stateController.stream;

  // Callbacks for UI updates
  VoidCallback? onQueueChanged;

  UploadQueueService({
    required TelegramAuthService telegramService,
    required CryptoHelper cryptoHelper,
    required Box<CloudMediaItem> mediaBox,
    required int storageChannelId,
  })  : _telegramService = telegramService,
        _cryptoHelper = cryptoHelper,
        _mediaBox = mediaBox,
        _storageChannelId = storageChannelId;

  /// Get current queue
  List<UploadTask> get queue => List.unmodifiable(_queue);

  /// Get pending count
  int get pendingCount =>
      _queue.where((t) => t.status == TaskStatus.pending).length;

  /// Get completed count
  int get completedCount =>
      _queue.where((t) => t.status == TaskStatus.completed).length;

  /// Check if processing
  bool get isProcessing => _isProcessing;

  /// Add a file to the upload queue
  Future<String> addToQueue(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    final mediaType = _detectMediaType(filePath);
    final taskId = _uuid.v4();

    final task = UploadTask(
      id: taskId,
      filePath: filePath,
      mediaType: mediaType,
    );

    _queue.add(task);
    _notifyStateChange();

    // Start processing if not already running
    if (!_isProcessing) {
      _processQueue();
    }

    return taskId;
  }

  /// Add multiple files to queue
  Future<List<String>> addMultipleToQueue(List<String> filePaths) async {
    final taskIds = <String>[];
    for (final filePath in filePaths) {
      try {
        final id = await addToQueue(filePath);
        taskIds.add(id);
      } catch (e) {
        debugPrint('Failed to add $filePath to queue: $e');
      }
    }
    return taskIds;
  }

  /// Process the upload queue with 10-second delays
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _notifyStateChange();

    while (_queue.any((t) => t.status == TaskStatus.pending)) {
      final task = _queue.firstWhere((t) => t.status == TaskStatus.pending);

      try {
        await _processTask(task);
      } catch (e) {
        task.status = TaskStatus.failed;
        task.errorMessage = e.toString();
        debugPrint('Upload failed for ${task.filePath}: $e');
      }

      _notifyStateChange();

      // Wait 10 seconds before next upload (if there are more)
      if (_queue.any((t) => t.status == TaskStatus.pending)) {
        debugPrint('⏳ Waiting 10 seconds before next upload...');
        await Future.delayed(_uploadDelay);
      }
    }

    _isProcessing = false;
    _notifyStateChange();
    debugPrint('✅ Upload queue completed');
  }

  /// Process a single upload task
  Future<void> _processTask(UploadTask task) async {
    final file = File(task.filePath);
    final fileName = p.basename(task.filePath);
    File? encryptedTempFile;
    String? thumbnailPath;

    try {
      // Step 0: Generate thumbnail for images (before encryption)
      if (task.mediaType == MediaType.image) {
        debugPrint('🖼️ Generating thumbnail for: $fileName');
        thumbnailPath = await ThumbnailService.generateThumbnail(task.filePath, task.id);
      }
      
      // Step 1: Encrypt the file
      task.status = TaskStatus.encrypting;
      task.progress = 0.1;
      _notifyStateChange();
      debugPrint('🔐 Encrypting: $fileName');

      final iv = _cryptoHelper.generateIV();
      final encryptedBytes = await _cryptoHelper.encryptFile(file, iv);

      // Save encrypted bytes to temp file (TDLib needs a file path)
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/void_enc_${task.id}.tmp';
      encryptedTempFile = File(tempPath);
      await encryptedTempFile.writeAsBytes(encryptedBytes);

      task.progress = 0.3;
      _notifyStateChange();

      // Step 2: Upload to Telegram
      task.status = TaskStatus.uploading;
      task.progress = 0.4;
      _notifyStateChange();
      debugPrint('📤 Uploading: $fileName');

      // Create caption with metadata (encrypted filename for later retrieval)
      final caption = 'VOID:$fileName';
      
      debugPrint('📤 Uploading to channel: $_storageChannelId');
      debugPrint('📤 Encrypted file path: ${encryptedTempFile.path}');
      debugPrint('📤 Encrypted file size: ${await encryptedTempFile.length()} bytes');

      final result = await _telegramService.sendFile(
        chatId: _storageChannelId,
        filePath: encryptedTempFile.path,
        caption: caption,
      );
      
      debugPrint('📤 Upload result: $result');

      task.progress = 0.8;
      _notifyStateChange();

      // Step 3: Extract message info and save to Hive
      final messageId = result['id'] as int?;
      String? fileId;

      // Try to get file ID from the message content
      final content = result['content'] as Map<String, dynamic>?;
      if (content != null) {
        // Check document, photo, video, etc.
        final document = content['document'] as Map<String, dynamic>?;
        final photo = content['photo'] as Map<String, dynamic>?;
        final video = content['video'] as Map<String, dynamic>?;

        if (document != null) {
          final docFile = document['document'] as Map<String, dynamic>?;
          fileId = docFile?['remote']?['id'] as String?;
        } else if (photo != null) {
          // Photo has sizes array, get the largest
          final sizes = photo['sizes'] as List<dynamic>?;
          if (sizes != null && sizes.isNotEmpty) {
            final largest = sizes.last as Map<String, dynamic>;
            final photoFile = largest['photo'] as Map<String, dynamic>?;
            fileId = photoFile?['remote']?['id'] as String?;
          }
        } else if (video != null) {
          final videoFile = video['video'] as Map<String, dynamic>?;
          fileId = videoFile?['remote']?['id'] as String?;
        }
      }

      // Save metadata to Hive
      final mediaItem = CloudMediaItem(
        id: task.id,
        originalFileName: fileName,
        localThumbnailPath: thumbnailPath,
        telegramMessageId: messageId,
        telegramFileId: fileId,
        encryptionIV: iv,
        fileSize: await file.length(),
        mediaType: task.mediaType,
        uploadStatus: UploadStatus.completed,
        createdAt: DateTime.now(),
        uploadedAt: DateTime.now(),
        originalFilePath: task.filePath,
      );

      await _mediaBox.put(task.id, mediaItem);

      task.status = TaskStatus.completed;
      task.progress = 1.0;
      debugPrint('✅ Uploaded: $fileName (msgId: $messageId, thumb: $thumbnailPath)');
      
      // DON'T delete temp file immediately - TDLib uploads asynchronously
      // Schedule deletion after TDLib has time to complete the upload
      _scheduleFileDeletion(encryptedTempFile.path);
    } catch (e) {
      // Delete thumbnail on error
      if (thumbnailPath != null) {
        await ThumbnailService.deleteThumbnail(thumbnailPath);
      }
      // Only delete temp file on error
      if (encryptedTempFile != null && await encryptedTempFile.exists()) {
        await encryptedTempFile.delete();
      }
      rethrow;
    }
  }
  
  /// Schedule a file for deletion after TDLib has time to upload it
  void _scheduleFileDeletion(String filePath) {
    // Wait 60 seconds before deleting to give TDLib time to upload
    Future.delayed(const Duration(seconds: 60), () async {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('🗑️ Cleaned up temp file: $filePath');
        }
      } catch (e) {
        debugPrint('Failed to delete temp file: $e');
      }
    });
  }

  /// Detect media type from file extension
  MediaType _detectMediaType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();

    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
    const videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'];

    if (imageExtensions.contains(ext)) {
      return MediaType.image;
    } else if (videoExtensions.contains(ext)) {
      return MediaType.video;
    } else {
      return MediaType.document;
    }
  }

  /// Notify listeners of state change
  void _notifyStateChange() {
    _stateController.add(List.from(_queue));
    onQueueChanged?.call();
  }

  /// Cancel pending uploads
  void cancelPending() {
    _queue.removeWhere((t) => t.status == TaskStatus.pending);
    _notifyStateChange();
  }

  /// Clear completed uploads from queue
  void clearCompleted() {
    _queue.removeWhere((t) => t.status == TaskStatus.completed);
    _notifyStateChange();
  }

  /// Retry failed uploads
  Future<void> retryFailed() async {
    for (final task in _queue) {
      if (task.status == TaskStatus.failed) {
        task.status = TaskStatus.pending;
        task.errorMessage = null;
        task.progress = 0.0;
      }
    }
    _notifyStateChange();

    if (!_isProcessing) {
      _processQueue();
    }
  }

  /// Dispose resources
  void dispose() {
    _delayTimer?.cancel();
    _stateController.close();
  }
}
