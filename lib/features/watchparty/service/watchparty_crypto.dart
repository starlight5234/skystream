import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;

class WatchPartyCrypto {
  /// Generates a secure random 6-character alphanumeric room passcode.
  static String generatePasscode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random.secure();
    return List.generate(6, (index) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Hashes `passcode + hostName` using SHA-256 to generate a 256-bit key.
  static encrypt_lib.Key deriveKey(String passcode, String hostName) {
    // Salt with hostName to prevent cross-room precomputation attacks.
    final saltInput = '$passcode:$hostName';
    final hashed = sha256.convert(utf8.encode(saltInput));
    return encrypt_lib.Key(Uint8List.fromList(hashed.bytes));
  }

  /// Encrypts plain text using AES-256-CBC and returns "$ivBase64:$ciphertextBase64".
  static String encrypt(String plainText, String passcode, String hostName) {
    final key = deriveKey(passcode, hostName);
    final iv = encrypt_lib.IV.fromSecureRandom(16);
    final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc));
    
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts compound string back to plain text using the derived key.
  static String decrypt(String encryptedCompound, String passcode, String hostName) {
    try {
      final parts = encryptedCompound.split(':');
      if (parts.length != 2) {
        throw const FormatException('Invalid encrypted payload format. Expected "iv:ciphertext".');
      }
      
      final key = deriveKey(passcode, hostName);
      final iv = encrypt_lib.IV.fromBase64(parts[0]);
      final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc));
      
      return encrypter.decrypt64(parts[1], iv: iv);
    } catch (e) {
      throw Exception('Incorrect passcode. Please check the code and try again.');
    }
  }
}
