import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/tdlib.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tele_gallery/shared/models/cloud_media_item.dart';

/// Unified Telegram service for auth and all API operations
class TelegramAuthService {
  static const String _storageChannelKey = 'void_storage_channel_id';
  static const String _storageChannelName = 'Void_Storage';

  int? _clientId;
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isReady = false; // Track if we can send phone number
  bool _isAuthenticated = false; // Track if fully authenticated
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

  /// Send a request and wait for response
  Future<Map<String, dynamic>> request(Map<String, dynamic> req) async {
    if (!_isInitialized) await init();

    final requestId = 'req_${++_requestId}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    req['@extra'] = requestId;
    _send(req);

    // Timeout after 15 seconds (most ops are fast)
    return completer.future.timeout(
      const Duration(seconds: 15),
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
    });

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

  /// Find or create the storage channel (Strictly Archive only)
  Future<int> findOrCreateStorageChannel() async {
    await waitUntilAuthenticated();

    // First check if we have a stored channel ID
    final storedId = await _secureStorage.read(key: _storageChannelKey);
    if (storedId != null) {
      final channelId = int.tryParse(storedId);
      if (channelId != null) {
        // Verify the channel still exists and is accessible
        try {
          final chat = await getChat(channelId);

          if (await _isValidStorageChannelChat(chat)) {
            print('✅ Reusing stored storage channel: ${chat['title']}');
            // ensure it’s archived
            await archiveChat(channelId);
            return channelId;
          } else {
            print(
              'Stored chat $channelId is no longer valid, clearing stored ID.',
            );
            await _secureStorage.delete(key: _storageChannelKey);
          }
        } catch (e) {
          print('Stored channel no longer accessible ($e), will search/create');
          await _secureStorage.delete(key: _storageChannelKey);
        }
      }
    }

    print('🔍 Searching for $_storageChannelName in ARCHIVE only...');

    // Use direct search to find candidates
    final chats = await searchChats(_storageChannelName);
    print('Found ${chats.length} candidates');

    // Please keep searchCandidates minimal as requested: strictly archive only search.
    // However, verify each candidate using _isValidStorageChannelChat as requested.

    // Filter for one that is IN THE ARCHIVE and VALID
    for (final chat in chats) {
      final title = chat['title'] as String?;
      final chatType = chat['type'] as Map<String, dynamic>?;
      final isChannel =
          chatType?['@type'] == 'chatTypeSupergroup' &&
          (chatType?['is_channel'] == true);

      if (title == _storageChannelName && isChannel) {
        // Check if it is in archive
        final chatLists = chat['chat_lists'] as List<dynamic>? ?? [];
        final isInArchive = chatLists.any(
          (l) => l['@type'] == 'chatListArchive',
        );

        if (isInArchive) {
          final chatId = chat['id'] as int;

          // Verify it is actually VALID (not deleted)
          if (await _isValidStorageChannelChat(chat)) {
            print('✅ Found existing VALID channel in ARCHIVE: $chatId');

            await _secureStorage.write(
              key: _storageChannelKey,
              value: chatId.toString(),
            );
            return chatId;
          } else {
            print(
              '⚠️ Archived chat $chatId is not valid (deleted/left), skipping.',
            );
          }
        }
      }
    }

    // Not found in archive -> Create new
    print(
      '📦 No archived channel found. Creating new $_storageChannelName channel...',
    );

    // 🔥 Channel recreation implies old data is invalid. Clear it.
    await _clearLocalData();

    final newChat = await createPrivateChannel(
      _storageChannelName,
      'Private storage for Void app. Do not delete or share.',
    );

    final chatId = newChat['id'] as int;
    print('Created channel: $chatId - archiving it...');

    // Archive the channel immediately
    await archiveChat(chatId);

    await _secureStorage.write(
      key: _storageChannelKey,
      value: chatId.toString(),
    );

    return chatId;
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
