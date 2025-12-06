import 'package:hive/hive.dart';

part 'cloud_media_item.g.dart';

/// Media type enum
@HiveType(typeId: 0)
enum MediaType {
  @HiveField(0)
  image,
  @HiveField(1)
  video,
  @HiveField(2)
  document,
}

/// Upload status enum
@HiveType(typeId: 1)
enum UploadStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  uploading,
  @HiveField(2)
  completed,
  @HiveField(3)
  failed,
}

/// Model for media items stored in the cloud (Telegram channel)
@HiveType(typeId: 2)
class CloudMediaItem extends HiveObject {
  /// Unique identifier (UUID)
  @HiveField(0)
  final String id;

  /// Original filename
  @HiveField(1)
  final String originalFileName;

  /// Path to local thumbnail
  @HiveField(2)
  String? localThumbnailPath;

  /// Telegram message ID (after upload)
  @HiveField(3)
  int? telegramMessageId;

  /// Telegram file ID (for downloading)
  @HiveField(4)
  String? telegramFileId;

  /// Remote file ID for encrypted thumbnail (if uploaded separately)
  @HiveField(14)
  String? thumbnailFileId;

  /// IV for encrypted thumbnail (base64)
  @HiveField(15)
  String? thumbnailIV;

  /// Encryption IV (Initialization Vector) - base64 encoded
  @HiveField(5)
  final String encryptionIV;

  /// File size in bytes
  @HiveField(6)
  final int fileSize;

  /// Media type
  @HiveField(7)
  final MediaType mediaType;

  /// Upload status
  @HiveField(8)
  UploadStatus uploadStatus;

  /// Creation timestamp
  @HiveField(9)
  final DateTime createdAt;

  /// Upload timestamp
  @HiveField(10)
  DateTime? uploadedAt;

  /// MIME type
  @HiveField(11)
  final String? mimeType;

  /// Error message if upload failed
  @HiveField(12)
  String? errorMessage;

  /// Original file path (for pending uploads)
  @HiveField(13)
  String? originalFilePath;

  CloudMediaItem({
    required this.id,
    required this.originalFileName,
    this.localThumbnailPath,
    this.telegramMessageId,
    this.telegramFileId,
    this.thumbnailFileId,
    this.thumbnailIV,
    required this.encryptionIV,
    required this.fileSize,
    required this.mediaType,
    this.uploadStatus = UploadStatus.pending,
    required this.createdAt,
    this.uploadedAt,
    this.mimeType,
    this.errorMessage,
    this.originalFilePath,
  });

  /// Check if the item has been uploaded
  bool get isUploaded => uploadStatus == UploadStatus.completed && telegramMessageId != null;

  /// Get file extension
  String get extension => originalFileName.split('.').last.toLowerCase();

  /// Create a copy with updated fields
  CloudMediaItem copyWith({
    String? localThumbnailPath,
    int? telegramMessageId,
    String? telegramFileId,
    String? thumbnailFileId,
    String? thumbnailIV,
    UploadStatus? uploadStatus,
    DateTime? uploadedAt,
    String? errorMessage,
    String? originalFilePath,
  }) {
    return CloudMediaItem(
      id: id,
      originalFileName: originalFileName,
      localThumbnailPath: localThumbnailPath ?? this.localThumbnailPath,
      telegramMessageId: telegramMessageId ?? this.telegramMessageId,
      telegramFileId: telegramFileId ?? this.telegramFileId,
      thumbnailFileId: thumbnailFileId ?? this.thumbnailFileId,
      thumbnailIV: thumbnailIV ?? this.thumbnailIV,
      encryptionIV: encryptionIV,
      fileSize: fileSize,
      mediaType: mediaType,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      createdAt: createdAt,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      mimeType: mimeType,
      errorMessage: errorMessage ?? this.errorMessage,
      originalFilePath: originalFilePath ?? this.originalFilePath,
    );
  }
}
