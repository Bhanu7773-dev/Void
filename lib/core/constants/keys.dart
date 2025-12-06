// For development, create keys_local.dart with your actual keys
// For production, pass keys via --dart-define

import 'keys_local.dart';

class AppKeys {
  // Uses keys_local.dart in development
  static const int apiId = AppKeysLocal.apiId;
  static const String apiHash = AppKeysLocal.apiHash;
}
