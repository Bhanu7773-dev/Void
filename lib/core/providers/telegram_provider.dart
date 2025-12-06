import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tele_gallery/features/auth/providers/auth_provider.dart';

/// State for storage channel
class StorageChannelState {
  final int? channelId;
  final bool isLoading;
  final String? error;

  const StorageChannelState({
    this.channelId,
    this.isLoading = false,
    this.error,
  });

  StorageChannelState copyWith({
    int? channelId,
    bool? isLoading,
    String? error,
  }) {
    return StorageChannelState(
      channelId: channelId ?? this.channelId,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool get isReady => channelId != null && !isLoading && error == null;
}

/// Notifier for storage channel management (Riverpod 2.0+ style)
class StorageChannelNotifier extends Notifier<StorageChannelState> {
  @override
  StorageChannelState build() => const StorageChannelState();

  /// Initialize and find/create storage channel
  Future<void> initialize() async {
    if (state.isLoading) return;
    
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      // Use the same auth service that handles authentication
      final telegramService = ref.read(telegramAuthServiceProvider);
      final channelId = await telegramService.findOrCreateStorageChannel();
      state = StorageChannelState(channelId: channelId);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Reset state (for logout)
  void reset() {
    state = const StorageChannelState();
  }
}

/// Provider for storage channel state
final storageChannelProvider = NotifierProvider<StorageChannelNotifier, StorageChannelState>(() {
  return StorageChannelNotifier();
});
