import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Service for generating thumbnails from images
class ThumbnailService {
  static const int thumbnailSize = 200;
  
  /// Get the thumbnails directory
  static Future<Directory> getThumbnailDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory('${appDir.path}/thumbnails');
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    return thumbDir;
  }
  
  /// Generate a thumbnail for an image file
  /// Returns the path to the generated thumbnail, or null if failed
  static Future<String?> generateThumbnail(String imagePath, String itemId) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        debugPrint('Thumbnail: Source file not found: $imagePath');
        return null;
      }
      
      // Read and decode image in isolate to avoid blocking UI
      final bytes = await file.readAsBytes();
      final thumbnailBytes = await compute(_generateThumbnailBytes, bytes);
      
      if (thumbnailBytes == null) {
        debugPrint('Thumbnail: Failed to decode image');
        return null;
      }
      
      // Save thumbnail
      final thumbDir = await getThumbnailDir();
      final thumbPath = '${thumbDir.path}/$itemId.jpg';
      final thumbFile = File(thumbPath);
      await thumbFile.writeAsBytes(thumbnailBytes);
      
      debugPrint('Thumbnail: Generated $thumbPath');
      return thumbPath;
    } catch (e) {
      debugPrint('Thumbnail generation error: $e');
      return null;
    }
  }
  
  /// Generate thumbnail bytes (runs in isolate)
  static Uint8List? _generateThumbnailBytes(Uint8List imageBytes) {
    try {
      // Decode image
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;
      
      // Resize to thumbnail
      final thumbnail = img.copyResize(
        image,
        width: image.width > image.height ? thumbnailSize : null,
        height: image.height >= image.width ? thumbnailSize : null,
        interpolation: img.Interpolation.linear,
      );
      
      // Encode as JPEG with quality 80
      return Uint8List.fromList(img.encodeJpg(thumbnail, quality: 80));
    } catch (e) {
      return null;
    }
  }
  
  /// Delete a thumbnail
  static Future<void> deleteThumbnail(String? thumbnailPath) async {
    if (thumbnailPath == null) return;
    try {
      final file = File(thumbnailPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Thumbnail: Deleted $thumbnailPath');
      }
    } catch (e) {
      debugPrint('Thumbnail deletion error: $e');
    }
  }
  
  /// Check if a thumbnail exists
  static Future<bool> thumbnailExists(String? thumbnailPath) async {
    if (thumbnailPath == null) return false;
    return File(thumbnailPath).exists();
  }
}
