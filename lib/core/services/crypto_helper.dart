import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart' as crypto;

/// Helper class for AES-256 encryption/decryption
class CryptoHelper {
  static const String _legacyKeyStorageKey = 'void_encryption_key';
  static const String _saltStorageKey = 'void_pbkdf2_salt';
  static const String _iterationsStorageKey = 'void_pbkdf2_iterations';
  static const int _defaultIterations = 100000;
  static const _secureStorage = FlutterSecureStorage();
  
  Key? _key;
  Uint8List? _salt;
  int _iterations = _defaultIterations;

  bool get hasKey => _key != null;

  Future<bool> hasStoredSalt() async {
    final storedSalt = await _secureStorage.read(key: _saltStorageKey);
    return storedSalt != null;
  }
  
  /// Initialize crypto helper.
  ///
  /// If a passphrase is provided, derives the key using PBKDF2 with stored (or newly created) salt.
  /// If no passphrase is provided, falls back to legacy stored key if present; otherwise generates
  /// a device-bound key (will be lost on uninstall) and logs a warning.
  Future<void> init({String? passphrase}) async {
    if (_key != null) return;

    // Legacy fallback: use stored key if no passphrase provided
    if (passphrase == null) {
      final legacy = await _secureStorage.read(key: _legacyKeyStorageKey);
      if (legacy != null) {
        _key = Key.fromBase64(legacy);
        print('CryptoHelper: Loaded legacy encryption key');
        return;
      }
    }

    // Try to load salt/iterations
    final storedSalt = await _secureStorage.read(key: _saltStorageKey);
    final storedIters = await _secureStorage.read(key: _iterationsStorageKey);

    if (storedSalt != null) {
      _salt = base64Decode(storedSalt);
      _iterations = int.tryParse(storedIters ?? '') ?? _defaultIterations;
      if (passphrase == null) {
        throw StateError('Passphrase required to derive encryption key');
      }
      await _deriveAndStore(passphrase, persistSalt: false);
      return;
    }

    // No salt yet: require passphrase to create new vault key
    if (passphrase == null) {
      // Backward-compatible fallback: generate a device-bound key (not recoverable)
      final keyBytes = _generateSecureRandomBytes(32);
      _key = Key(keyBytes);
      await _secureStorage.write(
        key: _legacyKeyStorageKey,
        value: _key!.base64,
      );
      print('CryptoHelper: Generated device-bound key (no passphrase provided). WARNING: not recoverable after uninstall.');
      return;
    }

    _salt = _generateSecureRandomBytes(16);
    _iterations = _defaultIterations;
    await _deriveAndStore(passphrase, persistSalt: true);
  }

  /// Derive key from passphrase and store salt/iterations if requested
  Future<void> _deriveAndStore(String passphrase, {required bool persistSalt}) async {
    final pbkdf2 = crypto.Pbkdf2(
      macAlgorithm: crypto.Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );

    final secretKey = crypto.SecretKey(utf8.encode(passphrase));
    final newKey = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: _salt!,
    );
    final keyBytes = await newKey.extractBytes();
    _key = Key(Uint8List.fromList(keyBytes));

    if (persistSalt) {
      await _secureStorage.write(
        key: _saltStorageKey,
        value: base64Encode(_salt!),
      );
      await _secureStorage.write(
        key: _iterationsStorageKey,
        value: _iterations.toString(),
      );
    }
  }

  /// Check if vault key exists (salt stored) and requires passphrase
  Future<bool> needsPassphrase() async {
    final storedSalt = await _secureStorage.read(key: _saltStorageKey);
    if (storedSalt != null) {
      // already initialized vault that needs passphrase to derive
      return _key == null;
    }
    return false;
  }

  /// Expose salt/iterations for syncing to Telegram config
  String? get currentSaltBase64 => _salt != null ? base64Encode(_salt!) : null;
  int get currentIterations => _iterations;
  
  /// Generate cryptographically secure random bytes
  Uint8List _generateSecureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
  
  /// Generate a random IV for encryption
  String generateIV() {
    final ivBytes = _generateSecureRandomBytes(16); // 16 bytes for AES
    return base64Encode(ivBytes);
  }
  
  /// Encrypt a file and return the encrypted bytes
  /// Returns the encrypted data
  Future<Uint8List> encryptFile(File file, String ivBase64) async {
    if (_key == null) await init();
    
    final iv = IV.fromBase64(ivBase64);
    final encrypter = Encrypter(AES(_key!, mode: AESMode.cbc));
    
    // Read file bytes
    final fileBytes = await file.readAsBytes();
    
    // Encrypt
    final encrypted = encrypter.encryptBytes(fileBytes, iv: iv);
    
    return encrypted.bytes;
  }
  
  /// Encrypt bytes directly
  Uint8List encryptBytes(Uint8List data, String ivBase64) {
    if (_key == null) throw StateError('CryptoHelper not initialized');
    
    final iv = IV.fromBase64(ivBase64);
    final encrypter = Encrypter(AES(_key!, mode: AESMode.cbc));
    
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    return encrypted.bytes;
  }
  
  /// Decrypt bytes
  Uint8List decryptBytes(Uint8List encryptedData, String ivBase64) {
    if (_key == null) throw StateError('CryptoHelper not initialized');
    
    final iv = IV.fromBase64(ivBase64);
    final encrypter = Encrypter(AES(_key!, mode: AESMode.cbc));
    
    final encrypted = Encrypted(encryptedData);
    final decrypted = encrypter.decryptBytes(encrypted, iv: iv);
    
    return Uint8List.fromList(decrypted);
  }
  
  /// Encrypt a file and save to a new file
  /// Returns the path to the encrypted file
  Future<String> encryptFileToPath(File sourceFile, String ivBase64, String destPath) async {
    final encryptedBytes = await encryptFile(sourceFile, ivBase64);
    
    final destFile = File(destPath);
    await destFile.writeAsBytes(encryptedBytes);
    
    return destPath;
  }
  
  /// Decrypt a file and return the decrypted bytes
  Future<Uint8List> decryptFile(File encryptedFile, String ivBase64) async {
    if (_key == null) await init();
    
    final iv = IV.fromBase64(ivBase64);
    final encrypter = Encrypter(AES(_key!, mode: AESMode.cbc));
    
    // Read encrypted bytes
    final encryptedBytes = await encryptedFile.readAsBytes();
    
    // Decrypt
    final encrypted = Encrypted(encryptedBytes);
    final decrypted = encrypter.decryptBytes(encrypted, iv: iv);
    
    return Uint8List.fromList(decrypted);
  }
  
  /// Decrypt a file and save to a new file
  Future<String> decryptFileToPath(File encryptedFile, String ivBase64, String destPath) async {
    final decryptedBytes = await decryptFile(encryptedFile, ivBase64);
    
    final destFile = File(destPath);
    await destFile.writeAsBytes(decryptedBytes);
    
    return destPath;
  }
  
  /// Check if the crypto helper is initialized
  bool get isInitialized => _key != null;
}
