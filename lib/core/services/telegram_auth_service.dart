import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/tdlib.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'thumbnail_service.dart';
import 'crypto_helper.dart';

import '../../shared/models/cloud_media_item.dart';

/// Unified Telegram service for auth and all API operations
class TelegramAuthService {
  static const String _storageChannelKey = 'void_storage_channel_id';
  static const String _storageChannelName = 'Void_Storage';
  static const String storageMetaPrefix = '#void_meta ';
  static const String storageConfigPrefix = '#void_config ';
  static const String storageThumbPrefix = '#void_thumb ';

  int? _clientId;
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isReady = false; // Track if we can send phone number
  bool _isAuthenticated = false; // Track if fully authenticated
  bool _tdlibParametersSent = false; // Prevent duplicate setTdlibParameters
  Completer<void>? _readyCompleter;
  Completer<void>? _authCompleter;
  Timer? _receiveTimer;

  final _secureStorage = const FlutterSecureStorage();

  // Completers for request-response pattern
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  int _requestId = 0;

  final _authStateController = StreamController<String>.broadcast();
  Stream<String> get authStateStream => _authStateController.stream;

  // Stream for general updates
  final _updateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updateController.stream;

  final int _apiId;
  final String _apiHash;

  TelegramAuthService({required int apiId, required String apiHash})
    : _apiId = apiId,
      _apiHash = apiHash;

  /// Check if authenticated
  bool get isAuthenticated => _isAuthenticated;

  // Persistent client ID storage file
  Future<File> _getClientIdFile() async {
    final tempDir = await getTemporaryDirectory();
    return File('${tempDir.path}/void_tdlib_session.txt');
  }

  /// Initialize TDLib and wait until it's ready to accept phone number
  Future<void> init() async {
    // Already initialized with this instance - do nothing
    if (_isInitialized && _clientId != null) {
      return;
    }

    _readyCompleter = Completer<void>();
    _authCompleter = Completer<void>();
    _tdlibParametersSent = false;

    try {
      // 1. Initialize native plugin (REQUIRED even for hot restart to bind FFI)
      try {
        await TdNativePlugin.initialize('libtdjson.so');
      } catch (e) {
        print('Failed to init with libtdjson.so, trying process(): $e');
        await TdNativePlugin.initialize();
      }

      // 2. Try to restore existing client from temp file (for Hot Restart)
      final file = await _getClientIdFile();
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          final parts = content.split(':');
          if (parts.length == 2) {
            final savedPid = int.parse(parts[0]);
            final savedClientId = int.parse(parts[1]);

            // Only reuse if in the SAME process (Hot Restart)
            if (savedPid == pid) {
              print('♻️ Restoring TDLib client $savedClientId (PID: $pid)');
              _clientId = savedClientId;
              _isInitialized = true;

              // Set log verbosity (good practice to re-set)
              _send({
                '@type': 'setLogVerbosityLevel',
                'new_verbosity_level': 1,
              });

              // Resume receiving
              _startReceiveLoop();

              // Check status and wait for it
              // We use request() here (which awaits the result) and manually update state.
              // Note: _isInitialized is already true here so request() won't recurs.
              try {
                final state = await request({'@type': 'getAuthorizationState'});
                final type = state['@type'] as String?;

                if (type == 'authorizationStateClosed') {
                  print(
                    '⚰️ Restored client is CLOSED. Destroying and recreating...',
                  );
                  try {
                    TdPlugin.instance.tdJsonClientDestroy(_clientId!);
                  } catch (_) {}
                  _clientId = null;
                  _isInitialized = false;

                  try {
                    await file.delete();
                    print('🧹 Deleted closed client session file');
                  } catch (_) {}

                  // Fall through to create NEW client
                } else {
                  _handleAuthState(state);
                  return; // Successfully restored and active
                }
              } catch (e) {
                print('Error restoring auth state: $e');
                // If error, assume bad state and create new
              }
            } else {
              print(
                '⚠️ Old session from different PID ($savedPid vs $pid), ignoring.',
              );
              await file.delete();
            }
          }
        } catch (e) {
          print('⚠️ Error reading session file: $e');
        }
      }

      // 3. Create NEW client
      _clientId = TdPlugin.instance.tdJsonClientCreate();
      print('✨ Created new TdClient: $_clientId');

      // 4. Save to file for next Hot Restart
      await file.writeAsString('$pid:$_clientId');
      print('💾 Saved client ID to ${file.path}');

      // Set log verbosity
      _send({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1});
    } catch (e) {
      print('Error creating client: $e');
      _readyCompleter?.completeError(e);
      return;
    }

    // Start receiving updates
    _startReceiveLoop();
    _isInitialized = true;
  }

  /// Wait until TDLib is ready to accept phone number
  Future<void> waitUntilReady() async {
    if (_isReady) return;
    await _readyCompleter?.future;
  }

  /// Wait until fully authenticated
  Future<void> waitUntilAuthenticated() async {
    if (_isAuthenticated) return;
    await _authCompleter?.future;
  }

  /// Force TDLib to report the current auth state (useful on cold starts)
  Future<String?> refreshAuthState({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_isInitialized) await init();

    try {
      final state = await request(
        {'@type': 'getAuthorizationState'},
        timeout: timeout,
      );
      final type = state['@type'] as String?;

      // Propagate to the auth stream so UI can jump straight to Home
      if (type != null && type.startsWith('authorizationState')) {
        _handleAuthState(state);
      }

      return type;
    } catch (e) {
      print('⚠️ Failed to refresh auth state: $e');
      return null;
    }
  }

  void _startReceiveLoop() {
    _receiveTimer?.cancel();
    // Use a periodic timer instead of tight Future.doWhile loop
    _receiveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isDisposed) {
        _receiveTimer?.cancel();
        return;
      }
      _pollUpdates();
    });
  }

  void _pollUpdates() {
    if (_clientId == null) return;

    try {
      // Use a very short timeout (0.0) to make it non-blocking
      final result = TdPlugin.instance.tdJsonClientReceive(_clientId!, 0.0);
      if (result != null) {
        final event = jsonDecode(result) as Map<String, dynamic>;
        final eventType = event['@type'] as String?;

        // Log auth-related events and errors
        if (event['@type'] == 'updateAuthorizationState') {
          print('TDLib auth: ${event['authorization_state']['@type']}');
        } else if (eventType == 'error') {
          final message = event['message'] as String? ?? '';
          final code = event['code'] as int? ?? 0;
          print('❌ TDLib error: $code - $message');

          // If we get lock error despite reuse, it means we messed up or multiple clients.
          // But our logic tries to avoid that.
        } else if (eventType == 'ok') {
          // Reduce noise
          // print('✅ TDLib ok response');
        }
        _handleUpdate(event);
      }
    } catch (e) {
      print('TDLib receive error: $e');
    }
  }

  // Remove _handleDatabaseLockError as it's no longer the primary strategy.

  void _handleUpdate(Map<String, dynamic> event) {
    final type = event['@type'] as String?;

    // Check if this is a response to a pending request
    final extra = event['@extra'] as String?;
    if (extra != null && _pendingRequests.containsKey(extra)) {
      final completer = _pendingRequests.remove(extra)!;
      if (type == 'error') {
        completer.completeError(
          TelegramException(
            code: event['code'] as int? ?? 0,
            message: event['message'] as String? ?? 'Unknown error',
          ),
        );
      } else {
        completer.complete(event);
      }
      return;
    }

    if (event['@type'] == 'updateAuthorizationState') {
      _handleAuthState(event['authorization_state']);
    } else if (type == 'updateConnectionState') {
      print('🌐 Connection state: ${event['state']['@type']}');
    } else if (type != null && type.startsWith('authorizationState')) {
      // Handle direct auth state updates (e.g. from getAuthorizationState if sent without request)
      _handleAuthState(event);
    }

    // Broadcast general updates
    if (!_updateController.isClosed) {
      _updateController.add(event);
    }
  }

  void _handleAuthState(Map<String, dynamic> state) {
    final type = state['@type'];
    print('Auth state changed to: $type');

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        print('📤 Sending TDLib parameters...');
        _sendTdlibParameters();
        break;
      case 'authorizationStateWaitPhoneNumber':
        print('✅ TDLib ready for phone number');
        _isReady = true;
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete();
        }
        _authStateController.add('wait_phone');
        break;
      case 'authorizationStateWaitCode':
        _authStateController.add('wait_code');
        break;
      case 'authorizationStateWaitPassword':
        _authStateController.add('wait_password');
        break;
      case 'authorizationStateReady':
        _isAuthenticated = true;

        // Mark as ready too, since we are authenticated
        _isReady = true;
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete();
        }

        if (_authCompleter != null && !_authCompleter!.isCompleted) {
          _authCompleter!.complete();
        }
        _authStateController.add('ready');
        break;
      case 'authorizationStateLoggingOut':
        _isAuthenticated = false;
        _authStateController.add('logging_out');
        break;
      case 'authorizationStateClosed':
        print('🔒 TDLib authorizationStateClosed – resetting client');
        _isAuthenticated = false;
        _isReady = false;
        _tdlibParametersSent = false;
        _receiveTimer?.cancel();

        // Fail waiters so UI doesn't hang
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.completeError(
            TelegramException(code: 0, message: 'TDLib closed'),
          );
        }
        if (_authCompleter != null && !_authCompleter!.isCompleted) {
          _authCompleter!.completeError(
            TelegramException(code: 0, message: 'TDLib closed'),
          );
        }

        if (_clientId != null) {
          try {
            TdPlugin.instance.tdJsonClientDestroy(_clientId!);
          } catch (e) {
            print('Error destroying TDLib client: $e');
          }
          _clientId = null;
        }

        _isInitialized = false;

        // (Optional async clean of the session file)
        () async {
          try {
            final file = await _getClientIdFile();
            if (await file.exists()) {
              await file.delete();
              print('🧹 Deleted session file after closed state');
            }
          } catch (e) {
            print('Error deleting session file: $e');
          }
        }();

        _authStateController.add('closed');
        break;
    }
  }

  Future<void> _sendTdlibParameters() async {
    if (_tdlibParametersSent) {
      // Avoid TDLib 400 Unexpected setTdlibParameters from double-send
      return;
    }

    _tdlibParametersSent = true;

    final appDir = await getApplicationDocumentsDirectory();
    final tdDir = Directory('${appDir.path}/tdlib');
    if (!tdDir.existsSync()) {
      tdDir.createSync(recursive: true);
    }

    print('📁 TDLib database dir: ${tdDir.path}');

    _send({
      '@type': 'setTdlibParameters',
      'database_directory': tdDir.path,
      'use_message_database': true,
      'use_secret_chats': true,
      'api_id': _apiId,
      'api_hash': _apiHash,
      'system_language_code': 'en',
      'device_model': 'Void',
      'application_version': '1.0.0',
      'enable_storage_optimizer': true,
    });
    print('📤 TDLib parameters sent');
  }

  void _send(Map<String, dynamic> request) {
    if (_clientId == null) return;
    try {
      TdPlugin.instance.tdJsonClientSend(_clientId!, jsonEncode(request));
    } catch (e) {
      print('Error sending: $e');
    }
  }

  /// Send a request and wait for response (customizable timeout)
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> req, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_isInitialized) await init();

    final requestId = 'req_${++_requestId}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    req['@extra'] = requestId;
    _send(req);

    // Allow custom timeout for slower calls (e.g., getChats on cold start)
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw TimeoutException('Request timed out: ${req['@type']}');
      },
    );
  }

  Future<void> sendCode(String phoneNumber) async {
    if (!_isInitialized) await init();

    // Wait until TDLib is ready to accept phone number
    await waitUntilReady();

    print('Sending phone number: $phoneNumber');
    _send({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber,
      'settings': {
        '@type': 'phoneNumberAuthenticationSettings',
        'allow_flash_call': false,
        'allow_missed_call': false,
        'is_current_phone_number': false,
        'allow_sms_retriever_api': false,
      },
    });
  }

  Future<void> signIn(String code) async {
    if (!_isInitialized) await init();
    print('Verifying code: $code');
    _send({'@type': 'checkAuthenticationCode', 'code': code});
  }

  Future<void> checkPassword(String password) async {
    if (!_isInitialized) await init();
    print('Checking password');
    _send({'@type': 'checkAuthenticationPassword', 'password': password});
  }

  Future<void> logOut() async {
    if (!_isInitialized || _clientId == null) return;

    print('🚪 Logging out...');
    _isAuthenticated = false;

    // Ask TDLib to log out
    _send({'@type': 'logOut'});

    // Optional: tiny delay to let loggingOut/Closed propagate
    await Future.delayed(const Duration(milliseconds: 100));

    // Close the TDLib client and free DB lock
    _send({'@type': 'close'});

    try {
      TdPlugin.instance.tdJsonClientDestroy(_clientId!);
    } catch (e) {
      print('Error destroying TDLib client: $e');
    }

    _clientId = null;
    _isInitialized = false;
    _isReady = false;
    _tdlibParametersSent = false;

    // Clear stored channel ID on logout
    await _secureStorage.delete(key: _storageChannelKey);

    // Delete the hot-restart client-id file so we don't try to restore this client
    try {
      final file = await _getClientIdFile();
      if (await file.exists()) {
        await file.delete();
        print('🧹 Deleted client session file on logout');
      }
    } catch (e) {
      print('Error deleting session file: $e');
    }
  }

  /// Check if a chat is a valid, usable Void_Storage channel
  Future<bool> _isValidStorageChannelChat(Map<String, dynamic> chat) async {
    final title = chat['title'] as String? ?? '';
    final chatType = chat['type'] as Map<String, dynamic>?;

    // Must match name & be a supergroup-channel
    if (title != _storageChannelName) return false;
    if (chatType?['@type'] != 'chatTypeSupergroup') return false;
    if (chatType?['is_channel'] != true) return false;

    final supergroupId = chatType?['supergroup_id'] as int?;
    if (supergroupId == null) return false;

    try {
      // Ask TDLib for supergroup info (forces server sync if needed)
      final supergroup = await request({
        '@type': 'getSupergroup',
        'supergroup_id': supergroupId,
      });

      final isDeleted = supergroup['is_deleted'] as bool? ?? false;
      final status = supergroup['status'] as Map<String, dynamic>?;
      final statusType = status?['@type'] as String? ?? '';

      // Consider invalid if deleted or we left/are banned
      final hasAccess =
          statusType != 'chatMemberStatusLeft' &&
          statusType != 'chatMemberStatusBanned';

      if (isDeleted || !hasAccess) {
        print(
          '⚠️ Storage channel supergroup invalid: '
          'isDeleted=$isDeleted, status=$statusType',
        );
        return false;
      }

      return true;
    } on TelegramException catch (e) {
      print('⚠️ getSupergroup failed for storage chat: $e');
      return false;
    } catch (e) {
      print('⚠️ Unknown error checking storage channel: $e');
      return false;
    }
  }

  /// Clear all local data (files & DB) when storage channel is reset
  Future<void> _clearLocalData() async {
    print('🧹 Clearing local data due to storage channel recreation...');
    try {
      // Open box if not already open (it should be, but safety first)
      if (!Hive.isBoxOpen('cloud_media')) {
        await Hive.openBox<CloudMediaItem>('cloud_media');
      }

      final box = Hive.box<CloudMediaItem>('cloud_media');

      // 1. Delete thumbnail files
      for (var item in box.values) {
        if (item.localThumbnailPath != null &&
            item.localThumbnailPath!.isNotEmpty) {
          try {
            final file = File(item.localThumbnailPath!);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (e) {
            print('Error deleting thumbnail for ${item.id}: $e');
          }
        }
      }

      // 2. Clear Metadata
      await box.clear();
      print('✅ Local thumbnails and DB entries cleared.');
    } catch (e) {
      print('⚠️ Error clearing local data: $e');
    }
  }

  // ============ API Methods (for use after authentication) ============

  /// Get current user info
  Future<Map<String, dynamic>> getMe() async {
    await waitUntilAuthenticated();
    return request({'@type': 'getMe'});
  }

  /// Ensure vault config message (salt/iterations) exists in storage channel
  Future<void> ensureVaultConfig({
    required int chatId,
    required String saltBase64,
    required int iterations,
  }) async {
    await waitUntilAuthenticated();

    // Look for existing config in recent history
    try {
      final page = await request({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': 0,
        'offset': 0,
        'limit': 50,
        'only_local': false,
      });

      final messages = (page['messages'] as List?) ?? [];
      for (final raw in messages) {
        final msg = raw as Map<String, dynamic>;
        final content = msg['content'] as Map<String, dynamic>?;
        if (content?['@type'] != 'messageText') continue;
        final textObj = content?['text'] as Map<String, dynamic>?;
        final text = textObj?['text'] as String? ?? '';
        if (text.startsWith(storageConfigPrefix)) {
          return; // already present
        }
      }
    } catch (e) {
      print('⚠️ ensureVaultConfig history check failed: $e');
    }

    final payload = jsonEncode({
      'v': 1,
      'salt': saltBase64,
      'iter': iterations,
    });

    try {
      await request({
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageText',
          'text': {
            '@type': 'formattedText',
            'text': '$storageConfigPrefix$payload',
          },
        },
      });
      print('✅ Posted vault config to storage channel');
    } catch (e) {
      print('⚠️ Failed to post vault config: $e');
    }
  }

  MediaType _parseMediaType(String? raw) {
    switch (raw) {
      case 'image':
        return MediaType.image;
      case 'video':
        return MediaType.video;
      default:
        return MediaType.document;
    }
  }

  /// Rebuild local index from storage channel history
  Future<int> rebuildIndexFromStorageChannel({
    required Box<CloudMediaItem> mediaBox,
    bool force = false,
  }) async {
    await waitUntilAuthenticated();

    // Skip if data already present unless forced
    if (!force && mediaBox.isNotEmpty) {
      print('📦 Rebuild skipped (local cache already populated)');
      return 0;
    }

    final me = await getMe();
    final myId = me['id'] as int;
    final chatId = await findOrCreateStorageChannel();

    final Map<String, Map<String, String>> thumbIndex = {};

    int imported = 0;
    int? fromMessageId;
    bool done = false;

    while (!done) {
      final page = await request({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': fromMessageId ?? 0,
        'offset': 0,
        'limit': 100,
        'only_local': false,
      });

      final messages = (page['messages'] as List?) ?? [];
      if (messages.isEmpty) {
        done = true;
        break;
      }

      for (final raw in messages) {
        final msg = raw as Map<String, dynamic>;

        // Only messages sent by us (user) or by the storage channel itself
        final sender = msg['sender_id'] as Map<String, dynamic>?;
        final senderType = sender?['@type'] as String?;
        final senderUserId = sender?['user_id'] as int?;
        final senderChatId = sender?['chat_id'] as int?;
        final isOurUser = senderType == 'messageSenderUser' && senderUserId == myId;
        final isOurChannel = senderType == 'messageSenderChat' && senderChatId == chatId;
        if (!isOurUser && !isOurChannel) continue;

        final content = msg['content'] as Map<String, dynamic>?;
        if (content == null) continue;

        // Config message (#void_config)
        if (content['@type'] == 'messageText') {
          final textObj = content['text'] as Map<String, dynamic>?;
          final text = textObj?['text'] as String? ?? '';
          if (text.startsWith(storageConfigPrefix)) {
            final jsonPart = text.substring(storageConfigPrefix.length);
            try {
              final cfg = jsonDecode(jsonPart) as Map<String, dynamic>;
              final salt = cfg['salt'] as String?;
              final iter = cfg['iter'] as int?;
              if (salt != null && iter != null) {
                await _secureStorage.write(key: 'void_pbkdf2_salt', value: salt);
                await _secureStorage.write(key: 'void_pbkdf2_iterations', value: iter.toString());
              }
            } catch (_) {
              // ignore malformed config
            }
          }
          continue;
        }

        if (content['@type'] != 'messageDocument') continue;

        final captionObj = content['caption'] as Map<String, dynamic>?;
        final captionText = captionObj?['text'] as String? ?? '';

        // Thumbnail message (#void_thumb)
        if (captionText.startsWith(storageThumbPrefix)) {
          final jsonPart = captionText.substring(storageThumbPrefix.length);
          try {
            final meta = jsonDecode(jsonPart) as Map<String, dynamic>;
            final targetId = meta['id'] as String?;
            final thumbIv = meta['iv'] as String?;

            final doc = content['document'] as Map<String, dynamic>?;
            final docFile = doc?['document'] as Map<String, dynamic>?;
            final remoteId = docFile?['remote']?['id'] as String?;

            if (targetId != null && thumbIv != null && remoteId != null) {
              thumbIndex[targetId] = {'id': remoteId, 'iv': thumbIv};
            }
          } catch (_) {}
          continue;
        }

        if (!captionText.startsWith(storageMetaPrefix)) continue;

        final jsonPart = captionText.substring(storageMetaPrefix.length);
        Map<String, dynamic> meta;
        try {
          meta = jsonDecode(jsonPart) as Map<String, dynamic>;
        } catch (e) {
          continue;
        }

        final iv = meta['iv'] as String?;
        if (iv == null || iv.isEmpty) continue;

        final doc = content['document'] as Map<String, dynamic>?;
        final docFile = doc?['document'] as Map<String, dynamic>?;
        final remoteId = docFile?['remote']?['id'] as String?;
        final sizeFromDoc = docFile?['size'] as int?;
        if (remoteId == null) continue;

        final messageId = msg['id'] as int?;
        if (messageId == null) continue;

        final metaId = meta['id'] as String? ?? messageId.toString();
        final createdAtStr = meta['created_at'] as String?;
        final createdAt = createdAtStr != null
            ? DateTime.tryParse(createdAtStr) ?? DateTime.now()
            : DateTime.now();

        final thumbData = thumbIndex[metaId];

        final item = CloudMediaItem(
          id: metaId,
          originalFileName: meta['name'] as String? ?? 'file',
          localThumbnailPath: null,
          telegramMessageId: messageId,
          telegramFileId: remoteId,
          thumbnailFileId: thumbData?['id'],
          thumbnailIV: thumbData?['iv'],
          encryptionIV: iv,
          fileSize: meta['size'] as int? ?? sizeFromDoc ?? 0,
          mediaType: _parseMediaType(meta['media_type'] as String?),
          uploadStatus: UploadStatus.completed,
          createdAt: createdAt,
          uploadedAt: createdAt,
          mimeType: meta['mime'] as String?,
          originalFilePath: null,
        );

        await mediaBox.put(item.id, item);
        imported++;
      }

      final lastMsg = messages.last as Map<String, dynamic>;
      fromMessageId = lastMsg['id'] as int?;
    }

    print('✅ Rebuilt local index with $imported items');
    return imported;
  }

  /// Search for chats by title (fast - no loadChats delay)
  Future<List<Map<String, dynamic>>> searchChats(
    String query, {
    int limit = 50,
  }) async {
    await waitUntilAuthenticated();

    // Use searchChats directly - TDLib searches cached + server chats
    final result = await request({
      '@type': 'searchChats',
      'query': query,
      'limit': limit,
    });

    final chatIds = (result['chat_ids'] as List?)?.cast<int>() ?? [];
    final chats = <Map<String, dynamic>>[];

    for (final chatId in chatIds) {
      try {
        final chat = await getChat(chatId);
        chats.add(chat);
      } catch (e) {
        print('Error getting chat $chatId: $e');
      }
    }

    return chats;
  }

  /// Search for chats in archive folder (fast - direct getChats)
  Future<List<Map<String, dynamic>>> searchArchivedChats(
    String query, {
    int limit = 50,
  }) async {
    await waitUntilAuthenticated();

    // Get archived chat IDs directly - no loadChats needed
    final archivedResult = await request({
      '@type': 'getChats',
      'chat_list': {'@type': 'chatListArchive'},
      'limit': limit,
    }, timeout: const Duration(seconds: 15));

    final chatIds = (archivedResult['chat_ids'] as List?)?.cast<int>() ?? [];
    final chats = <Map<String, dynamic>>[];

    for (final chatId in chatIds) {
      try {
        final chat = await getChat(chatId);
        final title = chat['title'] as String? ?? '';
        // Filter by query
        if (title.toLowerCase().contains(query.toLowerCase())) {
          chats.add(chat);
        }
      } catch (e) {
        print('Error getting archived chat $chatId: $e');
      }
    }

    return chats;
  }

  /// Archive a chat
  Future<void> archiveChat(int chatId) async {
    await waitUntilAuthenticated();
    await request({
      '@type': 'addChatToList',
      'chat_id': chatId,
      'chat_list': {'@type': 'chatListArchive'},
    });
    print('📦 Archived chat: $chatId');
  }

  /// Get chat by ID
  Future<Map<String, dynamic>> getChat(int chatId) async {
    await waitUntilAuthenticated();
    return request({'@type': 'getChat', 'chat_id': chatId});
  }

  /// Ensure chat is in archive list so TDLib can fetch it
  Future<void> _ensureChatInArchive(int chatId) async {
    try {
      await request({
        '@type': 'addChatToList',
        'chat_id': chatId,
        'chat_list': {'@type': 'chatListArchive'},
      });
    } catch (_) {
      // ignore — if already in archive or inaccessible, TDLib may throw
    }
  }

  /// Fast server-side lookup for the storage channel by exact title.
  /// This does NOT scan the archive; it just asks the server directly.
  Future<int?> _findStorageChannelOnServer() async {
    await waitUntilAuthenticated();

    try {
      final result = await request(
        {
          '@type': 'searchChatsOnServer',
          'query': _storageChannelName,
          'limit': 10,
        },
        timeout: const Duration(seconds: 15),
      );

      final ids = (result['chat_ids'] as List?)?.cast<int>() ?? [];

      for (final id in ids) {
        try {
          final chat = await request(
            {
              '@type': 'getChat',
              'chat_id': id,
            },
            timeout: const Duration(seconds: 10),
          );

          if (await _isValidStorageChannelChat(chat)) {
            print('✅ _findStorageChannelOnServer found channel: $id');
            // Ensure it lives in archive for cleanliness
            await archiveChat(id);
            return id;
          }
        } on TelegramException catch (e) {
          print('⚠️ getChat failed for candidate $id: $e');
        } catch (e) {
          print('⚠️ Unknown error reading candidate chat $id: $e');
        }
      }

      print('ℹ️ _findStorageChannelOnServer: no matching channel found');
      return null;
    } on TelegramException catch (e) {
      print('⚠️ searchChatsOnServer failed: $e');
      return null;
    } catch (e) {
      print('⚠️ searchChatsOnServer unknown error: $e');
      return null;
    }
  }

  /// Create a new private channel (supergroup)
  Future<Map<String, dynamic>> createPrivateChannel(
    String title,
    String description,
  ) async {
    await waitUntilAuthenticated();
    return request({
      '@type': 'createNewSupergroupChat',
      'title': title,
      'is_forum': false,
      'is_channel': true,
      'description': description,
      'location': null,
      'message_auto_delete_time': 0,
      'for_import': false,
    });
  }

  /// Find or create the storage channel as fast as possible.
  ///
  /// Strategy:
  /// 1. Try stored channel ID (fast path).
  /// 2. Try server-side search by title (no heavy archive load).
  /// 3. If not found, create a new private channel, archive it, store the ID.
  Future<int> findOrCreateStorageChannel() async {
    await waitUntilAuthenticated();

    // 1️⃣ Fast path – use stored ID if valid
    final storedId = await _secureStorage.read(key: _storageChannelKey);
    if (storedId != null) {
      final channelId = int.tryParse(storedId);
      if (channelId != null) {
        try {
          // Make sure it’s archived (no-op if already)
          await _ensureChatInArchive(channelId);

          final chat = await request(
            {
              '@type': 'getChat',
              'chat_id': channelId,
            },
            timeout: const Duration(seconds: 10),
          );

          if (await _isValidStorageChannelChat(chat)) {
            print('✅ Reusing stored storage channel: $channelId');
            await archiveChat(channelId);
            return channelId;
          } else {
            print(
              '⚠️ Stored channel $channelId no longer valid, clearing key.',
            );
            await _secureStorage.delete(key: _storageChannelKey);
          }
        } catch (e) {
          print(
            '⚠️ Stored channel $storedId not accessible ($e), clearing key.',
          );
          await _secureStorage.delete(key: _storageChannelKey);
        }
      } else {
        await _secureStorage.delete(key: _storageChannelKey);
      }
    }

    // 2️⃣ Fast server lookup (Teledrive-like behavior: ask server, don’t load all chats)
    print('🔎 Trying fast server lookup for $_storageChannelName ...');
    final serverId = await _findStorageChannelOnServer();
    if (serverId != null) {
      await _secureStorage.write(
        key: _storageChannelKey,
        value: serverId.toString(),
      );
      print('✅ Using server-discovered storage channel: $serverId');
      return serverId;
    }

    // 3️⃣ Not found anywhere → create brand new channel
    print('📦 No existing storage channel found. Creating new one...');

    // Important: clear local DB because we’re switching to a fresh channel
    await _clearLocalData();

    final newChat = await createPrivateChannel(
      _storageChannelName,
      'Private storage for Void app. Do not delete or share.',
    );

    final newId = newChat['id'] as int;
    print('✅ Created new storage channel: $newId – archiving it');

    await archiveChat(newId);

    await _secureStorage.write(
      key: _storageChannelKey,
      value: newId.toString(),
    );

    return newId;
  }

  /// Get stored channel ID (without verifying)
  Future<int?> getStoredChannelId() async {
    final storedId = await _secureStorage.read(key: _storageChannelKey);
    return storedId != null ? int.tryParse(storedId) : null;
  }

  /// Send a file to a chat
  Future<Map<String, dynamic>> sendFile({
    required int chatId,
    required String filePath,
    String? caption,
  }) async {
    await waitUntilAuthenticated();

    // Verify file exists
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File does not exist: $filePath');
    }
    final fileSize = await file.length();
    print('📤 Sending file: $filePath (${fileSize} bytes) to chat $chatId');

    try {
      final result = await request({
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageDocument',
          'document': {'@type': 'inputFileLocal', 'path': filePath},
          'caption': caption != null
              ? {'@type': 'formattedText', 'text': caption}
              : null,
          'disable_content_type_detection': false,
        },
      });

      print('📤 sendMessage result: ${result['@type']} - id: ${result['id']}');

      final sendingState = result['sending_state'];
      if (sendingState != null) {
        print('📤 Sending state: ${sendingState['@type']}');
      }

      return result;
    } on TelegramException catch (e) {
      print('❌ sendFile TelegramException: $e');

      // If chat became invalid (e.g. 400 CHAT_NOT_FOUND or write forbidden), clear and recreate storage channel
      if (e.code == 400) {
        print(
          '⚠️ Chat invalid error (400). Clearing storage key and attempting recreation next time.',
        );
        await _secureStorage.delete(key: _storageChannelKey);
      }
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  /// Download a file
  Future<String> downloadFile(int fileId, {int priority = 1}) async {
    await waitUntilAuthenticated();
    final result = await request({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': priority,
      'offset': 0,
      'limit': 0,
      'synchronous': true,
    });

    final local = result['local'] as Map<String, dynamic>?;
    final path = local?['path'] as String?;

    if (path == null || path.isEmpty) {
      throw TelegramException(code: 0, message: 'File download failed');
    }

    return path;
  }

  /// Download a file using remote file ID (string) -> returns local path
  Future<String> downloadFileByRemoteId(String remoteFileId) async {
    await waitUntilAuthenticated();
    final file = await request({
      '@type': 'getRemoteFile',
      'remote_file_id': remoteFileId,
      'only_if_prior': false,
    });

    final fileId = file['id'] as int?;
    if (fileId == null) {
      throw TelegramException(code: 0, message: 'Remote file lookup failed');
    }

    return downloadFile(fileId);
  }

  /// Backfill thumbnails for imported images (downloads + decrypts)
  Future<int> backfillThumbnailsForImages({
    required Box<CloudMediaItem> mediaBox,
    required CryptoHelper cryptoHelper,
    int? maxCount,
    int? maxBytes,
  }) async {
    await waitUntilAuthenticated();

    int generated = 0;
    final items = mediaBox.values.where((item) {
      final hasThumbRemote = item.thumbnailFileId != null && item.thumbnailIV != null;
      final hasMainRemote = item.telegramFileId != null;
      return item.mediaType == MediaType.image &&
          (item.localThumbnailPath == null || item.localThumbnailPath!.isEmpty) &&
          (hasThumbRemote || (hasMainRemote && item.encryptionIV.isNotEmpty));
    }).toList();

    for (final item in items) {
      if (maxCount != null && generated >= maxCount) break;

      try {
        // Prefer dedicated thumbnail if available (smaller download)
        if (item.thumbnailFileId != null && item.thumbnailIV != null) {
          final thumbPath = await _downloadAndDecryptThumbnail(
            remoteFileId: item.thumbnailFileId!,
            ivBase64: item.thumbnailIV!,
            itemId: item.id,
            cryptoHelper: cryptoHelper,
          );

          if (thumbPath != null) {
            await mediaBox.put(item.id, item.copyWith(localThumbnailPath: thumbPath));
            generated++;
            continue;
          }
        }

        final encryptedPath = await downloadFileByRemoteId(item.telegramFileId!);

        // Skip very large files if a size cap is provided to avoid filling disk
        if (maxBytes != null) {
          final encFile = File(encryptedPath);
          final size = await encFile.length();
          if (size > maxBytes) {
            print('Thumbnail backfill skipped for ${item.id} (size $size > $maxBytes)');
            continue;
          }
        }

        final tempDir = await getTemporaryDirectory();
        final decryptedPath = p.join(tempDir.path, 'void_dec_${item.id}.tmp');
        await cryptoHelper.decryptFileToPath(File(encryptedPath), item.encryptionIV, decryptedPath);

        final thumbPath = await ThumbnailService.generateThumbnail(decryptedPath, item.id);

        // clean up decrypted temp file
        try {
          final f = File(decryptedPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}

        // clean up encrypted download to avoid filling cache
        try {
          final f = File(encryptedPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}

        if (thumbPath != null) {
          await mediaBox.put(item.id, item.copyWith(localThumbnailPath: thumbPath));
          generated++;
        }
      } catch (e) {
        print('Thumbnail backfill failed for ${item.id}: $e');
      }
    }

    return generated;
  }

  Future<String?> _downloadAndDecryptThumbnail({
    required String remoteFileId,
    required String ivBase64,
    required String itemId,
    required CryptoHelper cryptoHelper,
  }) async {
    try {
      final encPath = await downloadFileByRemoteId(remoteFileId);
      final tempDir = await ThumbnailService.getThumbnailDir();
      final destPath = p.join(tempDir.path, '${itemId}_remote_thumb.jpg');

      await cryptoHelper.decryptFileToPath(
        File(encPath),
        ivBase64,
        destPath,
      );

      // clean up encrypted file
      try {
        final f = File(encPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}

      return destPath;
    } catch (e) {
      print('Thumbnail remote download failed for $itemId: $e');
      return null;
    }
  }

  /// Delete a message from a chat
  Future<void> deleteMessage(int chatId, int messageId) async {
    await waitUntilAuthenticated();
    await request({
      '@type': 'deleteMessages',
      'chat_id': chatId,
      'message_ids': [messageId],
      'revoke': true,
    });
    print('🗑️ Deleted message $messageId from chat $chatId');
  }

  void dispose() {
    _isDisposed = true;
    _receiveTimer?.cancel();
    _authStateController.close();
    _updateController.close();

    // Complete any pending requests with error
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          TelegramException(code: 0, message: 'Service disposed'),
        );
      }
    }
    _pendingRequests.clear();

    // DO NOT destroy client on dispose, so it survives Hot Restart
    // The OS will clean up when the process actually dies
    // if (_clientId != null) {
    //   _send({'@type': 'close'});
    //   TdPlugin.instance.tdJsonClientDestroy(_clientId!);
    // }
  }
}

class TelegramException implements Exception {
  final int code;
  final String message;

  TelegramException({required this.code, required this.message});

  @override
  String toString() => 'TelegramException($code): $message';
}
