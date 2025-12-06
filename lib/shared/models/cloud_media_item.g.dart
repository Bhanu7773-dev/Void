// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cloud_media_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MediaTypeAdapter extends TypeAdapter<MediaType> {
  @override
  final int typeId = 0;

  @override
  MediaType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MediaType.image;
      case 1:
        return MediaType.video;
      case 2:
        return MediaType.document;
      default:
        return MediaType.document;
    }
  }

  @override
  void write(BinaryWriter writer, MediaType obj) {
    switch (obj) {
      case MediaType.image:
        writer.writeByte(0);
        break;
      case MediaType.video:
        writer.writeByte(1);
        break;
      case MediaType.document:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class UploadStatusAdapter extends TypeAdapter<UploadStatus> {
  @override
  final int typeId = 1;

  @override
  UploadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return UploadStatus.pending;
      case 1:
        return UploadStatus.uploading;
      case 2:
        return UploadStatus.completed;
      case 3:
        return UploadStatus.failed;
      default:
        return UploadStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, UploadStatus obj) {
    switch (obj) {
      case UploadStatus.pending:
        writer.writeByte(0);
        break;
      case UploadStatus.uploading:
        writer.writeByte(1);
        break;
      case UploadStatus.completed:
        writer.writeByte(2);
        break;
      case UploadStatus.failed:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UploadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CloudMediaItemAdapter extends TypeAdapter<CloudMediaItem> {
  @override
  final int typeId = 2;

  @override
  CloudMediaItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CloudMediaItem(
      id: fields[0] as String,
      originalFileName: fields[1] as String,
      localThumbnailPath: fields[2] as String?,
      telegramMessageId: fields[3] as int?,
      telegramFileId: fields[4] as String?,
      encryptionIV: fields[5] as String,
      fileSize: fields[6] as int,
      mediaType: fields[7] as MediaType,
      uploadStatus: fields[8] as UploadStatus,
      createdAt: fields[9] as DateTime,
      uploadedAt: fields[10] as DateTime?,
      mimeType: fields[11] as String?,
      errorMessage: fields[12] as String?,
      originalFilePath: fields[13] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CloudMediaItem obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.originalFileName)
      ..writeByte(2)
      ..write(obj.localThumbnailPath)
      ..writeByte(3)
      ..write(obj.telegramMessageId)
      ..writeByte(4)
      ..write(obj.telegramFileId)
      ..writeByte(5)
      ..write(obj.encryptionIV)
      ..writeByte(6)
      ..write(obj.fileSize)
      ..writeByte(7)
      ..write(obj.mediaType)
      ..writeByte(8)
      ..write(obj.uploadStatus)
      ..writeByte(9)
      ..write(obj.createdAt)
      ..writeByte(10)
      ..write(obj.uploadedAt)
      ..writeByte(11)
      ..write(obj.mimeType)
      ..writeByte(12)
      ..write(obj.errorMessage)
      ..writeByte(13)
      ..write(obj.originalFilePath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudMediaItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
