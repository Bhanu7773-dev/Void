import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service to handle runtime permissions for storage access
class PermissionService {
  /// Request all necessary storage permissions based on Android version
  /// Returns true if all required permissions are granted
  static Future<bool> requestStoragePermissions() async {
    // Skip for non-Android platforms or web
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }

    debugPrint('Requesting storage permissions...');
    
    // Request all potentially needed permissions
    // The system will only prompt for ones that are relevant to the Android version
    Map<Permission, PermissionStatus> statuses = await [
      Permission.photos,
      Permission.videos,
      Permission.storage,
    ].request();
    
    for (final entry in statuses.entries) {
      debugPrint('${entry.key}: ${entry.value}');
    }
    
    // Check if we have what we need
    final photosGranted = statuses[Permission.photos]?.isGranted ?? false;
    final videosGranted = statuses[Permission.videos]?.isGranted ?? false;
    final storageGranted = statuses[Permission.storage]?.isGranted ?? false;
    
    // Success if either:
    // - Both photos AND videos are granted (Android 13+)
    // - Storage is granted (Android 12 and below)
    // - Limited access is granted (Android 14+ photo picker)
    final photosLimited = statuses[Permission.photos] == PermissionStatus.limited;
    final videosLimited = statuses[Permission.videos] == PermissionStatus.limited;
    
    final hasAccess = (photosGranted && videosGranted) || 
                      storageGranted || 
                      (photosLimited || videosLimited);
    
    debugPrint('Has storage access: $hasAccess');
    return hasAccess;
  }

  /// Check if storage permissions are already granted
  static Future<bool> hasStoragePermissions() async {
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }

    // Check all permission types
    final photosStatus = await Permission.photos.status;
    final videosStatus = await Permission.videos.status;
    final storageStatus = await Permission.storage.status;
    
    debugPrint('Checking permissions - Photos: $photosStatus, Videos: $videosStatus, Storage: $storageStatus');
    
    // Accept granted or limited (partial) access
    final photosOk = photosStatus.isGranted || photosStatus.isLimited;
    final videosOk = videosStatus.isGranted || videosStatus.isLimited;
    final storageOk = storageStatus.isGranted;
    
    return (photosOk && videosOk) || storageOk;
  }

  /// Check if any permission is permanently denied
  static Future<bool> isPermissionPermanentlyDenied() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }

    final photosPermanent = await Permission.photos.isPermanentlyDenied;
    final storagePermanent = await Permission.storage.isPermanentlyDenied;
    
    debugPrint('Permanently denied - Photos: $photosPermanent, Storage: $storagePermanent');
    
    // Only consider permanently denied if BOTH types are denied
    return photosPermanent && storagePermanent;
  }

  /// Open app settings for the user to manually grant permissions
  static Future<bool> openSettings() async {
    return await openAppSettings();
  }
}
