import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/services/crypto_helper.dart';
import '../../../core/services/upload_queue_service.dart';
import '../../../shared/models/cloud_media_item.dart';
import '../../auth/providers/auth_provider.dart';

/// Provider for CryptoHelper
final cryptoHelperProvider = Provider<CryptoHelper>((ref) {
  return CryptoHelper();
});

/// Provider for the media box
final mediaBoxProvider = Provider<Box<CloudMediaItem>>((ref) {
  return Hive.box<CloudMediaItem>('cloud_media');
});

/// Stream of box events to trigger rebuilds on changes
final mediaBoxStreamProvider = StreamProvider<BoxEvent>((ref) {
  final box = ref.watch(mediaBoxProvider);
  return box.watch();
});

/// Notifier to trigger media list refresh
class MediaRefreshNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void refresh() {
    state++;
  }
}

final mediaRefreshProvider = NotifierProvider<MediaRefreshNotifier, int>(() {
  return MediaRefreshNotifier();
});

/// Provider for UploadQueueService (requires storage channel to be set)
final uploadQueueServiceProvider = FutureProvider<UploadQueueService?>((
  ref,
) async {
  final telegramService = ref.watch(telegramAuthServiceProvider);
  final cryptoHelper = ref.watch(cryptoHelperProvider);
  final mediaBox = ref.watch(mediaBoxProvider);

  // Get stored channel ID (assumes findOrCreateStorageChannel was called at startup)
  final channelId = await telegramService.getStoredChannelId();
  if (channelId == null) {
    return null;
  }

  // Initialize crypto helper
  await cryptoHelper.init();

  final service = UploadQueueService(
    telegramService: telegramService,
    cryptoHelper: cryptoHelper,
    mediaBox: mediaBox,
    storageChannelId: channelId,
  );

  // Set callback to refresh media list when upload completes
  service.onQueueChanged = () {
    ref.read(mediaRefreshProvider.notifier).refresh();
  };

  return service;
});

/// Provider for all uploaded media items from Hive
final mediaItemsProvider = Provider<List<CloudMediaItem>>((ref) {
  // Watch the refresh trigger (manual)
  ref.watch(mediaRefreshProvider);

  // Watch the box stream to trigger rebuilds on ANY box change (clear, add, delete)
  ref.watch(mediaBoxStreamProvider);

  final box = ref.watch(mediaBoxProvider);
  final items = box.values.toList();
  // Sort by creation date, newest first
  items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return items;
});

/// Provider for completed uploads only
final completedUploadsProvider = Provider<List<CloudMediaItem>>((ref) {
  final items = ref.watch(mediaItemsProvider);
  return items
      .where((item) => item.uploadStatus == UploadStatus.completed)
      .toList();
});

/// Provider for pending uploads count
final pendingUploadsCountProvider = Provider<int>((ref) {
  final serviceAsync = ref.watch(uploadQueueServiceProvider);
  return serviceAsync.maybeWhen(
    data: (service) => service?.pendingCount ?? 0,
    orElse: () => 0,
  );
});
