import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tele_gallery/core/services/telegram_auth_service.dart';

import 'package:tele_gallery/core/constants/keys.dart';

final telegramAuthServiceProvider = Provider<TelegramAuthService>((ref) {
  final service = TelegramAuthService(
    apiId: AppKeys.apiId,
    apiHash: AppKeys.apiHash,
  );
  ref.onDispose(() => service.dispose());
  return service;
});

final authStateProvider = StreamProvider<String>((ref) {
  final authService = ref.watch(telegramAuthServiceProvider);
  return authService.authStateStream;
});
