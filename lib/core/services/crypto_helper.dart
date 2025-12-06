import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Helper class for AES-256 encryption/decryption
class CryptoHelper {
  static const String _keyStorageKey = 'void_encryption_key';
  static const _secureStorage = FlutterSecureStorage();
  
  Key? _key;
  
  /// Initialize the crypto helper and load/generate the encryption key
  Future<void> init() async {
    if (_key != null) return;
    
    // Try to load existing key
    final storedKey = await _secureStorage.read(key: _keyStorageKey);
    
    if (storedKey != null) {
      _key = Key.fromBase64(storedKey);
      print('CryptoHelper: Loaded existing encryption key');
    } else {
      // Generate new 256-bit key
      final keyBytes = _generateSecureRandomBytes(32); // 32 bytes = 256 bits
      _key = Key(keyBytes);
      
      // Store the key securely
      await _secureStorage.write(key: _keyStorageKey, value: _key!.base64);
      print('CryptoHelper: Generated and stored new encryption key');
    }
  }
  
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
